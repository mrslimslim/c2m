import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class StoreSnapshotTests: XCTestCase {
    func testSessionStoreSnapshotRoundTripRestoresSessionsAliasesActiveSelectionAndDrafts() {
        let store = SessionStore()

        let temporary = makeSession(id: "temp-session", createdAt: 100, lastActiveAt: 101)
        let stable = makeSession(id: "stable-session", createdAt: 100, lastActiveAt: 150)

        _ = store.applySessionList([temporary])
        store.setActiveSession(id: temporary.id)
        store.setDraft("continue", for: temporary.id)
        _ = store.applySessionList([stable])

        let restored = SessionStore()
        restored.restore(from: store.snapshot())

        XCTAssertEqual(restored.sessions, store.sessions)
        XCTAssertEqual(restored.activeSessionId, stable.id)
        XCTAssertEqual(restored.resolvedSessionId(for: temporary.id), stable.id)
        XCTAssertEqual(restored.draft(for: stable.id), "continue")
    }

    func testTimelineStoreKeepsItemsSortedWhenEarlierCommandIsStagedLater() {
        let store = TimelineStore()

        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .status(state: .thinking, message: "Working"),
            timestamp: 20
        )
        store.appendUserCommand("run tests", sessionId: "session-1", timestamp: 10)

        XCTAssertEqual(
            store.timeline(for: "session-1").map(\.kind),
            [
                .userCommand(text: "run tests"),
                .status(state: .thinking, message: "Working"),
            ]
        )
    }

    func testConversationSnapshotStoreRoundTripsSessionTimelineFilesAndConnectionMapping() throws {
        let suiteName = "ConversationSnapshotStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()

        let session = makeSession(id: "session-1", createdAt: 100, lastActiveAt: 200)
        _ = sessionStore.applySessionList([session])
        sessionStore.setActiveSession(id: session.id)
        sessionStore.setDraft("follow-up", for: session.id)
        timelineStore.appendUserCommand("first prompt", sessionId: session.id, timestamp: 10)
        fileStore.markRequested(path: "README.md", sessionId: session.id)
        fileStore.routeFileContent(path: "README.md", content: "hello", language: "markdown")

        let store = ConversationSnapshotStore(userDefaults: defaults)
        let snapshot = ConversationSnapshot(
            sessionStore: sessionStore.snapshot(),
            timelineStore: timelineStore.snapshot(),
            fileStore: fileStore.snapshot(),
            sessionToConnectionID: [session.id: "connection-1"]
        )

        try store.saveSnapshot(snapshot)

        XCTAssertEqual(store.loadSnapshot(), snapshot)
    }
}

private extension StoreSnapshotTests {
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
