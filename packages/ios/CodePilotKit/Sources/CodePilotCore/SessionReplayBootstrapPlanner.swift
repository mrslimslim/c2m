import Foundation

public enum SessionReplayBootstrapPlanner {
    public static func sessionIDsForReconnect(
        restoredSessionIDs: [String],
        previouslyMappedSessionIDs: [String],
        currentMappedSessionIDs: [String],
        resolveSessionID: (String) -> String?
    ) -> [String] {
        let currentResolvedSessionIDs = Set(
            currentMappedSessionIDs.compactMap { sessionID in
                resolveSessionID(sessionID) ?? sessionID
            }
        )

        let seedSessionIDs = previouslyMappedSessionIDs + restoredSessionIDs
        let reconnectSessionIDs = seedSessionIDs.compactMap { sessionID -> String? in
            let resolvedSessionID = resolveSessionID(sessionID) ?? sessionID
            guard currentResolvedSessionIDs.contains(resolvedSessionID) else {
                return nil
            }
            return resolvedSessionID
        }

        return Array(Set(reconnectSessionIDs)).sorted()
    }
}
