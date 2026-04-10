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

    func testLegacyEventWithoutEventIDStillAppendsTimelineContent() {
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

        router.handle(
            .event(
                sessionId: session.id,
                event: .agentMessage(text: "legacy output"),
                eventId: 0,
                timestamp: 1
            )
        )

        XCTAssertEqual(
            timelineStore.timeline(for: session.id).map(\.kind),
            [.agentMessage(text: "legacy output")]
        )
        XCTAssertNil(
            sessionStore.lastAppliedEventID(for: session.id),
            "legacy events should remain compatible without inventing replay cursors"
        )
    }

    func testCodeChangeTimelineItemPreservesBridgeEventID() {
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

        router.handle(
            .event(
                sessionId: session.id,
                event: .codeChange(changes: [.init(path: "Sources/App.swift", kind: .update)]),
                eventId: 1,
                timestamp: 10
            )
        )

        XCTAssertEqual(timelineStore.timeline(for: session.id).first?.eventId, 1)
    }

    func testDiffRoutingStoresInitialDiffAndAppendsLaterHunks() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diffStore = DiffStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diffStore: diffStore,
            diagnostics: diagnostics
        )

        router.handle(
            .diffContent(
                sessionId: "session-1",
                eventId: 42,
                files: [
                    .init(
                        path: "Sources/App.swift",
                        kind: .update,
                        addedLines: 2,
                        deletedLines: 1,
                        isTruncated: false,
                        totalHunkCount: 2,
                        loadedHunks: [
                            .init(
                                oldStart: 1,
                                oldLineCount: 1,
                                newStart: 1,
                                newLineCount: 2,
                                lines: [
                                    .init(kind: .delete, text: "-let value = 1"),
                                    .init(kind: .add, text: "+let value = 2"),
                                ]
                            )
                        ],
                        nextHunkIndex: 1
                    )
                ]
            )
        )

        XCTAssertEqual(diffStore.state(for: "session-1", eventId: 42)?.files.first?.loadedHunks.count, 1)
        XCTAssertEqual(diffStore.state(for: "session-1", eventId: 42)?.files.first?.nextHunkIndex, 1)

        router.handle(
            .diffHunksContent(
                sessionId: "session-1",
                eventId: 42,
                path: "Sources/App.swift",
                hunks: [
                    .init(
                        oldStart: 9,
                        oldLineCount: 1,
                        newStart: 10,
                        newLineCount: 2,
                        lines: [
                            .init(kind: .context, text: " func run() {}"),
                            .init(kind: .add, text: "+print(value)"),
                        ]
                    )
                ],
                nextHunkIndex: nil
            )
        )

        XCTAssertEqual(diffStore.state(for: "session-1", eventId: 42)?.files.first?.loadedHunks.count, 2)
        XCTAssertNil(diffStore.state(for: "session-1", eventId: 42)?.files.first?.nextHunkIndex)
    }

    func testRouterRoutesFileSearchResultsToStore() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let fileSearchStore = FileSearchStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            fileSearchStore: fileSearchStore,
            diagnostics: diagnostics
        )
        let session = makeSession(id: "session-1", state: .coding, createdAt: 1_700_000_000, lastActiveAt: 1_700_000_001)
        router.handle(.sessionList(sessions: [session]))

        router.handle(
            .fileSearchResults(
                sessionId: session.id,
                query: "turnview",
                results: [
                    .init(
                        path: "Sources/TurnView.swift",
                        displayName: "TurnView.swift",
                        directoryHint: "Sources"
                    )
                ]
            )
        )

        XCTAssertEqual(
            fileSearchStore.state(for: session.id),
            .init(
                query: "turnview",
                results: [
                    .init(
                        path: "Sources/TurnView.swift",
                        displayName: "TurnView.swift",
                        directoryHint: "Sources"
                    )
                ],
                isLoading: false,
                errorMessage: nil
            )
        )
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

    func testIncomingConcreteSessionIdDoesNotReusePersistedAliasReplayCursor() {
        let originalStore = SessionStore()
        let oldSession = makeSession(
            id: "old-real-session",
            state: .idle,
            createdAt: 1_700_000_100,
            lastActiveAt: 1_700_000_101
        )
        originalStore.upsert(oldSession)
        _ = originalStore.applySessionRemap(from: "codex-2", to: oldSession.id)
        originalStore.recordAppliedEventID(6, for: oldSession.id)

        let sessionStore = SessionStore()
        sessionStore.restore(from: originalStore.snapshot())
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let diagnostics = DiagnosticsStore()
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            diagnostics: diagnostics
        )

        let freshSession = makeSession(
            id: "codex-2",
            state: .thinking,
            createdAt: 1_700_000_300,
            lastActiveAt: 1_700_000_301
        )
        router.handle(.sessionList(sessions: [freshSession]))

        var replayRequests: [(String, Int)] = []
        router.onReplayNeeded = { sessionID, afterEventId in
            replayRequests.append((sessionID, afterEventId))
        }

        router.handle(
            .event(
                sessionId: freshSession.id,
                event: .status(state: .thinking, message: "fresh"),
                eventId: 1,
                timestamp: 1
            )
        )

        XCTAssertEqual(sessionStore.resolvedSessionId(for: freshSession.id), freshSession.id)
        XCTAssertEqual(sessionStore.lastAppliedEventID(for: freshSession.id), 1)
        XCTAssertEqual(sessionStore.lastAppliedEventID(for: oldSession.id), 6)
        XCTAssertEqual(replayRequests.map { "\($0.0):\($0.1)" }, [])
        XCTAssertEqual(
            timelineStore.timeline(for: freshSession.id).map(\.kind),
            [.status(state: .thinking, message: "fresh")]
        )
    }

    func testPlaceholderSessionRemapMigratesTimelineDraftFileAndActiveSelection() {
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

        sessionStore.updateState(for: "temp-session", state: .thinking)
        sessionStore.setActiveSession(id: "temp-session")
        sessionStore.setDraft("continue with refactor", for: "temp-session")
        timelineStore.appendUserCommand("run tests", sessionId: "temp-session", timestamp: 1_700_000_105)
        fileStore.markRequested(path: "README.md", sessionId: "temp-session")
        fileStore.routeFileContent(path: "README.md", content: "hello", language: "markdown")

        let stableSession = makeSession(
            id: "stable-session",
            state: .thinking,
            createdAt: 1_700_000_100,
            lastActiveAt: 1_700_000_120
        )
        router.handle(.sessionList(sessions: [stableSession]))

        XCTAssertEqual(sessionStore.activeSessionId, stableSession.id)
        XCTAssertEqual(sessionStore.resolvedSessionId(for: "temp-session"), stableSession.id)
        XCTAssertEqual(sessionStore.draft(for: stableSession.id), "continue with refactor")
        XCTAssertEqual(
            timelineStore.timeline(for: stableSession.id).map(\.kind),
            [.userCommand(text: "run tests")]
        )
        XCTAssertEqual(timelineStore.timeline(for: "temp-session"), [])
        XCTAssertEqual(
            fileStore.fileState(for: "README.md", sessionId: stableSession.id)?.content,
            "hello"
        )
        XCTAssertNil(fileStore.fileState(for: "README.md", sessionId: "temp-session"))
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
