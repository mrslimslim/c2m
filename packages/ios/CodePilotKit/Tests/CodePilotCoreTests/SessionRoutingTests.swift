import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class SessionRoutingTests: XCTestCase {
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

        router.handle(.event(sessionId: session.id, event: .status(state: .thinking, message: "working"), timestamp: 1))
        router.handle(.event(sessionId: session.id, event: .thinking(text: "step-by-step"), timestamp: 2))
        router.handle(.event(sessionId: session.id, event: .agentMessage(text: "done"), timestamp: 3))
        router.handle(.event(sessionId: session.id, event: .codeChange(changes: [.init(path: "a.swift", kind: .update)]), timestamp: 4))
        router.handle(
            .event(
                sessionId: session.id,
                event: .commandExec(command: "swift test", output: "ok", exitCode: 0, status: .done),
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
                timestamp: 6
            )
        )
        router.handle(.event(sessionId: session.id, event: .error(message: "session failed"), timestamp: 7))

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
        router.handle(.event(sessionId: session.id, event: .error(message: "command failed"), timestamp: 10))

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
