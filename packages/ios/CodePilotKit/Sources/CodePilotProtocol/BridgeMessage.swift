import Foundation

public struct HandshakeOkMessage: Codable, Equatable, Sendable {
    public let type: String = "handshake_ok"
    public let encrypted: Bool
    public let clientId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case encrypted
        case clientId
    }

    public init(encrypted: Bool, clientId: String?) {
        self.encrypted = encrypted
        self.clientId = clientId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "handshake_ok" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected type \"handshake_ok\", got \"\(type)\""
            )
        }

        self.encrypted = try container.decode(Bool.self, forKey: .encrypted)
        self.clientId = try container.decodeIfPresent(String.self, forKey: .clientId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("handshake_ok", forKey: .type)
        try container.encode(encrypted, forKey: .encrypted)
        try container.encodeIfPresent(clientId, forKey: .clientId)
    }
}

public enum BridgeMessage: Codable, Equatable, Sendable {
    case event(sessionId: String, event: AgentEvent, eventId: Int, timestamp: Int)
    case sessionList(sessions: [SessionInfo])
    case fileContent(path: String, content: String, language: String)
    case pong(latencyMs: Int)
    case error(message: String)
    case sessionSyncComplete(sessionId: String, latestEventId: Int, resolvedSessionId: String?)

    enum CodingKeys: String, CodingKey {
        case type
        case encrypted
        case clientId
        case sessionId
        case event
        case eventId
        case timestamp
        case sessions
        case path
        case content
        case language
        case latencyMs
        case message
        case latestEventId
        case resolvedSessionId
    }

    enum MessageType: String, Codable {
        case event
        case sessionList = "session_list"
        case fileContent = "file_content"
        case pong
        case error
        case sessionSyncComplete = "session_sync_complete"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .event:
            self = .event(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                event: try container.decode(AgentEvent.self, forKey: .event),
                eventId: try container.decode(Int.self, forKey: .eventId),
                timestamp: try container.decode(Int.self, forKey: .timestamp)
            )
        case .sessionList:
            self = .sessionList(sessions: try container.decode([SessionInfo].self, forKey: .sessions))
        case .fileContent:
            self = .fileContent(
                path: try container.decode(String.self, forKey: .path),
                content: try container.decode(String.self, forKey: .content),
                language: try container.decode(String.self, forKey: .language)
            )
        case .pong:
            self = .pong(latencyMs: try container.decode(Int.self, forKey: .latencyMs))
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        case .sessionSyncComplete:
            self = .sessionSyncComplete(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                latestEventId: try container.decode(Int.self, forKey: .latestEventId),
                resolvedSessionId: try container.decodeIfPresent(String.self, forKey: .resolvedSessionId)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .event(sessionId, event, eventId, timestamp):
            try container.encode(MessageType.event, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(event, forKey: .event)
            try container.encode(eventId, forKey: .eventId)
            try container.encode(timestamp, forKey: .timestamp)
        case let .sessionList(sessions):
            try container.encode(MessageType.sessionList, forKey: .type)
            try container.encode(sessions, forKey: .sessions)
        case let .fileContent(path, content, language):
            try container.encode(MessageType.fileContent, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(content, forKey: .content)
            try container.encode(language, forKey: .language)
        case let .pong(latencyMs):
            try container.encode(MessageType.pong, forKey: .type)
            try container.encode(latencyMs, forKey: .latencyMs)
        case let .error(message):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .sessionSyncComplete(sessionId, latestEventId, resolvedSessionId):
            try container.encode(MessageType.sessionSyncComplete, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(latestEventId, forKey: .latestEventId)
            try container.encodeIfPresent(resolvedSessionId, forKey: .resolvedSessionId)
        }
    }
}

public struct EncryptedWireMessage: Codable, Equatable, Sendable {
    public let v: Int
    public let nonce: String
    public let ciphertext: String
    public let tag: String

    enum CodingKeys: String, CodingKey {
        case v
        case nonce
        case ciphertext
        case tag
    }

    public init(nonce: String, ciphertext: String, tag: String) {
        self.v = 1
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .v,
                in: container,
                debugDescription: "Unsupported encrypted wire version \(version); expected 1"
            )
        }

        self.v = 1
        self.nonce = try container.decode(String.self, forKey: .nonce)
        self.ciphertext = try container.decode(String.self, forKey: .ciphertext)
        self.tag = try container.decode(String.self, forKey: .tag)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .v)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(ciphertext, forKey: .ciphertext)
        try container.encode(tag, forKey: .tag)
    }
}
