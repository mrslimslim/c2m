import Foundation

public struct HandshakeMessage: Codable, Equatable, Sendable {
    public let type: String = "handshake"
    public let phonePubkey: String
    public let otp: String

    enum CodingKeys: String, CodingKey {
        case type
        case phonePubkey = "phone_pubkey"
        case otp
    }

    public init(phonePubkey: String, otp: String) {
        self.phonePubkey = phonePubkey
        self.otp = otp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "handshake" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected type \"handshake\", got \"\(type)\""
            )
        }

        self.phonePubkey = try container.decode(String.self, forKey: .phonePubkey)
        self.otp = try container.decode(String.self, forKey: .otp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("handshake", forKey: .type)
        try container.encode(phonePubkey, forKey: .phonePubkey)
        try container.encode(otp, forKey: .otp)
    }
}

// MARK: - Session Configuration

public struct SessionConfig: Codable, Equatable, Sendable {
    public var model: String?
    public var approvalPolicy: String?
    public var sandboxMode: String?

    public init(model: String? = nil, approvalPolicy: String? = nil, sandboxMode: String? = nil) {
        self.model = model
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
    }

    /// Returns true if all fields are nil (no configuration set).
    public var isEmpty: Bool {
        model == nil && approvalPolicy == nil && sandboxMode == nil
    }
}

// MARK: - Phone Message

public enum PhoneMessage: Codable, Equatable, Sendable {
    case command(text: String, sessionId: String?, config: SessionConfig?)
    case cancel(sessionId: String)
    case fileRequest(path: String, sessionId: String)
    case deleteSession(sessionId: String)
    case listSessions
    case ping(ts: Int)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case sessionId
        case path
        case ts
        case config
    }

    enum MessageType: String, Codable {
        case command
        case cancel
        case fileRequest = "file_req"
        case deleteSession = "delete_session"
        case listSessions = "list_sessions"
        case ping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .command:
            self = .command(
                text: try container.decode(String.self, forKey: .text),
                sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
                config: try container.decodeIfPresent(SessionConfig.self, forKey: .config)
            )
        case .cancel:
            self = .cancel(sessionId: try container.decode(String.self, forKey: .sessionId))
        case .fileRequest:
            self = .fileRequest(
                path: try container.decode(String.self, forKey: .path),
                sessionId: try container.decode(String.self, forKey: .sessionId)
            )
        case .deleteSession:
            self = .deleteSession(sessionId: try container.decode(String.self, forKey: .sessionId))
        case .listSessions:
            self = .listSessions
        case .ping:
            self = .ping(ts: try container.decode(Int.self, forKey: .ts))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .command(text, sessionId, config):
            try container.encode(MessageType.command, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(sessionId, forKey: .sessionId)
            if let config, !config.isEmpty {
                try container.encode(config, forKey: .config)
            }
        case let .cancel(sessionId):
            try container.encode(MessageType.cancel, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
        case let .fileRequest(path, sessionId):
            try container.encode(MessageType.fileRequest, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(sessionId, forKey: .sessionId)
        case let .deleteSession(sessionId):
            try container.encode(MessageType.deleteSession, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
        case .listSessions:
            try container.encode(MessageType.listSessions, forKey: .type)
        case let .ping(ts):
            try container.encode(MessageType.ping, forKey: .type)
            try container.encode(ts, forKey: .ts)
        }
    }
}
