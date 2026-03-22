import Foundation

public enum BridgeCapability {
    public static let sessionReplayV1 = "session_replay_v1"
    public static let slashCatalogV1 = "slash_catalog_v1"
}

public struct HandshakeOkMessage: Codable, Equatable, Sendable {
    public let type: String = "handshake_ok"
    public let encrypted: Bool
    public let clientId: String?
    public let capabilities: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case encrypted
        case clientId
        case capabilities
    }

    public init(encrypted: Bool, clientId: String?, capabilities: [String]? = nil) {
        self.encrypted = encrypted
        self.clientId = clientId
        self.capabilities = capabilities
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
        self.capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("handshake_ok", forKey: .type)
        try container.encode(encrypted, forKey: .encrypted)
        try container.encodeIfPresent(clientId, forKey: .clientId)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
    }
}

public enum BridgeMessage: Codable, Equatable, Sendable {
    case event(sessionId: String, event: AgentEvent, eventId: Int, timestamp: Int)
    case sessionList(sessions: [SessionInfo])
    case fileContent(path: String, content: String, language: String)
    case pong(latencyMs: Int)
    case error(message: String)
    case sessionSyncComplete(sessionId: String, latestEventId: Int, resolvedSessionId: String?)
    case slashCatalog(SlashCatalogMessage)
    case slashActionResult(SlashActionResultMessage)

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
        case capability
        case adapter
        case adapterVersion
        case catalogVersion
        case defaults
        case commands
        case commandId
        case ok
    }

    enum MessageType: String, Codable {
        case event
        case sessionList = "session_list"
        case fileContent = "file_content"
        case pong
        case error
        case sessionSyncComplete = "session_sync_complete"
        case slashCatalog = "slash_catalog"
        case slashActionResult = "slash_action_result"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .event:
            self = .event(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                event: try container.decode(AgentEvent.self, forKey: .event),
                eventId: try container.decodeIfPresent(Int.self, forKey: .eventId) ?? 0,
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
        case .slashCatalog:
            self = .slashCatalog(
                .init(
                    capability: try container.decode(String.self, forKey: .capability),
                    adapter: try container.decode(AgentType.self, forKey: .adapter),
                    adapterVersion: try container.decodeIfPresent(String.self, forKey: .adapterVersion),
                    catalogVersion: try container.decode(String.self, forKey: .catalogVersion),
                    defaults: try container.decode(SessionConfig.self, forKey: .defaults),
                    commands: try container.decode([SlashCommandMeta].self, forKey: .commands)
                )
            )
        case .slashActionResult:
            self = .slashActionResult(
                .init(
                    commandId: try container.decode(String.self, forKey: .commandId),
                    ok: try container.decode(Bool.self, forKey: .ok),
                    message: try container.decodeIfPresent(String.self, forKey: .message)
                )
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
            if eventId > 0 {
                try container.encode(eventId, forKey: .eventId)
            }
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
        case let .slashCatalog(message):
            try container.encode(MessageType.slashCatalog, forKey: .type)
            try container.encode(message.capability, forKey: .capability)
            try container.encode(message.adapter, forKey: .adapter)
            try container.encodeIfPresent(message.adapterVersion, forKey: .adapterVersion)
            try container.encode(message.catalogVersion, forKey: .catalogVersion)
            try container.encode(message.defaults, forKey: .defaults)
            try container.encode(message.commands, forKey: .commands)
        case let .slashActionResult(message):
            try container.encode(MessageType.slashActionResult, forKey: .type)
            try container.encode(message.commandId, forKey: .commandId)
            try container.encode(message.ok, forKey: .ok)
            try container.encodeIfPresent(message.message, forKey: .message)
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
