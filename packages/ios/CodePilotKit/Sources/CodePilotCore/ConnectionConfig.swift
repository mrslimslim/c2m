import Foundation

public enum ConnectionConfig: Equatable, Sendable {
    case lan(
        host: String,
        port: Int,
        token: String,
        bridgePublicKey: String,
        otp: String
    )
    case relay(
        url: String,
        channel: String,
        bridgePublicKey: String,
        otp: String
    )

    public var bridgePublicKey: String {
        switch self {
        case let .lan(_, _, _, bridgePublicKey, _):
            bridgePublicKey
        case let .relay(_, _, bridgePublicKey, _):
            bridgePublicKey
        }
    }

    public var otp: String {
        switch self {
        case let .lan(_, _, _, _, otp):
            otp
        case let .relay(_, _, _, otp):
            otp
        }
    }

    public var legacyToken: String? {
        switch self {
        case let .lan(_, _, token, _, _):
            token
        case .relay:
            nil
        }
    }

    public var isRelay: Bool {
        switch self {
        case .lan:
            false
        case .relay:
            true
        }
    }
}
