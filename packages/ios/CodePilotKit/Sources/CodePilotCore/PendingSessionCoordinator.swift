import Foundation
import CodePilotProtocol

public struct PendingSessionResolution: Equatable, Sendable {
    public let connectionID: String
    public let sessionID: String
    public let command: String
    public let timestamp: Int

    public init(connectionID: String, sessionID: String, command: String, timestamp: Int) {
        self.connectionID = connectionID
        self.sessionID = sessionID
        self.command = command
        self.timestamp = timestamp
    }
}

private struct PendingSessionCommand: Equatable, Sendable {
    let command: String
    let timestamp: Int
}

public final class PendingSessionCoordinator {
    private let lock = NSLock()
    private var pendingByConnectionID: [String: PendingSessionCommand] = [:]

    public init() {}

    public func registerPendingCommand(
        _ command: String,
        for connectionID: String,
        timestamp: Int = Int(Date().timeIntervalSince1970 * 1_000)
    ) {
        lock.lock()
        defer { lock.unlock() }
        pendingByConnectionID[connectionID] = .init(command: command, timestamp: timestamp)
    }

    public func clearPendingCommand(for connectionID: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingByConnectionID[connectionID] = nil
    }

    public func resolvePendingCommand(
        for connectionID: String,
        knownSessionIDs: [String],
        incomingSessions: [SessionInfo]
    ) -> PendingSessionResolution? {
        lock.lock()
        defer { lock.unlock() }

        guard let pending = pendingByConnectionID[connectionID] else {
            return nil
        }

        let known = Set(knownSessionIDs)
        guard let session = incomingSessions
            .filter({ !known.contains($0.id) })
            .sorted(by: sortSessions)
            .first
        else {
            return nil
        }

        pendingByConnectionID[connectionID] = nil
        return .init(
            connectionID: connectionID,
            sessionID: session.id,
            command: pending.command,
            timestamp: pending.timestamp
        )
    }

    public func resolvePendingCommand(
        for connectionID: String,
        knownSessionIDs: [String],
        incomingEventSessionID: String
    ) -> PendingSessionResolution? {
        lock.lock()
        defer { lock.unlock() }

        guard let pending = pendingByConnectionID[connectionID] else {
            return nil
        }

        let known = Set(knownSessionIDs)
        guard !known.contains(incomingEventSessionID) else {
            return nil
        }

        pendingByConnectionID[connectionID] = nil
        return .init(
            connectionID: connectionID,
            sessionID: incomingEventSessionID,
            command: pending.command,
            timestamp: pending.timestamp
        )
    }

    private func sortSessions(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        if lhs.lastActiveAt != rhs.lastActiveAt {
            return lhs.lastActiveAt > rhs.lastActiveAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id < rhs.id
    }
}
