import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class StoreSnapshotTests: XCTestCase {
    func testSessionStoreSnapshotRoundTripRestoresSessionsAliasesActiveSelectionDraftsAndReplayCursors() {
        let store = SessionStore()

        let temporary = makeSession(id: "temp-session", createdAt: 100, lastActiveAt: 101)
        let stable = makeSession(id: "stable-session", createdAt: 100, lastActiveAt: 150)

        _ = store.applySessionList([temporary])
        store.setActiveSession(id: temporary.id)
        store.setDraft("continue", for: temporary.id)
        store.recordAppliedEventID(7, for: temporary.id)
        _ = store.applySessionList([stable])

        XCTAssertEqual(store.snapshot().lastAppliedEventIdBySessionID[stable.id], 7)

        let restored = SessionStore()
        restored.restore(from: store.snapshot())

        XCTAssertEqual(restored.sessions, store.sessions)
        XCTAssertEqual(restored.activeSessionId, stable.id)
        XCTAssertEqual(restored.resolvedSessionId(for: temporary.id), stable.id)
        XCTAssertEqual(restored.draft(for: stable.id), "continue")
        XCTAssertEqual(restored.lastAppliedEventID(for: stable.id), 7)
        XCTAssertEqual(restored.lastAppliedEventID(for: temporary.id), 7)
    }

    func testSessionStoreExplicitRemapMigratesReplayCursorToCanonicalSessionID() {
        let store = SessionStore()
        let temporary = makeSession(id: "temp-session", createdAt: 100, lastActiveAt: 101)

        store.upsert(temporary)
        store.recordAppliedEventID(4, for: temporary.id)

        XCTAssertEqual(
            store.applySessionRemap(from: temporary.id, to: "stable-session"),
            .init(from: "temp-session", to: "stable-session")
        )
        XCTAssertEqual(store.lastAppliedEventID(for: "stable-session"), 4)
        XCTAssertEqual(store.lastAppliedEventID(for: temporary.id), 4)
        XCTAssertEqual(store.sessions.map(\.id), ["stable-session"])
    }

    func testSessionStoreRemapsPlaceholderSessionToSingleIncomingRealSession() {
        let store = SessionStore()

        store.updateState(for: "temp-session", state: .thinking)
        store.setActiveSession(id: "temp-session")
        store.setDraft("continue", for: "temp-session")

        _ = store.applySessionList(
            [
                .init(
                    id: "stable-session",
                    agentType: .codex,
                    workDir: "/tmp/repo",
                    state: .thinking,
                    createdAt: 100,
                    lastActiveAt: 200
                )
            ]
        )

        XCTAssertEqual(store.activeSessionId, "stable-session")
        XCTAssertEqual(store.resolvedSessionId(for: "temp-session"), "stable-session")
        XCTAssertEqual(store.draft(for: "stable-session"), "continue")
        XCTAssertEqual(store.session(for: "temp-session")?.workDir, "/tmp/repo")
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

    func testTimelineStoreReplacesRunningCommandWithCompletedEntry() {
        let store = TimelineStore()

        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "swift test", output: nil, exitCode: nil, status: .running),
            timestamp: 10
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "swift test", output: "ok", exitCode: 0, status: .done),
            timestamp: 20
        )

        XCTAssertEqual(
            store.timeline(for: "session-1"),
            [
                .init(
                    timestamp: 10,
                    kind: .commandExec(command: "swift test", output: "ok", exitCode: 0, status: .done)
                )
            ]
        )
    }

    func testTimelineStoreKeepsLaterRunOfSameCommandAsSeparateEntry() {
        let store = TimelineStore()

        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "swift test", output: nil, exitCode: nil, status: .running),
            timestamp: 10
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "swift test", output: "ok", exitCode: 0, status: .done),
            timestamp: 20
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "swift test", output: nil, exitCode: nil, status: .running),
            timestamp: 30
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "swift test", output: "still ok", exitCode: 0, status: .done),
            timestamp: 40
        )

        XCTAssertEqual(
            store.timeline(for: "session-1"),
            [
                .init(
                    timestamp: 10,
                    kind: .commandExec(command: "swift test", output: "ok", exitCode: 0, status: .done)
                ),
                .init(
                    timestamp: 30,
                    kind: .commandExec(command: "swift test", output: "still ok", exitCode: 0, status: .done)
                ),
            ]
        )
    }

    func testTimelineStoreCoalescesStreamingAgentMessageSnapshotsAndChunks() {
        let store = TimelineStore()

        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .agentMessage(text: "Hel"),
            timestamp: 10,
            eventId: 1
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .agentMessage(text: "Hello"),
            timestamp: 11,
            eventId: 2
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .agentMessage(text: " world"),
            timestamp: 12,
            eventId: 3
        )

        XCTAssertEqual(
            store.timeline(for: "session-1"),
            [
                .init(
                    eventId: 3,
                    timestamp: 10,
                    kind: .agentMessage(text: "Hello world")
                )
            ]
        )
    }

    func testTimelineStoreCoalescesThinkingAndCommandOutputStreamingUpdates() {
        let store = TimelineStore()

        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .thinking(text: "Think"),
            timestamp: 10,
            eventId: 1
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .thinking(text: "ing"),
            timestamp: 11,
            eventId: 2
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "cargo test", output: "run", exitCode: nil, status: .running),
            timestamp: 12,
            eventId: 3
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "cargo test", output: "running", exitCode: nil, status: .running),
            timestamp: 13,
            eventId: 4
        )
        store.appendBridgeEvent(
            sessionId: "session-1",
            event: .commandExec(command: "cargo test", output: " complete", exitCode: 0, status: .done),
            timestamp: 14,
            eventId: 5
        )

        XCTAssertEqual(
            store.timeline(for: "session-1"),
            [
                .init(
                    eventId: 2,
                    timestamp: 10,
                    kind: .thinking(text: "Thinking")
                ),
                .init(
                    eventId: 5,
                    timestamp: 12,
                    kind: .commandExec(command: "cargo test", output: "running complete", exitCode: 0, status: .done)
                ),
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
        sessionStore.recordAppliedEventID(9, for: session.id)
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

    func testSessionStoreSnapshotDecodesMissingReplayCursorsAsEmptyState() throws {
        let data = Data(
            """
            {
              "sessions": [],
              "activeSessionId": null,
              "draftsBySessionId": {},
              "idAliases": {}
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(SessionStoreSnapshot.self, from: data)

        XCTAssertEqual(snapshot.lastAppliedEventIdBySessionID, [String: Int]())
    }

    func testSessionStoreAcceptsNewerBusySessionListStateOverOlderLocalIdleState() {
        let store = SessionStore()
        store.upsert(
            .init(
                id: "session-1",
                agentType: .codex,
                workDir: "/tmp/repo",
                state: .idle,
                createdAt: 100,
                lastActiveAt: 100
            )
        )

        _ = store.applySessionList(
            [
                .init(
                    id: "session-1",
                    agentType: .codex,
                    workDir: "/tmp/repo",
                    state: .runningCommand,
                    createdAt: 100,
                    lastActiveAt: 200
                )
            ]
        )

        XCTAssertEqual(store.session(for: "session-1")?.state, .runningCommand)
        XCTAssertEqual(store.session(for: "session-1")?.lastActiveAt, 200)
    }

    func testSessionStoreRejectsOlderBusySessionListStateWhenLocalIdleStateIsNewer() {
        let store = SessionStore()
        store.upsert(
            .init(
                id: "session-1",
                agentType: .codex,
                workDir: "/tmp/repo",
                state: .idle,
                createdAt: 100,
                lastActiveAt: 200
            )
        )

        _ = store.applySessionList(
            [
                .init(
                    id: "session-1",
                    agentType: .codex,
                    workDir: "/tmp/repo",
                    state: .thinking,
                    createdAt: 100,
                    lastActiveAt: 100
                )
            ]
        )

        XCTAssertEqual(store.session(for: "session-1")?.state, .idle)
        XCTAssertEqual(store.session(for: "session-1")?.lastActiveAt, 200)
    }

    func testSessionStoreRejectsOlderIdleSessionListStateWhenLocalBusyStateIsNewer() {
        let store = SessionStore()
        store.upsert(
            .init(
                id: "session-1",
                agentType: .codex,
                workDir: "/tmp/repo",
                state: .thinking,
                createdAt: 100,
                lastActiveAt: 200
            )
        )

        _ = store.applySessionList(
            [
                .init(
                    id: "session-1",
                    agentType: .codex,
                    workDir: "/tmp/repo",
                    state: .idle,
                    createdAt: 100,
                    lastActiveAt: 100
                )
            ]
        )

        XCTAssertEqual(store.session(for: "session-1")?.state, .thinking)
        XCTAssertEqual(store.session(for: "session-1")?.lastActiveAt, 200)
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
