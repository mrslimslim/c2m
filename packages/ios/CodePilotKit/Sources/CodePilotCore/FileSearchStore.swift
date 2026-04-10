import Foundation
import CodePilotProtocol

public struct FileSearchState: Equatable, Sendable {
    public let query: String
    public let results: [FileSearchMatch]
    public let isLoading: Bool
    public let errorMessage: String?

    public init(
        query: String,
        results: [FileSearchMatch],
        isLoading: Bool,
        errorMessage: String?
    ) {
        self.query = query
        self.results = results
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

public final class FileSearchStore {
    private let lock = NSLock()
    private var stateBySessionId: [String: FileSearchState] = [:]

    public init() {}

    public func markRequested(query: String, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        stateBySessionId[sessionId] = .init(
            query: query,
            results: [],
            isLoading: true,
            errorMessage: nil
        )
    }

    public func routeResults(sessionId: String, query: String, results: [FileSearchMatch]) {
        lock.lock()
        defer { lock.unlock() }
        stateBySessionId[sessionId] = .init(
            query: query,
            results: results,
            isLoading: false,
            errorMessage: nil
        )
    }

    public func markFailed(query: String, sessionId: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        stateBySessionId[sessionId] = .init(
            query: query,
            results: [],
            isLoading: false,
            errorMessage: message
        )
    }

    public func clear(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        stateBySessionId[sessionId] = nil
    }

    public func state(for sessionId: String) -> FileSearchState? {
        lock.lock()
        defer { lock.unlock() }
        return stateBySessionId[sessionId]
    }

    public func migrateSessionState(from oldSessionId: String, to newSessionId: String) {
        guard oldSessionId != newSessionId else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if let state = stateBySessionId.removeValue(forKey: oldSessionId) {
            stateBySessionId[newSessionId] = state
        }
    }

    public func removeSessionState(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        stateBySessionId[sessionId] = nil
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        stateBySessionId.removeAll()
    }
}
