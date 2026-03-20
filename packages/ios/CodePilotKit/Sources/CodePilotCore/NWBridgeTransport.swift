import Foundation
import Network
import CodePilotProtocol

/// WebSocket transport using raw Network.framework TCP + manual HTTP upgrade.
/// Not subject to ATS — works with `ws://` LAN hosts.
public final class NWBridgeTransport: BridgeTransport {
    public var onReceive: ((BridgeTransportFrame) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let stateQueue = DispatchQueue(label: "CodePilotCore.NWBridgeTransport.state")
    private let networkQueue = DispatchQueue(label: "CodePilotCore.NWBridgeTransport.network")

    private var connection: NWConnection?
    private var isClosed = true
    private var connectionGeneration: UInt64 = 0
    private var isUpgraded = false
    /// Queued frames to send after WebSocket upgrade completes
    private var pendingSendQueue: [(Data, ((Error?) -> Void)?)] = []

    public init(url: URL) {
        self.url = url
    }

    public func open() throws {
        var oldConnection: NWConnection?

        stateQueue.sync {
            isClosed = false
            connectionGeneration += 1
            isUpgraded = false
            pendingSendQueue.removeAll()
            oldConnection = connection
            connection = nil
        }

        oldConnection?.cancel()

        let (host, port, path, useTLS) = try parseURL(url)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 15

        let params: NWParameters
        if useTLS {
            params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOptions)
        } else {
            params = NWParameters(tls: nil, tcp: tcpOptions)
        }

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWBridgeTransportError.invalidURL
        }
        let conn = NWConnection(host: nwHost, port: nwPort, using: params)

        let token = stateQueue.sync { connectionGeneration }

        conn.stateUpdateHandler = { [weak self] state in
            self?.handleStateUpdate(state, generation: token, host: host, port: port, path: path)
        }

        stateQueue.sync {
            self.connection = conn
        }

        conn.start(queue: networkQueue)
    }

    public func close() {
        let prev: NWConnection? = stateQueue.sync {
            isClosed = true
            connectionGeneration += 1
            isUpgraded = false
            pendingSendQueue.removeAll()
            receiveBuffer.removeAll()
            let prev = connection
            connection = nil
            return prev
        }
        prev?.cancel()
    }

    public func send(_ frame: BridgeTransportFrame) throws {
        let payload = try encode(frame: frame)
        guard let textData = payload.data(using: .utf8) else {
            throw NWBridgeTransportError.invalidOutboundFrame
        }

        let gen: UInt64 = stateQueue.sync { connectionGeneration }

        // Build WebSocket text frame
        let wsFrame = buildWebSocketFrame(opcode: 0x1, payload: textData, mask: true)

        let upgraded: Bool = stateQueue.sync { isUpgraded }

        if !upgraded {
            // Queue the frame — it will be flushed after HTTP upgrade completes
            stateQueue.sync {
                pendingSendQueue.append((wsFrame, { [weak self] error in
                    guard let self else { return }
                    if let error, self.isActive(generation: gen) {
                        self.onDisconnect?(error)
                    }
                }))
            }
            return
        }

        let conn: NWConnection? = stateQueue.sync { connection }
        guard let conn else {
            throw NWBridgeTransportError.notConnected
        }

        conn.send(content: wsFrame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error, self.isActive(generation: gen) {
                self.onDisconnect?(error)
            }
        })
    }

    // MARK: - State Handling

    private func handleStateUpdate(
        _ state: NWConnection.State,
        generation: UInt64,
        host: String,
        port: UInt16,
        path: String
    ) {
        guard isActive(generation: generation) else { return }

        switch state {
        case .setup, .preparing:
            break
        case .ready:
            // TCP connected, perform WebSocket HTTP upgrade
            performUpgrade(generation: generation, host: host, port: port, path: path)
        case let .failed(error):
            onDisconnect?(error)
        case .cancelled:
            if isActive(generation: generation) {
                onDisconnect?(nil)
            }
        case let .waiting(error):
            onDisconnect?(error)
        @unknown default:
            break
        }
    }

    // MARK: - HTTP Upgrade Handshake

    private func performUpgrade(generation: UInt64, host: String, port: UInt16, path: String) {
        guard isActive(generation: generation) else { return }
        let conn: NWConnection? = stateQueue.sync { connection }
        guard let conn else { return }

        // Generate Sec-WebSocket-Key
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        let wsKey = Data(keyBytes).base64EncodedString()

        let portSuffix = (port == 80 || port == 443) ? "" : ":\(port)"
        let request = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)\(portSuffix)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(wsKey)",
            "Sec-WebSocket-Version: 13",
            "",
            "",
        ].joined(separator: "\r\n")

        guard let requestData = request.data(using: .utf8) else {
            onDisconnect?(NWBridgeTransportError.invalidOutboundFrame)
            return
        }

        conn.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard let self, self.isActive(generation: generation) else { return }
            if let error {
                self.onDisconnect?(error)
                return
            }

            // Read upgrade response
            self.readUpgradeResponse(generation: generation)
        })
    }

    private func readUpgradeResponse(generation: UInt64) {
        guard isActive(generation: generation) else { return }
        let conn: NWConnection? = stateQueue.sync { connection }
        guard let conn else { return }

        // Read enough bytes for the HTTP response (up to 4KB)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, _, error in
            guard let self, self.isActive(generation: generation) else { return }

            if let error {
                self.onDisconnect?(error)
                return
            }

            guard let data = content, !data.isEmpty else {
                self.onDisconnect?(NWBridgeTransportError.upgradeFailed)
                return
            }

            guard let response = String(data: data, encoding: .utf8) else {
                self.onDisconnect?(NWBridgeTransportError.upgradeFailed)
                return
            }

            // Verify "101 Switching Protocols"
            guard response.hasPrefix("HTTP/1.1 101") else {
                self.onDisconnect?(NWBridgeTransportError.upgradeFailed)
                return
            }

            // WebSocket upgrade succeeded
            self.stateQueue.sync { self.isUpgraded = true }

            // Flush any queued frames (e.g., handshake)
            self.flushPendingSendQueue(generation: generation)

            // Check if response contains data after the headers (framing bytes)
            if let headerEnd = response.range(of: "\r\n\r\n") {
                let afterHeaders = response[headerEnd.upperBound...]
                if !afterHeaders.isEmpty, let remaining = afterHeaders.data(using: .utf8) {
                    // Process any trailing data as WebSocket frames
                    self.processReceivedData(remaining, generation: generation)
                }
            }

            // Start WebSocket receive loop
            self.receiveWebSocketData(generation: generation)
        }
    }

    // MARK: - WebSocket Frame Processing

    private func receiveWebSocketData(generation: UInt64) {
        guard isActive(generation: generation) else { return }
        let conn: NWConnection? = stateQueue.sync { connection }
        guard let conn else { return }

        conn.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self, self.isActive(generation: generation) else { return }

            if let error {
                self.onDisconnect?(error)
                return
            }

            if isComplete {
                self.onDisconnect?(nil)
                return
            }

            guard let data = content, !data.isEmpty else {
                self.receiveWebSocketData(generation: generation)
                return
            }

            self.processReceivedData(data, generation: generation)
            self.receiveWebSocketData(generation: generation)
        }
    }

    /// Buffer for partial WebSocket frames
    private var receiveBuffer = Data()

    private func processReceivedData(_ data: Data, generation: UInt64) {
        stateQueue.sync { receiveBuffer.append(data) }

        while true {
            let buffer: Data = stateQueue.sync { receiveBuffer }
            guard let (frame, consumed) = parseWebSocketFrame(buffer) else {
                break
            }

            stateQueue.sync { receiveBuffer = Data(receiveBuffer.dropFirst(consumed)) }

            guard isActive(generation: generation) else { return }

            switch frame.opcode {
            case 0x1: // text
                if let text = String(data: frame.payload, encoding: .utf8) {
                    do {
                        let bridgeFrame = try decode(data: Data(text.utf8))
                        onReceive?(bridgeFrame)
                    } catch {
                        onDisconnect?(error)
                        return
                    }
                }
            case 0x2: // binary
                do {
                    let bridgeFrame = try decode(data: frame.payload)
                    onReceive?(bridgeFrame)
                } catch {
                    onDisconnect?(error)
                    return
                }
            case 0x8: // close
                onDisconnect?(nil)
                return
            case 0x9: // ping — send pong
                sendPong(frame.payload, generation: generation)
            case 0xA: // pong — ignore
                break
            default:
                break
            }
        }
    }

    private func flushPendingSendQueue(generation: UInt64) {
        let queue: [(Data, ((Error?) -> Void)?)] = stateQueue.sync {
            let q = pendingSendQueue
            pendingSendQueue.removeAll()
            return q
        }
        let conn: NWConnection? = stateQueue.sync { connection }
        guard let conn, isActive(generation: generation) else { return }

        for (data, completion) in queue {
            conn.send(content: data, completion: .contentProcessed { error in
                completion?(error)
            })
        }
    }

    private func sendPong(_ payload: Data, generation: UInt64) {
        let conn: NWConnection? = stateQueue.sync { connection }
        guard let conn, isActive(generation: generation) else { return }

        let pongFrame = buildWebSocketFrame(opcode: 0xA, payload: payload, mask: true)
        conn.send(content: pongFrame, completion: .contentProcessed { _ in })
    }

    // MARK: - WebSocket Frame Parsing

    private struct WSFrame {
        let opcode: UInt8
        let payload: Data
    }

    /// Parses a single WebSocket frame from buffer. Returns nil if not enough data.
    /// Returns (frame, bytesConsumed) on success.
    private func parseWebSocketFrame(_ data: Data) -> (WSFrame, Int)? {
        guard data.count >= 2 else { return nil }

        let byte0 = data[data.startIndex]
        let byte1 = data[data.startIndex + 1]
        let opcode = byte0 & 0x0F
        let isMasked = (byte1 & 0x80) != 0
        var payloadLength = UInt64(byte1 & 0x7F)

        var offset = 2

        if payloadLength == 126 {
            guard data.count >= offset + 2 else { return nil }
            payloadLength = UInt64(data[data.startIndex + offset]) << 8
                | UInt64(data[data.startIndex + offset + 1])
            offset += 2
        } else if payloadLength == 127 {
            guard data.count >= offset + 8 else { return nil }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = payloadLength << 8 | UInt64(data[data.startIndex + offset + i])
            }
            offset += 8
        }

        var maskKey: [UInt8]?
        if isMasked {
            guard data.count >= offset + 4 else { return nil }
            maskKey = [
                data[data.startIndex + offset],
                data[data.startIndex + offset + 1],
                data[data.startIndex + offset + 2],
                data[data.startIndex + offset + 3],
            ]
            offset += 4
        }

        let totalNeeded = offset + Int(payloadLength)
        guard data.count >= totalNeeded else { return nil }

        var payload = Data(data[data.startIndex + offset ..< data.startIndex + totalNeeded])

        if let mask = maskKey {
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }

        return (WSFrame(opcode: opcode, payload: payload), totalNeeded)
    }

    /// Builds a WebSocket frame (client frames must be masked per RFC 6455).
    private func buildWebSocketFrame(opcode: UInt8, payload: Data, mask: Bool) -> Data {
        var frame = Data()

        // FIN + opcode
        frame.append(0x80 | opcode)

        // Payload length + mask bit
        let maskBit: UInt8 = mask ? 0x80 : 0x00
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }

        if mask {
            var maskKey = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &maskKey)
            frame.append(contentsOf: maskKey)

            var maskedPayload = payload
            for i in 0..<maskedPayload.count {
                maskedPayload[i] ^= maskKey[i % 4]
            }
            frame.append(maskedPayload)
        } else {
            frame.append(payload)
        }

        return frame
    }

    // MARK: - Helpers

    private func isActive(generation: UInt64) -> Bool {
        stateQueue.sync {
            !isClosed && connectionGeneration == generation
        }
    }

    private func parseURL(_ url: URL) throws -> (host: String, port: UInt16, path: String, tls: Bool) {
        let scheme = url.scheme?.lowercased() ?? "ws"
        let useTLS = (scheme == "wss" || scheme == "https")
        let defaultPort: UInt16 = useTLS ? 443 : 80

        guard let host = url.host, !host.isEmpty else {
            throw NWBridgeTransportError.invalidURL
        }
        let port = UInt16(url.port ?? Int(defaultPort))

        var path = url.path
        if path.isEmpty { path = "/" }
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }

        return (host, port, path, useTLS)
    }

    private func encode(frame: BridgeTransportFrame) throws -> String {
        let data: Data
        switch frame {
        case let .handshake(message):   data = try encoder.encode(message)
        case let .handshakeOK(message): data = try encoder.encode(message)
        case let .transport(message):   data = try encoder.encode(message)
        case let .phone(message):       data = try encoder.encode(message)
        case let .bridge(message):      data = try encoder.encode(message)
        case let .encrypted(message):   data = try encoder.encode(message)
        }

        guard let payload = String(data: data, encoding: .utf8) else {
            throw NWBridgeTransportError.invalidOutboundFrame
        }
        return payload
    }

    private func decode(data: Data) throws -> BridgeTransportFrame {
        if let handshakeOK = try? decoder.decode(HandshakeOkMessage.self, from: data) {
            return .handshakeOK(handshakeOK)
        }
        if let transport = try? decoder.decode(TransportFrame.self, from: data) {
            return .transport(transport)
        }
        if let encrypted = try? decoder.decode(EncryptedWireMessage.self, from: data) {
            return .encrypted(encrypted)
        }
        if let bridgeMessage = try? decoder.decode(BridgeMessage.self, from: data) {
            return .bridge(bridgeMessage)
        }
        if let phoneMessage = try? decoder.decode(PhoneMessage.self, from: data) {
            return .phone(phoneMessage)
        }
        if let handshake = try? decoder.decode(HandshakeMessage.self, from: data) {
            return .handshake(handshake)
        }

        throw NWBridgeTransportError.unsupportedInboundPayload
    }
}

public enum NWBridgeTransportError: Error, LocalizedError {
    case notConnected
    case invalidURL
    case invalidOutboundFrame
    case unsupportedInboundPayload
    case upgradeFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket not connected"
        case .invalidURL: return "Invalid WebSocket URL"
        case .invalidOutboundFrame: return "Failed to encode outbound frame"
        case .unsupportedInboundPayload: return "Unsupported inbound payload"
        case .upgradeFailed: return "WebSocket HTTP upgrade failed"
        }
    }
}
