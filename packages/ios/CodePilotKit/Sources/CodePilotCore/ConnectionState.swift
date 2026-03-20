import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case reconnecting
    case connected(encrypted: Bool, clientId: String?)
    case failed(reason: String)
}
