import XCTest
@testable import CodePilotCore
import CodePilotProtocol

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

    func testResetClearsInFlightReplaySoProtocolFailureDoesNotWedgeFutureRecovery() {
        let coordinator = SessionReplayCoordinator()

        XCTAssertEqual(
            coordinator.enqueueGapSync(
                for: "connection-1",
                sessionID: "session-1",
                afterEventId: 4
            ),
            .init(connectionID: "connection-1", sessionID: "session-1", afterEventId: 4)
        )
        XCTAssertTrue(coordinator.hasInFlightSyncs(for: "connection-1"))

        coordinator.reset(for: "connection-1")

        XCTAssertFalse(coordinator.hasInFlightSyncs(for: "connection-1"))
        XCTAssertEqual(
            coordinator.enqueueGapSync(
                for: "connection-1",
                sessionID: "session-1",
                afterEventId: 4
            ),
            .init(connectionID: "connection-1", sessionID: "session-1", afterEventId: 4)
        )
    }

    func testHasInFlightSyncTracksReplayBootstrapSessionsUntilCompletion() {
        let coordinator = SessionReplayCoordinator()

        XCTAssertEqual(
            coordinator.enqueueReconnectSyncs(
                for: "connection-1",
                sessionIDs: ["session-1"]
            ) { _ in
                0
            },
            [
                .init(connectionID: "connection-1", sessionID: "session-1", afterEventId: 0),
            ]
        )
        XCTAssertTrue(coordinator.hasInFlightSync(for: "connection-1", sessionID: "session-1"))

        coordinator.markSyncCompleted(
            for: "connection-1",
            sessionID: "session-1",
            resolvedSessionID: "stable-session-1"
        )

        XCTAssertFalse(coordinator.hasInFlightSync(for: "connection-1", sessionID: "session-1"))
        XCTAssertFalse(coordinator.hasInFlightSync(for: "connection-1", sessionID: "stable-session-1"))
    }

    func testRestoredTemporarySessionCanReplayMissingEventsAfterSessionListRemap() {
        let originalSessionStore = SessionStore()
        let originalTimelineStore = TimelineStore()
        let originalFileStore = FileStore()

        let temporarySession = makeSession(id: "temp-session", createdAt: 100, lastActiveAt: 101)
        _ = originalSessionStore.applySessionList([temporarySession])
        originalSessionStore.setActiveSession(id: temporarySession.id)
        originalSessionStore.setDraft("continue", for: temporarySession.id)
        originalSessionStore.recordAppliedEventID(2, for: temporarySession.id)
        originalTimelineStore.appendUserCommand("resume", sessionId: temporarySession.id, timestamp: 1)
        originalTimelineStore.appendBridgeEvent(
            sessionId: temporarySession.id,
            event: .thinking(text: "before relaunch"),
            timestamp: 2
        )
        originalFileStore.markRequested(path: "README.md", sessionId: temporarySession.id)
        originalFileStore.routeFileContent(path: "README.md", content: "cached", language: "markdown")

        let snapshot = ConversationSnapshot(
            sessionStore: originalSessionStore.snapshot(),
            timelineStore: originalTimelineStore.snapshot(),
            fileStore: originalFileStore.snapshot(),
            sessionToConnectionID: [temporarySession.id: "connection-1"]
        )

        let restoredSessionStore = SessionStore()
        restoredSessionStore.restore(from: snapshot.sessionStore)
        let restoredTimelineStore = TimelineStore()
        restoredTimelineStore.restore(from: snapshot.timelineStore)
        let restoredFileStore = FileStore()
        restoredFileStore.restore(from: snapshot.fileStore)

        let router = SessionMessageRouter(
            sessionStore: restoredSessionStore,
            timelineStore: restoredTimelineStore,
            fileStore: restoredFileStore,
            diagnostics: DiagnosticsStore()
        )
        let coordinator = SessionReplayCoordinator()
        let recoverableSessionIDs = ["temp-session"]

        let stableSession = makeSession(id: "stable-session", createdAt: 100, lastActiveAt: 150)
        router.handle(.sessionList(sessions: [stableSession]))

        XCTAssertEqual(restoredSessionStore.sessions.map(\.id), ["stable-session"])
        XCTAssertEqual(restoredSessionStore.activeSessionId, "stable-session")
        XCTAssertEqual(restoredSessionStore.resolvedSessionId(for: "temp-session"), "stable-session")
        XCTAssertEqual(restoredSessionStore.draft(for: "stable-session"), "continue")
        XCTAssertEqual(
            restoredFileStore.fileState(for: "README.md", sessionId: "stable-session")?.content,
            "cached"
        )

        XCTAssertEqual(
            coordinator.enqueueReconnectSyncs(
                for: "connection-1",
                sessionIDs: recoverableSessionIDs
            ) { sessionID in
                restoredSessionStore.lastAppliedEventID(for: sessionID)
            },
            [
                .init(connectionID: "connection-1", sessionID: "temp-session", afterEventId: 2),
            ]
        )

        router.handle(
            .event(
                sessionId: "stable-session",
                event: .agentMessage(text: "recovered after relaunch"),
                eventId: 3,
                timestamp: 3
            )
        )
        router.handle(
            .sessionSyncComplete(
                sessionId: "temp-session",
                latestEventId: 3,
                resolvedSessionId: "stable-session"
            )
        )
        coordinator.markSyncCompleted(
            for: "connection-1",
            sessionID: "temp-session",
            resolvedSessionID: "stable-session"
        )

        XCTAssertEqual(restoredSessionStore.lastAppliedEventID(for: "temp-session"), 3)
        XCTAssertEqual(restoredSessionStore.lastAppliedEventID(for: "stable-session"), 3)
        XCTAssertEqual(
            restoredTimelineStore.timeline(for: "stable-session").map(\.kind),
            [
                .userCommand(text: "resume"),
                .thinking(text: "before relaunch"),
                .agentMessage(text: "recovered after relaunch"),
            ]
        )
        XCTAssertNil(restoredFileStore.fileState(for: "README.md", sessionId: "temp-session"))
        XCTAssertEqual(
            coordinator.enqueueGapSync(
                for: "connection-1",
                sessionID: "stable-session",
                afterEventId: 3
            ),
            .init(connectionID: "connection-1", sessionID: "stable-session", afterEventId: 3)
        )
    }
}

private extension SessionReplayCoordinatorTests {
    func makeSession(id: String, createdAt: Int, lastActiveAt: Int) -> SessionInfo {
        .init(
            id: id,
            agentType: .codex,
            workDir: "/tmp/repo",
            state: .thinking,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt
        )
    }
}
