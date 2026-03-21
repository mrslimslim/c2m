import XCTest
@testable import CodePilotCore

final class SessionReplayCoordinatorTests: XCTestCase {
    func testReconnectEnqueuesOneSyncRequestPerKnownSessionUsingStoredCursor() {
        let coordinator = SessionReplayCoordinator()
        let store = SessionStore()

        store.recordAppliedEventID(9, for: "session-b")
        store.recordAppliedEventID(3, for: "session-a")

        XCTAssertEqual(
            coordinator.enqueueReconnectSyncs(
                for: "connection-1",
                sessionIDs: ["session-b", "session-a", "session-c"]
            ) { sessionID in
                store.lastAppliedEventID(for: sessionID)
            },
            [
                .init(connectionID: "connection-1", sessionID: "session-a", afterEventId: 3),
                .init(connectionID: "connection-1", sessionID: "session-b", afterEventId: 9),
                .init(connectionID: "connection-1", sessionID: "session-c", afterEventId: 0),
            ]
        )
    }

    func testGapTriggeredSyncRequestIsNotEnqueuedRepeatedlyForActiveReplay() {
        let coordinator = SessionReplayCoordinator()

        XCTAssertEqual(
            coordinator.enqueueGapSync(
                for: "connection-1",
                sessionID: "session-1",
                afterEventId: 4
            ),
            .init(connectionID: "connection-1", sessionID: "session-1", afterEventId: 4)
        )
        XCTAssertNil(
            coordinator.enqueueGapSync(
                for: "connection-1",
                sessionID: "session-1",
                afterEventId: 4
            )
        )
        XCTAssertNil(
            coordinator.enqueueGapSync(
                for: "connection-1",
                sessionID: "session-1",
                afterEventId: 5
            )
        )

        coordinator.markSyncCompleted(for: "connection-1", sessionID: "session-1", resolvedSessionID: nil)

        XCTAssertEqual(
            coordinator.enqueueGapSync(
                for: "connection-1",
                sessionID: "session-1",
                afterEventId: 5
            ),
            .init(connectionID: "connection-1", sessionID: "session-1", afterEventId: 5)
        )
    }
}
