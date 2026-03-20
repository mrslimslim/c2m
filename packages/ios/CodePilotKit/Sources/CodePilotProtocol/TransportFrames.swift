import Foundation

public enum RelayDevice: String, Codable, Equatable, Sendable {
    case bridge
    case phone
}

public enum TransportFrame: Codable, Equatable, Sendable {
    case auth(token: String)
    case authOK(clientId: String?)
    case authFailed(reason: String?)
    case relayPeerConnected(device: RelayDevice)
    case relayPeerDisconnected(device: RelayDevice)

    enum CodingKeys: String, CodingKey {
        case type
        case token
        case clientId
        case reason
        case device
    }

    enum FrameType: String, Codable {
        case auth
        case authOK = "auth_ok"
        case authFailed = "auth_failed"
        case relayPeerConnected = "relay_peer_connected"
        case relayPeerDisconnected = "relay_peer_disconnected"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(FrameType.self, forKey: .type)

        switch type {
        case .auth:
            self = .auth(token: try container.decode(String.self, forKey: .token))
        case .authOK:
            self = .authOK(clientId: try container.decodeIfPresent(String.self, forKey: .clientId))
        case .authFailed:
            self = .authFailed(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        case .relayPeerConnected:
            self = .relayPeerConnected(device: try container.decode(RelayDevice.self, forKey: .device))
        case .relayPeerDisconnected:
            self = .relayPeerDisconnected(device: try container.decode(RelayDevice.self, forKey: .device))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .auth(token):
            try container.encode(FrameType.auth, forKey: .type)
            try container.encode(token, forKey: .token)
        case let .authOK(clientId):
            try container.encode(FrameType.authOK, forKey: .type)
            try container.encodeIfPresent(clientId, forKey: .clientId)
        case let .authFailed(reason):
            try container.encode(FrameType.authFailed, forKey: .type)
            try container.encodeIfPresent(reason, forKey: .reason)
        case let .relayPeerConnected(device):
            try container.encode(FrameType.relayPeerConnected, forKey: .type)
            try container.encode(device, forKey: .device)
        case let .relayPeerDisconnected(device):
            try container.encode(FrameType.relayPeerDisconnected, forKey: .type)
            try container.encode(device, forKey: .device)
        }
    }
}
