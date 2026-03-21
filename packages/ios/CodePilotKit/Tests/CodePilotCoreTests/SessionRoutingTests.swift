import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class SessionRoutingTests: XCTestCase {
    func testDuplicateEventIDIsIgnored() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diagnostics: diagnostics
        )
        let session = makeSession(id: "session-1", state: .thinking, createdAt: 1_700_000_000, lastActiveAt: 1_700_000_001)
        router.handle(.sessionList(sessions: [session]))

        router.handle(.event(sessionId: session.id, event: .thinking(text: "first"), eventId: 1, timestamp: 1))
        router.handle(.event(sessionId: session.id, event: .thinking(text: "duplicate"), eventId: 1, timestamp: 2))

        XCTAssertEqual(
            timelineStore.timeline(for: session.id).map(\.kind),
            [.thinking(text: "first")]
        )
        XCTAssertEqual(sessionStore.lastAppliedEventID(for: session.id), 1)
    }

    func testEventGapRequestsReplayInsteadOfAppendingOutOfOrderItem() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diagnostics: diagnostics
        )
        let session = makeSession(id: "session-1", state: .thinking, createdAt: 1_700_000_000, lastActiveAt: 1_700_000_001)
        router.handle(.sessionList(sessions: [session]))

        var replayRequests: [(String, Int)] = []
        router.onReplayNeeded = { sessionID, afterEventId in
            replayRequests.append((sessionID, afterEventId))
        }

        router.handle(.event(sessionId: session.id, event: .thinking(text: "first"), eventId: 1, timestamp: 1))
        router.handle(.event(sessionId: session.id, event: .agentMessage(text: "third"), eventId: 3, timestamp: 3))

        XCTAssertEqual(
            timelineStore.timeline(for: session.id).map(\.kind),
            [.thinking(text: "first")]
        )
        XCTAssertEqual(replayRequests.map { "\($0.0):\($0.1)" }, ["session-1:1"])
        XCTAssertEqual(sessionStore.lastAppliedEventID(for: session.id), 1)
    }

    func testSessionSyncCompleteResolvedSessionIDMigratesReplayState() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diagnostics: diagnostics
        )

        let temporarySession = makeSession(
            id: "temp-session",
            state: .thinking,
            createdAt: 1_700_000_100,
            lastActiveAt: 1_700_000_101
        )
        sessionStore.upsert(temporarySession)
        sessionStore.setActiveSession(id: temporarySession.id)
        sessionStore.setDraft("continue", for: temporarySession.id)
        sessionStore.recordAppliedEventID(4, for: temporarySession.id)
        timelineStore.appendUserCommand("run tests", sessionId: temporarySession.id, timestamp: 10)
        fileStore.markRequested(path: "README.md", sessionId: temporarySession.id)
        fileStore.routeFileContent(path: "README.md", content: "hello", language: "markdown")

        router.handle(
            .sessionSyncComplete(
                sessionId: temporarySession.id,
                latestEventId: 7,
                resolvedSessionId: "stable-session"
            )
        )

        XCTAssertEqual(sessionStore.sessions.map(\.id), ["stable-session"])
        XCTAssertEqual(sessionStore.activeSessionId, "stable-session")
        XCTAssertEqual(sessionStore.resolvedSessionId(for: temporarySession.id), "stable-session")
        XCTAssertEqual(sessionStore.draft(for: "stable-session"), "continue")
        XCTAssertEqual(sessionStore.lastAppliedEventID(for: temporarySession.id), 7)
        XCTAssertEqual(sessionStore.lastAppliedEventID(for: "stable-session"), 7)
        XCTAssertEqual(
            timelineStore.timeline(for: "stable-session").map(\.kind),
            [.userCommand(text: "run tests")]
        )
        XCTAssertNil(fileStore.fileState(for: "README.md", sessionId: temporarySession.id))
        XCTAssertEqual(
            fileStore.fileState(for: "README.md", sessionId: "stable-session")?.content,
            "hello"
        )
    }

    func testSessionListUpdatesAndKeepsExplicitActiveSelection() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diagnostics: diagnostics
        )

        let older = makeSession(
            id: "session-1",
            state: .idle,
            createdAt: 1_700_000_000,
            lastActiveAt: 1_700_000_010
        )
        let newer = makeSession(
            id: "session-2",
            state: .thinking,
            createdAt: 1_700_000_001,
            lastActiveAt: 1_700_000_020
        )

        router.handle(.sessionList(sessions: [older, newer]))
        XCTAssertEqual(sessionStore.sessions.map(\.id), ["session-2", "session-1"])
        XCTAssertEqual(sessionStore.activeSessionId, "session-2")

        sessionStore.setActiveSession(id: "session-1")
        router.handle(.sessionList(sessions: [older, newer]))
        XCTAssertEqual(sessionStore.activeSessionId, "session-1")
    }

    func testSessionIdRemapMigratesTimelineDraftFileAndActiveSelection() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diagnostics: diagnostics
        )

        let temporarySession = makeSession(
            id: "codex-temp-1",
            state: .thinking,
            createdAt: 1_700_000_100,
            lastActiveAt: 1_700_000_101
        )
        router.handle(.sessionList(sessions: [temporarySession]))
        sessionStore.setActiveSession(id: temporarySession.id)
        sessionStore.setDraft("continue with refactor", for: temporarySession.id)
        timelineStore.appendUserCommand("run tests", sessionId: temporarySession.id, timestamp: 1_700_000_105)
        fileStore.markRequested(path: "README.md", sessionId: temporarySession.id)
        fileStore.routeFileContent(path: "README.md", content: "hello", language: "markdown")

        let remappedSession = makeSession(
            id: "thread_real_123",
            state: .thinking,
            createdAt: 1_700_000_100,
            lastActiveAt: 1_700_000_120
        )
        router.handle(.sessionList(sessions: [remappedSession]))

        XCTAssertEqual(sessionStore.activeSessionId, remappedSession.id)
        XCTAssertEqual(sessionStore.draft(for: remappedSession.id), "continue with refactor")
        XCTAssertEqual(
            timelineStore.timeline(for: remappedSession.id).map(\.kind),
            [.userCommand(text: "run tests")]
        )
        XCTAssertEqual(timelineStore.timeline(for: temporarySession.id), [])
        XCTAssertEqual(
            fileStore.fileState(for: "README.md", sessionId: remappedSession.id)?.content,
            "hello"
        )
        XCTAssertNil(fileStore.fileState(for: "README.md", sessionId: temporarySession.id))
    }

    func testTimelineCreatesItemForEveryAgentEventType() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diagnostics: diagnostics
        )
        let session = makeSession(id: "session-1", state: .thinking, createdAt: 1_700_000_000, lastActiveAt: 1_700_000_001)
        router.handle(.sessionList(sessions: [session]))

        router.handle(.event(sessionId: session.id, event: .status(state: .thinking, message: "working"), eventId: 1, timestamp: 1))
        router.handle(.event(sessionId: session.id, event: .thinking(text: "step-by-step"), eventId: 2, timestamp: 2))
        router.handle(.event(sessionId: session.id, event: .agentMessage(text: "done"), eventId: 3, timestamp: 3))
        router.handle(.event(sessionId: session.id, event: .codeChange(changes: [.init(path: "a.swift", kind: .update)]), eventId: 4, timestamp: 4))
        router.handle(
            .event(
                sessionId: session.id,
                event: .commandExec(command: "swift test", output: "ok", exitCode: 0, status: .done),
                eventId: 5,
                timestamp: 5
            )
        )
        router.handle(
            .event(
                sessionId: session.id,
                event: .turnCompleted(
                    summary: "completed",
                    filesChanged: ["a.swift"],
                    usage: .init(inputTokens: 10, outputTokens: 3, cachedInputTokens: nil)
                ),
                eventId: 6,
                timestamp: 6
            )
        )
        router.handle(.event(sessionId: session.id, event: .error(message: "session failed"), eventId: 7, timestamp: 7))

        XCTAssertEqual(
            timelineStore.timeline(for: session.id).map(\.kind),
            [
                .status(state: .thinking, message: "working"),
                .thinking(text: "step-by-step"),
                .agentMessage(text: "done"),
                .codeChange(changes: [.init(path: "a.swift", kind: .update)]),
                .commandExec(command: "swift test", output: "ok", exitCode: 0, status: .done),
                .turnCompleted(
                    summary: "completed",
                    filesChanged: ["a.swift"],
                    usage: .init(inputTokens: 10, outputTokens: 3, cachedInputTokens: nil)
                ),
                .sessionError(message: "session failed"),
            ]
        )
    }

    func testTopLevelBridgeErrorsStaySeparateFromSessionErrors() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diagnostics: diagnostics
        )
        let session = makeSession(id: "session-1", state: .thinking, createdAt: 1_700_000_000, lastActiveAt: 1_700_000_001)
        router.handle(.sessionList(sessions: [session]))

        router.handle(.error(message: "bridge disconnected"))
        router.handle(.event(sessionId: session.id, event: .error(message: "command failed"), eventId: 1, timestamp: 10))

        XCTAssertEqual(timelineStore.transportTimeline.map(\.kind), [.transportError(message: "bridge disconnected")])
        XCTAssertEqual(timelineStore.timeline(for: session.id).map(\.kind), [.sessionError(message: "command failed")])
    }
}

private extension SessionRoutingTests {
    func makeSession(
        id: String,
        state: AgentState,
        createdAt: Int,
        lastActiveAt: Int
    ) -> SessionInfo {
        .init(
            id: id,
            agentType: .codex,
            workDir: "/tmp/repo",
            state: state,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt
        )
    }
}
