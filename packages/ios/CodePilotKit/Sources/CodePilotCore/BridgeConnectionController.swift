import Foundation
import CodePilotProtocol

public enum BridgeConnectionControllerError: Error, Equatable {
    case notConnected
    case encryptedSessionRequiresCiphertext
    case transport(String)
    case protocolViolation(String)
}

public final class BridgeConnectionController {
    public var onStateChange: ((ConnectionState) -> Void)? {
        get { withQueue { stateChangeHandler } }
        set { withQueue { stateChangeHandler = newValue } }
    }

    public var onBridgeMessage: ((BridgeMessage) -> Void)? {
        get { withQueue { bridgeMessageHandler } }
        set { withQueue { bridgeMessageHandler = newValue } }
    }

    public var state: ConnectionState {
        withQueue { currentState }
    }

    private let config: ConnectionConfig
    private let transport: BridgeTransport
    private let diagnostics: DiagnosticsStore
    private let controllerQueue = DispatchQueue(label: "CodePilotCore.BridgeConnectionController")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueKeyValue: UInt8 = 1

    private enum NegotiationPhase {
        case idle
        case awaitingHandshake
        case awaitingLegacyAuth
        case established
    }

    private var currentState: ConnectionState = .disconnected
    private var stateChangeHandler: ((ConnectionState) -> Void)?
    private var bridgeMessageHandler: ((BridgeMessage) -> Void)?
    private var callbacksBound = false
    private var shouldStayConnected = false
    private var ignoreDisconnectCallback = false
    private var negotiationPhase: NegotiationPhase = .idle
    private var waitingForLegacyAuth = false
    private var cryptoSession = E2ECryptoSession()
    private var sessionKey: Data?

    public var maxReconnectAttempts: Int = 5
    public var reconnectBaseDelay: TimeInterval = 0.5
    private var reconnectAttempts: Int = 0
    private var reconnectWorkItem: DispatchWorkItem?

    public init(
        config: ConnectionConfig,
        transport: BridgeTransport,
        diagnostics: DiagnosticsStore = .init()
    ) {
        self.config = config
        self.transport = transport
        self.diagnostics = diagnostics
        controllerQueue.setSpecific(key: queueKey, value: queueKeyValue)
    }

    public func connect() throws {
        try withQueue {
            shouldStayConnected = true
            reconnectAttempts = 0
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            bindTransportCallbacksIfNeeded()
            transition(to: .connecting)
            try openAndSendHandshake()
        }
    }

    public func disconnect() {
        withQueue {
            shouldStayConnected = false
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            ignoreDisconnectCallback = true
            transport.close()
            ignoreDisconnectCallback = false
            sessionKey = nil
            negotiationPhase = .idle
            waitingForLegacyAuth = false
            transition(to: .disconnected)
        }
    }

    public func reconnect() throws {
        try withQueue {
            shouldStayConnected = true
            transition(to: .reconnecting)
            try openAndSendHandshake()
        }
    }

    public func send(_ message: PhoneMessage) throws {
        try withQueue {
            guard case let .connected(encrypted, _) = currentState else {
                throw BridgeConnectionControllerError.notConnected
            }

            if encrypted {
                guard let sessionKey else {
                    throw BridgeConnectionControllerError.protocolViolation("missing_session_key")
                }
                let payload = try JSONEncoder().encode(message)
                let encryptedMessage = try E2ECryptoSession.encrypt(plaintext: payload, sessionKey: sessionKey)
                try transport.send(.encrypted(encryptedMessage))
                return
            }

            try transport.send(.phone(message))
        }
    }

    private func bindTransportCallbacksIfNeeded() {
        guard !callbacksBound else {
            return
        }
        callbacksBound = true

        transport.onReceive = { [weak self] frame in
            self?.withQueue {
                self?.handle(frame)
            }
        }

        transport.onDisconnect = { [weak self] error in
            self?.withQueue {
                self?.handleDisconnect(error)
            }
        }
    }

    private func openAndSendHandshake() throws {
        waitingForLegacyAuth = false
        negotiationPhase = .awaitingHandshake
        sessionKey = nil
        cryptoSession = E2ECryptoSession()

        do {
            try transport.open()
            let handshake = HandshakeMessage(phonePubkey: cryptoSession.publicKeyBase64, otp: config.otp)
            try transport.send(.handshake(handshake))
            diagnostics.recordInfo("handshake sent")
        } catch {
            fail(reason: "transport_open_failed", terminal: true)
            throw BridgeConnectionControllerError.transport("transport_open_failed")
        }
    }

    private func handleDisconnect(_ error: Error?) {
        if ignoreDisconnectCallback {
            return
        }

        if let error {
            diagnostics.recordError("transport disconnected: \(error.localizedDescription)")
        } else {
            diagnostics.recordInfo("transport disconnected")
        }

        guard shouldStayConnected else {
            if case .failed = currentState {
                return
            }
            transition(to: .disconnected)
            return
        }

        reconnectAttempts += 1
        if reconnectAttempts > maxReconnectAttempts {
            diagnostics.recordError("max reconnect attempts (\(maxReconnectAttempts)) exceeded")
            fail(reason: "max_reconnect_attempts_exceeded", terminal: true)
            return
        }

        // Exponential backoff: base * 2^(attempt-1), capped at 30s
        let delay = reconnectBaseDelay > 0
            ? min(reconnectBaseDelay * pow(2.0, Double(reconnectAttempts - 1)), 30.0)
            : 0
        diagnostics.recordInfo("reconnecting in \(delay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
        transition(to: .reconnecting)

        if delay <= 0 {
            // Synchronous reconnect (for tests)
            do {
                try openAndSendHandshake()
            } catch {
                fail(reason: "reconnect_failed", terminal: true)
            }
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.withQueue {
                guard let self, self.shouldStayConnected else { return }
                do {
                    try self.openAndSendHandshake()
                } catch {
                    self.fail(reason: "reconnect_failed", terminal: true)
                }
            }
        }
        reconnectWorkItem = workItem
        controllerQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func handle(_ frame: BridgeTransportFrame) {
        switch frame {
        case let .handshakeOK(message):
            handleHandshakeOK(message)
        case let .transport(frame):
            handleTransportFrame(frame)
        case let .bridge(message):
            handleBridgeMessage(message)
        case let .encrypted(message):
            handleEncryptedMessage(message)
        case .handshake, .phone:
            diagnostics.recordInfo("ignored inbound frame")
        }
    }

    private func handleHandshakeOK(_ message: HandshakeOkMessage) {
        guard isAwaitingHandshake else {
            diagnostics.recordInfo("ignored out-of-phase handshake_ok")
            return
        }

        if config.isRelay, !message.encrypted {
            fail(reason: "relay_requires_encryption", terminal: true)
            return
        }

        if message.encrypted {
            do {
                sessionKey = try cryptoSession.deriveSessionKey(
                    theirPublicKeyBase64: config.bridgePublicKey,
                    otp: config.otp
                )
            } catch {
                fail(reason: "handshake_key_derivation_failed", terminal: true)
                return
            }
        } else {
            sessionKey = nil
        }

        negotiationPhase = .established
        waitingForLegacyAuth = false
        reconnectAttempts = 0
        transition(to: .connected(encrypted: message.encrypted, clientId: message.clientId))
    }

    private func handleTransportFrame(_ frame: TransportFrame) {
        switch frame {
        case let .authFailed(reason):
            if canBeginLegacyFallback(from: reason), let token = config.legacyToken {
                waitingForLegacyAuth = true
                negotiationPhase = .awaitingLegacyAuth
                do {
                    try transport.send(.transport(.auth(token: token)))
                    diagnostics.recordInfo("fallback auth sent")
                } catch {
                    fail(reason: "legacy_auth_send_failed", terminal: true)
                }
                return
            }

            guard isAwaitingLegacyAuth else {
                if isAwaitingHandshake {
                    fail(reason: reason ?? "auth_failed", terminal: true)
                } else {
                    diagnostics.recordInfo("ignored out-of-phase auth_failed")
                }
                return
            }

            fail(reason: reason ?? "auth_failed", terminal: true)

        case let .authOK(clientId):
            if config.isRelay, isAwaitingHandshake {
                fail(reason: "relay_auth_downgrade_rejected", terminal: true)
                return
            }
            guard isAwaitingLegacyAuth else {
                diagnostics.recordInfo("ignored out-of-phase auth_ok")
                return
            }
            if config.isRelay {
                fail(reason: "relay_auth_downgrade_rejected", terminal: true)
                return
            }

            sessionKey = nil
            waitingForLegacyAuth = false
            negotiationPhase = .established
            transition(to: .connected(encrypted: false, clientId: clientId))

        case let .relayPeerConnected(device):
            diagnostics.recordInfo("relay_peer_connected:\(device.rawValue)")

        case let .relayPeerDisconnected(device):
            diagnostics.recordInfo("relay_peer_disconnected:\(device.rawValue)")

        case .auth:
            diagnostics.recordInfo("ignored inbound auth frame")
        }
    }

    private var canFallbackToLegacyToken: Bool {
        guard let token = config.legacyToken, !token.isEmpty else {
            return false
        }
        guard !config.isRelay else {
            return false
        }
        guard !waitingForLegacyAuth else {
            return false
        }
        return true
    }

    private var isAwaitingHandshake: Bool {
        guard negotiationPhase == .awaitingHandshake else {
            return false
        }
        switch currentState {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    private var isAwaitingLegacyAuth: Bool {
        guard negotiationPhase == .awaitingLegacyAuth, waitingForLegacyAuth else {
            return false
        }
        switch currentState {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    private func canBeginLegacyFallback(from reason: String?) -> Bool {
        guard isAwaitingHandshake else {
            return false
        }
        guard canFallbackToLegacyToken else {
            return false
        }
        if let reason {
            return reason == "handshake_required"
        }
        return false
    }

    private func handleBridgeMessage(_ message: BridgeMessage) {
        guard case let .connected(encrypted, _) = currentState else {
            diagnostics.recordInfo("ignored bridge message while not connected")
            return
        }

        if encrypted {
            diagnostics.recordError("plaintext frame rejected in encrypted mode")
            fail(reason: "encrypted_session_requires_ciphertext", terminal: true)
            return
        }

        bridgeMessageHandler?(message)
    }

    private func handleEncryptedMessage(_ message: EncryptedWireMessage) {
        guard case let .connected(encrypted, _) = currentState, encrypted else {
            diagnostics.recordInfo("ignored invalid encrypted payload: no encrypted session")
            return
        }

        guard let sessionKey else {
            diagnostics.recordInfo("ignored invalid encrypted payload: missing session key")
            return
        }

        do {
            let plaintext = try E2ECryptoSession.decrypt(message: message, sessionKey: sessionKey)
            let bridgeMessage = try JSONDecoder().decode(BridgeMessage.self, from: plaintext)
            bridgeMessageHandler?(bridgeMessage)
        } catch {
            diagnostics.recordInfo("ignored invalid encrypted payload")
        }
    }

    private func fail(reason: String, terminal: Bool) {
        if terminal {
            shouldStayConnected = false
            negotiationPhase = .idle
            waitingForLegacyAuth = false
        }
        diagnostics.recordError(reason)
        transition(to: .failed(reason: reason))
    }

    private func transition(to newState: ConnectionState) {
        if currentState == newState {
            return
        }
        let oldState = currentState
        currentState = newState
        diagnostics.recordStateTransition(from: oldState, to: newState)
        stateChangeHandler?(newState)
    }

    private func withQueue<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueKeyValue {
            return try block()
        }
        return try controllerQueue.sync {
            try block()
        }
    }
}
