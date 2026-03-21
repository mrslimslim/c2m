import Foundation

public struct FileState: Codable, Equatable, Sendable {
    public let path: String
    public let content: String
    public let language: String
    public let isLoading: Bool

    public init(path: String, content: String, language: String, isLoading: Bool) {
        self.path = path
        self.content = content
        self.language = language
        self.isLoading = isLoading
    }
}

public struct FileStoreSnapshot: Codable, Equatable, Sendable {
    public let fileStatesBySession: [String: [String: FileState]]
    public let pendingRequestsByPath: [String: [String]]

    public init(
        fileStatesBySession: [String: [String: FileState]],
        pendingRequestsByPath: [String: [String]]
    ) {
        self.fileStatesBySession = fileStatesBySession
        self.pendingRequestsByPath = pendingRequestsByPath
    }
}

public final class FileStore {
    private let lock = NSLock()
    private var fileStatesBySession: [String: [String: FileState]] = [:]
    private var pendingRequestsByPath: [String: [String]] = [:]

    public init() {}

    public func markRequested(path: String, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }

        pendingRequestsByPath[path, default: []].append(sessionId)
        fileStatesBySession[sessionId, default: [:]][path] = .init(
            path: path,
            content: "",
            language: "",
            isLoading: true
        )
    }

    public func cancelRequested(path: String, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }

        if var queue = pendingRequestsByPath[path],
           let index = queue.firstIndex(of: sessionId) {
            queue.remove(at: index)
            pendingRequestsByPath[path] = queue.isEmpty ? nil : queue
        }

        if let state = fileStatesBySession[sessionId]?[path], state.isLoading {
            fileStatesBySession[sessionId]?[path] = nil
            if fileStatesBySession[sessionId]?.isEmpty == true {
                fileStatesBySession[sessionId] = nil
            }
        }
    }

    public func routeFileContent(
        path: String,
        content: String,
        language: String,
        fallbackSessionId: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        let targetSessionId = dequeuePendingSessionIdLocked(path: path) ?? fallbackSessionId
        guard let targetSessionId else {
            return
        }

        fileStatesBySession[targetSessionId, default: [:]][path] = .init(
            path: path,
            content: content,
            language: language,
            isLoading: false
        )
    }

    public func fileState(for path: String, sessionId: String) -> FileState? {
        lock.lock()
        defer { lock.unlock() }
        return fileStatesBySession[sessionId]?[path]
    }

    public func files(for sessionId: String) -> [FileState] {
        lock.lock()
        defer { lock.unlock() }
        let values = fileStatesBySession[sessionId]?.values.map { $0 } ?? []
        return values.sorted { $0.path < $1.path }
    }

    public func migrateSessionState(from oldSessionId: String, to newSessionId: String) {
        guard oldSessionId != newSessionId else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if let states = fileStatesBySession.removeValue(forKey: oldSessionId) {
            fileStatesBySession[newSessionId, default: [:]].merge(states, uniquingKeysWith: { _, new in new })
        }

        for path in pendingRequestsByPath.keys {
            guard let queue = pendingRequestsByPath[path] else {
                continue
            }
            pendingRequestsByPath[path] = queue.map { $0 == oldSessionId ? newSessionId : $0 }
        }
    }

    public func removeSessionState(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }

        fileStatesBySession[sessionId] = nil
        for path in pendingRequestsByPath.keys {
            guard let queue = pendingRequestsByPath[path] else {
                continue
            }

            let filtered = queue.filter { $0 != sessionId }
            pendingRequestsByPath[path] = filtered.isEmpty ? nil : filtered
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        fileStatesBySession.removeAll()
        pendingRequestsByPath.removeAll()
    }

    public func snapshot() -> FileStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            fileStatesBySession: fileStatesBySession,
            pendingRequestsByPath: pendingRequestsByPath
        )
    }

    public func restore(from snapshot: FileStoreSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        fileStatesBySession = snapshot.fileStatesBySession
        pendingRequestsByPath = snapshot.pendingRequestsByPath
    }

    private func dequeuePendingSessionIdLocked(path: String) -> String? {
        guard var queue = pendingRequestsByPath[path], !queue.isEmpty else {
            return nil
        }
        let sessionId = queue.removeFirst()
        pendingRequestsByPath[path] = queue.isEmpty ? nil : queue
        return sessionId
    }
}
