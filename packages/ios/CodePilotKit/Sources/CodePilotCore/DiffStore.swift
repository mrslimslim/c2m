import Foundation
import CodePilotProtocol

public struct DiffState: Equatable, Sendable {
    public let eventId: Int
    public let isLoading: Bool
    public let errorMessage: String?
    public let files: [DiffFile]
    public let loadingMorePaths: Set<String>
    public let fileErrorsByPath: [String: String]

    public init(
        eventId: Int,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        files: [DiffFile] = [],
        loadingMorePaths: Set<String> = [],
        fileErrorsByPath: [String: String] = [:]
    ) {
        self.eventId = eventId
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.files = files
        self.loadingMorePaths = loadingMorePaths
        self.fileErrorsByPath = fileErrorsByPath
    }
}

public final class DiffStore {
    private let lock = NSLock()
    private var statesBySession: [String: [Int: DiffState]] = [:]

    public init() {}

    public func markRequested(sessionId: String, eventId: Int) {
        lock.lock()
        defer { lock.unlock() }

        var sessionStates = statesBySession[sessionId, default: [:]]
        let previous = sessionStates[eventId] ?? .init(eventId: eventId)
        sessionStates[eventId] = .init(
            eventId: eventId,
            isLoading: true,
            errorMessage: nil,
            files: previous.files,
            loadingMorePaths: previous.loadingMorePaths,
            fileErrorsByPath: previous.fileErrorsByPath
        )
        statesBySession[sessionId] = sessionStates
    }

    public func markRequestFailed(sessionId: String, eventId: Int, message: String) {
        lock.lock()
        defer { lock.unlock() }

        var sessionStates = statesBySession[sessionId, default: [:]]
        let previous = sessionStates[eventId] ?? .init(eventId: eventId)
        sessionStates[eventId] = .init(
            eventId: eventId,
            isLoading: false,
            errorMessage: message,
            files: previous.files,
            loadingMorePaths: previous.loadingMorePaths,
            fileErrorsByPath: previous.fileErrorsByPath
        )
        statesBySession[sessionId] = sessionStates
    }

    public func routeDiffContent(sessionId: String, eventId: Int, files: [DiffFile]) {
        lock.lock()
        defer { lock.unlock() }

        statesBySession[sessionId, default: [:]][eventId] = .init(
            eventId: eventId,
            isLoading: false,
            errorMessage: nil,
            files: files
        )
    }

    public func markLoadingMore(sessionId: String, eventId: Int, path: String) {
        lock.lock()
        defer { lock.unlock() }

        var sessionStates = statesBySession[sessionId, default: [:]]
        let previous = sessionStates[eventId] ?? .init(eventId: eventId)
        var loading = previous.loadingMorePaths
        loading.insert(path)
        var fileErrors = previous.fileErrorsByPath
        fileErrors[path] = nil
        sessionStates[eventId] = .init(
            eventId: eventId,
            isLoading: previous.isLoading,
            errorMessage: previous.errorMessage,
            files: previous.files,
            loadingMorePaths: loading,
            fileErrorsByPath: fileErrors
        )
        statesBySession[sessionId] = sessionStates
    }

    public func markLoadingMoreFailed(sessionId: String, eventId: Int, path: String, message: String) {
        lock.lock()
        defer { lock.unlock() }

        var sessionStates = statesBySession[sessionId, default: [:]]
        let previous = sessionStates[eventId] ?? .init(eventId: eventId)
        var loading = previous.loadingMorePaths
        loading.remove(path)
        var fileErrors = previous.fileErrorsByPath
        fileErrors[path] = message
        sessionStates[eventId] = .init(
            eventId: eventId,
            isLoading: previous.isLoading,
            errorMessage: previous.errorMessage,
            files: previous.files,
            loadingMorePaths: loading,
            fileErrorsByPath: fileErrors
        )
        statesBySession[sessionId] = sessionStates
    }

    public func routeDiffHunksContent(
        sessionId: String,
        eventId: Int,
        path: String,
        hunks: [DiffHunk],
        nextHunkIndex: Int?
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard var sessionStates = statesBySession[sessionId],
              let previous = sessionStates[eventId],
              let fileIndex = previous.files.firstIndex(where: { $0.path == path }) else {
            return
        }

        var files = previous.files
        let existing = files[fileIndex]
        files[fileIndex] = .init(
            path: existing.path,
            kind: existing.kind,
            addedLines: existing.addedLines,
            deletedLines: existing.deletedLines,
            isTruncated: existing.isTruncated,
            truncationReason: existing.truncationReason,
            totalHunkCount: existing.totalHunkCount,
            loadedHunks: existing.loadedHunks + hunks,
            nextHunkIndex: nextHunkIndex
        )

        var loading = previous.loadingMorePaths
        loading.remove(path)
        var fileErrors = previous.fileErrorsByPath
        fileErrors[path] = nil

        sessionStates[eventId] = .init(
            eventId: eventId,
            isLoading: previous.isLoading,
            errorMessage: previous.errorMessage,
            files: files,
            loadingMorePaths: loading,
            fileErrorsByPath: fileErrors
        )
        statesBySession[sessionId] = sessionStates
    }

    public func state(for sessionId: String, eventId: Int) -> DiffState? {
        lock.lock()
        defer { lock.unlock() }
        return statesBySession[sessionId]?[eventId]
    }

    public func migrateSessionState(from oldSessionId: String, to newSessionId: String) {
        guard oldSessionId != newSessionId else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let previous = statesBySession.removeValue(forKey: oldSessionId) ?? [:]
        guard !previous.isEmpty else {
            return
        }
        var merged = statesBySession[newSessionId, default: [:]]
        merged.merge(previous, uniquingKeysWith: { _, new in new })
        statesBySession[newSessionId] = merged
    }

    public func removeSessionState(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        statesBySession[sessionId] = nil
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        statesBySession.removeAll()
    }
}
