import Foundation
import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class BridgeConnectionControllerTests: XCTestCase {
    func testLANE2EHandshakeSuccess() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.lan(
            host: "192.168.1.100",
            port: 19_260,
            token: "legacy-token",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-123456"
        )
        let diagnostics = DiagnosticsStore()
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: diagnostics)

        var deliveredMessages: [BridgeMessage] = []
        controller.onBridgeMessage = { deliveredMessages.append($0) }

        try controller.connect()

        let handshake = try extractHandshake(from: transport.sentFrames, at: 0)
        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "client-1")))

        let encryptedPayload = try makeEncryptedBridgeFrame(
            .pong(latencyMs: 42),
            bridgeSession: bridgeSession,
            phonePublicKey: handshake.phonePubkey,
            otp: "otp-123456"
        )
        transport.simulateReceive(encryptedPayload)

        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "client-1"))
        XCTAssertEqual(deliveredMessages, [.pong(latencyMs: 42)])
        XCTAssertTrue(diagnostics.entries.contains { $0.message.contains("connected") })
    }

    func testLANTokenFallbackSuccess() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.lan(
            host: "192.168.1.100",
            port: 19_260,
            token: "legacy-token",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-123456"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        var deliveredMessages: [BridgeMessage] = []
        controller.onBridgeMessage = { deliveredMessages.append($0) }

        try controller.connect()
        transport.simulateReceive(.transport(.authFailed(reason: "handshake_required")))

        XCTAssertEqual(transport.sentFrames[safe: 1], .transport(.auth(token: "legacy-token")))

        transport.simulateReceive(.transport(.authOK(clientId: "legacy-client")))
        transport.simulateReceive(.bridge(.pong(latencyMs: 9)))

        XCTAssertEqual(controller.state, .connected(encrypted: false, clientId: "legacy-client"))
        XCTAssertEqual(deliveredMessages, [.pong(latencyMs: 9)])
    }

    func testRelayHandshakeSuccess() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "relay-client")))

        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "relay-client"))
        XCTAssertEqual(transport.sentFrames.count, 1)
        XCTAssertNoThrow(try extractHandshake(from: transport.sentFrames, at: 0))
    }

    func testRelayRejectsPlaintextHandshakeDowngrade() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.handshakeOK(.init(encrypted: false, clientId: "relay-client")))

        XCTAssertEqual(controller.state, .failed(reason: "relay_requires_encryption"))
    }

    func testRelayRejectsLegacyAuthOKFrames() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.transport(.authOK(clientId: "legacy-client")))

        XCTAssertEqual(controller.state, .failed(reason: "relay_auth_downgrade_rejected"))
    }

    func testLateHandshakeOKAfterFailedIsIgnored() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.transport(.authFailed(reason: "invalid_otp")))
        XCTAssertEqual(controller.state, .failed(reason: "invalid_otp"))

        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "late-client")))
        XCTAssertEqual(controller.state, .failed(reason: "invalid_otp"))
    }

    func testLateHandshakeOKWhileConnectedIsIgnored() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "relay-client")))
        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "relay-client"))

        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "late-client")))
        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "relay-client"))
    }

    func testRelayControlFrameHandling() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let diagnostics = DiagnosticsStore()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: diagnostics)

        var deliveredMessages: [BridgeMessage] = []
        controller.onBridgeMessage = { deliveredMessages.append($0) }

        try controller.connect()
        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "relay-client")))
        transport.simulateReceive(.transport(.relayPeerConnected(device: .bridge)))
        transport.simulateReceive(.transport(.relayPeerDisconnected(device: .bridge)))

        XCTAssertEqual(deliveredMessages, [])
        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "relay-client"))
        XCTAssertTrue(diagnostics.entries.contains { $0.message.contains("relay_peer_connected") })
        XCTAssertTrue(diagnostics.entries.contains { $0.message.contains("relay_peer_disconnected") })
    }

    func testHandshakeFailureTransitionsToFailed() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.transport(.authFailed(reason: "invalid_otp")))

        XCTAssertEqual(controller.state, .failed(reason: "invalid_otp"))
    }

    func testPostFailureDisconnectDoesNotReconnect() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.transport(.authFailed(reason: "invalid_otp")))
        XCTAssertEqual(controller.state, .failed(reason: "invalid_otp"))

        transport.simulateDisconnect()

        XCTAssertEqual(transport.openCallCount, 1)
        XCTAssertEqual(controller.state, .failed(reason: "invalid_otp"))
    }

    func testLateAuthFramesOutsideLegacyAuthPhaseAreIgnored() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "relay-client")))
        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "relay-client"))

        transport.simulateReceive(.transport(.authOK(clientId: "late-client")))
        transport.simulateReceive(.transport(.authFailed(reason: "late-failure")))

        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "relay-client"))
    }

    func testEncryptedSessionsRejectPlaintextFollowUpFrames() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let diagnostics = DiagnosticsStore()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: diagnostics)

        try controller.connect()
        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "relay-client")))
        transport.simulateReceive(.bridge(.pong(latencyMs: 1)))

        XCTAssertEqual(controller.state, .failed(reason: "encrypted_session_requires_ciphertext"))
        XCTAssertTrue(diagnostics.entries.contains { $0.message.contains("plaintext frame rejected") })
    }

    func testReconnectMovesThroughReconnectingBackToConnected() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())
        controller.reconnectBaseDelay = 0

        var states: [ConnectionState] = []
        controller.onStateChange = { states.append($0) }

        try controller.connect()
        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "relay-client")))

        transport.simulateDisconnect()
        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertEqual(transport.openCallCount, 2)
        XCTAssertNoThrow(try extractHandshake(from: transport.sentFrames, at: 1))

        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "relay-client-2")))

        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "relay-client-2"))
        XCTAssertTrue(states.contains(.reconnecting))
        XCTAssertTrue(states.contains(.connected(encrypted: true, clientId: "relay-client-2")))
    }

    func testInvalidEncryptedReplayFrameIsIgnoredAndConnectionStaysAlive() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let diagnostics = DiagnosticsStore()
        let config = ConnectionConfig.relay(
            url: "wss://relay.example.com",
            channel: "abcd1234",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-654321"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: diagnostics)

        try controller.connect()
        transport.simulateReceive(.handshakeOK(.init(encrypted: true, clientId: "relay-client")))

        let invalidReplay = EncryptedWireMessage(
            nonce: Data(repeating: 0x00, count: 12).base64EncodedString(),
            ciphertext: Data(repeating: 0xFF, count: 32).base64EncodedString(),
            tag: Data(repeating: 0xAA, count: 16).base64EncodedString()
        )
        transport.simulateReceive(.encrypted(invalidReplay))

        XCTAssertEqual(controller.state, .connected(encrypted: true, clientId: "relay-client"))
        XCTAssertTrue(diagnostics.entries.contains { $0.message.contains("ignored invalid encrypted payload") })
    }

    func testConcurrentInboundFramesInvokeCallbacksSerially() throws {
        let transport = MockBridgeTransport()
        let bridgeSession = E2ECryptoSession()
        let config = ConnectionConfig.lan(
            host: "192.168.1.100",
            port: 19_260,
            token: "legacy-token",
            bridgePublicKey: bridgeSession.publicKeyBase64,
            otp: "otp-123456"
        )
        let controller = BridgeConnectionController(config: config, transport: transport, diagnostics: DiagnosticsStore())

        try controller.connect()
        transport.simulateReceive(.transport(.authFailed(reason: "handshake_required")))
        transport.simulateReceive(.transport(.authOK(clientId: "legacy-client")))

        let callbacksExpected = 40
        let callbacksFinished = expectation(description: "all callbacks finished")
        callbacksFinished.expectedFulfillmentCount = callbacksExpected

        let lock = NSLock()
        var activeCallbacks = 0
        var maxConcurrentCallbacks = 0

        controller.onBridgeMessage = { _ in
            lock.lock()
            activeCallbacks += 1
            maxConcurrentCallbacks = max(maxConcurrentCallbacks, activeCallbacks)
            lock.unlock()

            Thread.sleep(forTimeInterval: 0.002)

            lock.lock()
            activeCallbacks -= 1
            lock.unlock()
            callbacksFinished.fulfill()
        }

        DispatchQueue.concurrentPerform(iterations: callbacksExpected) { index in
            transport.simulateReceive(.bridge(.pong(latencyMs: index)))
        }

        wait(for: [callbacksFinished], timeout: 2.0)
        XCTAssertEqual(maxConcurrentCallbacks, 1)
    }
}

private extension BridgeConnectionControllerTests {
    enum TestError: Error {
        case expectedHandshake
    }

    func extractHandshake(from frames: [BridgeTransportFrame], at index: Int) throws -> HandshakeMessage {
        guard case let .handshake(handshake)? = frames[safe: index] else {
            throw TestError.expectedHandshake
        }
        return handshake
    }

    func makeEncryptedBridgeFrame(
        _ message: BridgeMessage,
        bridgeSession: E2ECryptoSession,
        phonePublicKey: String,
        otp: String
    ) throws -> BridgeTransportFrame {
        let sessionKey = try bridgeSession.deriveSessionKey(theirPublicKeyBase64: phonePublicKey, otp: otp)
        let payload = try JSONEncoder().encode(message)
        let wire = try E2ECryptoSession.encrypt(plaintext: payload, sessionKey: sessionKey)
        return .encrypted(wire)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
