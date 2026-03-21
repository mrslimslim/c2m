import XCTest
@testable import CodePilotFeatures
@testable import CodePilotCore
import CodePilotProtocol

final class SessionDetailViewModelTests: XCTestCase {
    func testSendDraftWithoutActiveSessionSendsCommandWithNilSessionId() throws {
        let sender = MockPhoneMessageSender()
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let viewModel = SessionDetailViewModel(
            sender: sender,
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore
        )

        viewModel.draft = "create new session command"
        try viewModel.sendDraft()

        XCTAssertEqual(sender.messages, [.command(text: "create new session command", sessionId: nil, config: nil)])
        XCTAssertEqual(viewModel.draft, "")
    }

    func testSendDraftAppendsUserCommandAndSendsCommand() throws {
        let sender = MockPhoneMessageSender()
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let session = makeSession(id: "session-1", state: .idle)
        _ = sessionStore.applySessionList([session])
        sessionStore.setActiveSession(id: session.id)

        let viewModel = SessionDetailViewModel(
            sender: sender,
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore
        )

        viewModel.draft = "swift test"
        try viewModel.sendDraft()

        XCTAssertEqual(sender.messages, [.command(text: "swift test", sessionId: session.id, config: nil)])
        XCTAssertEqual(timelineStore.timeline(for: session.id).map(\.kind), [.userCommand(text: "swift test")])
        XCTAssertEqual(sessionStore.session(for: session.id)?.state, .thinking)
        XCTAssertEqual(viewModel.draft, "")
    }

    func testSendDraftFailureDoesNotAppendPhantomTimelineItem() throws {
        let sender = MockPhoneMessageSender()
        sender.error = MockPhoneMessageSenderError.sendFailed

        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let session = makeSession(id: "session-1", state: .idle)
        _ = sessionStore.applySessionList([session])
        sessionStore.setActiveSession(id: session.id)

        let viewModel = SessionDetailViewModel(
            sender: sender,
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore
        )
        viewModel.draft = "swift test"

        XCTAssertThrowsError(try viewModel.sendDraft())
        XCTAssertEqual(sender.messages, [])
        XCTAssertEqual(timelineStore.timeline(for: session.id), [])
        XCTAssertEqual(viewModel.draft, "swift test")
    }

    func testCancelOnlySendsWhileSessionIsBusy() throws {
        let sender = MockPhoneMessageSender()
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let busySession = makeSession(id: "session-1", state: .thinking)
        _ = sessionStore.applySessionList([busySession])
        sessionStore.setActiveSession(id: busySession.id)

        let viewModel = SessionDetailViewModel(
            sender: sender,
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore
        )

        try viewModel.cancel()
        XCTAssertEqual(sender.messages, [.cancel(sessionId: busySession.id)])

        let idleSession = makeSession(id: "session-1", state: .idle)
        _ = sessionStore.applySessionList([idleSession])
        try viewModel.cancel()

        XCTAssertEqual(sender.messages, [.cancel(sessionId: busySession.id)])
    }

    func testFileRequestMarksLoadingAndRoutesReturnedFileContent() throws {
        let sender = MockPhoneMessageSender()
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
        let session = makeSession(id: "session-1", state: .coding)
        _ = sessionStore.applySessionList([session])
        sessionStore.setActiveSession(id: session.id)

        let viewModel = SessionDetailViewModel(
            sender: sender,
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore
        )

        try viewModel.requestFile(path: "Sources/App.swift")

        XCTAssertEqual(sender.messages, [.fileRequest(path: "Sources/App.swift", sessionId: session.id)])
        XCTAssertEqual(viewModel.fileState(for: "Sources/App.swift")?.isLoading, true)

        router.handle(.fileContent(path: "Sources/App.swift", content: "print(\"hi\")", language: "swift"))

        XCTAssertEqual(viewModel.fileState(for: "Sources/App.swift")?.isLoading, false)
        XCTAssertEqual(viewModel.fileState(for: "Sources/App.swift")?.content, "print(\"hi\")")
        XCTAssertEqual(viewModel.fileState(for: "Sources/App.swift")?.language, "swift")
    }

    func testRequestFileWithSynchronousResponseDoesNotRegressToLoadingState() throws {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let session = makeSession(id: "session-1", state: .coding)
        _ = sessionStore.applySessionList([session])
        sessionStore.setActiveSession(id: session.id)

        let sender = ReentrantFileMessageSender { message in
            guard case let .fileRequest(path, _) = message else {
                return
            }
            fileStore.routeFileContent(path: path, content: "loaded", language: "swift")
        }

        let viewModel = SessionDetailViewModel(
            sender: sender,
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore
        )

        try viewModel.requestFile(path: "Sources/App.swift")

        XCTAssertEqual(sender.messages, [.fileRequest(path: "Sources/App.swift", sessionId: session.id)])
        XCTAssertEqual(viewModel.fileState(for: "Sources/App.swift")?.isLoading, false)
        XCTAssertEqual(viewModel.fileState(for: "Sources/App.swift")?.content, "loaded")
        XCTAssertEqual(viewModel.fileState(for: "Sources/App.swift")?.language, "swift")
    }

    func testRequestFileFailureDoesNotCreateLoadingOrPendingState() throws {
        let sender = MockPhoneMessageSender()
        sender.error = MockPhoneMessageSenderError.sendFailed

        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let session = makeSession(id: "session-1", state: .coding)
        _ = sessionStore.applySessionList([session])
        sessionStore.setActiveSession(id: session.id)
        let viewModel = SessionDetailViewModel(
            sender: sender,
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore
        )

        XCTAssertThrowsError(try viewModel.requestFile(path: "Sources/App.swift"))
        XCTAssertEqual(sender.messages, [])
        XCTAssertNil(viewModel.fileState(for: "Sources/App.swift"))

        fileStore.routeFileContent(path: "Sources/App.swift", content: "unexpected", language: "swift")
        XCTAssertNil(viewModel.fileState(for: "Sources/App.swift"))
    }
}

private enum MockPhoneMessageSenderError: Error {
    case sendFailed
}

private final class MockPhoneMessageSender: PhoneMessageSending {
    private(set) var messages: [PhoneMessage] = []
    var error: Error?

    func send(_ message: PhoneMessage) throws {
        if let error {
            throw error
        }
        messages.append(message)
    }
}

private final class ReentrantFileMessageSender: PhoneMessageSending {
    private(set) var messages: [PhoneMessage] = []
    private let onSend: (PhoneMessage) -> Void

    init(onSend: @escaping (PhoneMessage) -> Void) {
        self.onSend = onSend
    }

    func send(_ message: PhoneMessage) throws {
        messages.append(message)
        onSend(message)
    }
}

private extension SessionDetailViewModelTests {
    func makeSession(id: String, state: AgentState) -> SessionInfo {
        .init(
            id: id,
            agentType: .codex,
            workDir: "/tmp/repo",
            state: state,
            createdAt: 1_700_000_000,
            lastActiveAt: 1_700_000_111
        )
    }
}
