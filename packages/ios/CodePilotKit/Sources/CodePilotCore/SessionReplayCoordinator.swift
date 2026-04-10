import Foundation

public struct SessionReplayRequest: Equatable, Sendable {
    public let connectionID: String
    public let sessionID: String
    public let afterEventId: Int

    public init(connectionID: String, sessionID: String, afterEventId: Int) {
        self.connectionID = connectionID
        self.sessionID = sessionID
        self.afterEventId = afterEventId
    }
}

public final class SessionReplayCoordinator {
    private let lock = NSLock()
    private var inFlightAfterEventIdByConnectionID: [String: [String: Int]] = [:]

    public init() {}

    public func enqueueReconnectSyncs(
        for connectionID: String,
        sessionIDs: [String],
        lastAppliedEventID: (String) -> Int?
    ) -> [SessionReplayRequest] {
        lock.lock()
        defer { lock.unlock() }

        let uniqueSessionIDs = Array(Set(sessionIDs)).sorted()
        var requests: [SessionReplayRequest] = []
        for sessionID in uniqueSessionIDs {
            guard inFlightAfterEventIdByConnectionID[connectionID]?[sessionID] == nil else {
                continue
            }

            let afterEventId = lastAppliedEventID(sessionID) ?? 0
            inFlightAfterEventIdByConnectionID[connectionID, default: [:]][sessionID] = afterEventId
            requests.append(
                .init(
                    connectionID: connectionID,
                    sessionID: sessionID,
                    afterEventId: afterEventId
                )
            )
        }

        return requests
    }

    public func enqueueGapSync(
        for connectionID: String,
        sessionID: String,
        afterEventId: Int
    ) -> SessionReplayRequest? {
        lock.lock()
        defer { lock.unlock() }

        guard inFlightAfterEventIdByConnectionID[connectionID]?[sessionID] == nil else {
            return nil
        }

        inFlightAfterEventIdByConnectionID[connectionID, default: [:]][sessionID] = afterEventId
        return .init(connectionID: connectionID, sessionID: sessionID, afterEventId: afterEventId)
    }

    public func markSyncCompleted(
        for connectionID: String,
        sessionID: String,
        resolvedSessionID: String?
    ) {
        lock.lock()
        defer { lock.unlock() }

        inFlightAfterEventIdByConnectionID[connectionID]?[sessionID] = nil
        if let resolvedSessionID {
            inFlightAfterEventIdByConnectionID[connectionID]?[resolvedSessionID] = nil
        }
        if inFlightAfterEventIdByConnectionID[connectionID]?.isEmpty == true {
            inFlightAfterEventIdByConnectionID[connectionID] = nil
        }
    }

    public func hasInFlightSyncs(for connectionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(inFlightAfterEventIdByConnectionID[connectionID]?.isEmpty ?? true)
    }

    public func hasInFlightSync(for connectionID: String, sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlightAfterEventIdByConnectionID[connectionID]?[sessionID] != nil
    }

    public func reset(for connectionID: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlightAfterEventIdByConnectionID[connectionID] = nil
    }
}
