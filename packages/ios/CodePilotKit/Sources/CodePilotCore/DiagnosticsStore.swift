import Foundation

public struct DiagnosticEntry: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case info
        case error
        case stateTransition
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public final class DiagnosticsStore {
    private let lock = NSLock()
    private var storage: [DiagnosticEntry] = []

    public init() {}

    public var entries: [DiagnosticEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func recordInfo(_ message: String) {
        append(.init(kind: .info, message: message))
    }

    public func recordError(_ message: String) {
        append(.init(kind: .error, message: message))
    }

    public func recordStateTransition(from: ConnectionState, to: ConnectionState) {
        append(.init(kind: .stateTransition, message: "state: \(label(for: from)) -> \(label(for: to))"))
    }

    private func append(_ entry: DiagnosticEntry) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(entry)
    }

    private func label(for state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .reconnecting:
            "reconnecting"
        case let .connected(encrypted, _):
            encrypted ? "connected(encrypted)" : "connected(plaintext)"
        case let .failed(reason):
            "failed(\(reason))"
        }
    }
}
