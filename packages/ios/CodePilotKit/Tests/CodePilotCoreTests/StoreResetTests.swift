import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class StoreResetTests: XCTestCase {
    func testSessionStoreResetClearsSessionsAliasesActiveSelectionAndDrafts() {
        let store = SessionStore()

        let temporary = makeSession(id: "temp-session")
        let stable = makeSession(id: "stable-session")

        _ = store.applySessionList([temporary])
        store.setActiveSession(id: temporary.id)
        store.setDraft("continue with refactor", for: temporary.id)

        _ = store.applySessionList([stable])

        XCTAssertEqual(store.resolvedSessionId(for: temporary.id), stable.id)
        XCTAssertEqual(store.activeSessionId, stable.id)
        XCTAssertEqual(store.draft(for: stable.id), "continue with refactor")

        store.reset()

        XCTAssertEqual(store.sessions, [])
        XCTAssertNil(store.activeSessionId)
        XCTAssertEqual(store.draft(for: stable.id), "")
        XCTAssertEqual(store.draft(for: temporary.id), "")
        XCTAssertNil(store.session(for: stable.id))
        XCTAssertNil(store.session(for: temporary.id))
    }

    func testTimelineStoreResetSessionTimelinesKeepsTransportTimeline() {
        let store = TimelineStore()

        store.appendUserCommand("swift test", sessionId: "session-1", timestamp: 1)
        store.appendTransportError("bridge disconnected", timestamp: 2)

        store.resetSessionTimelines()

        XCTAssertEqual(store.timeline(for: "session-1"), [])
        XCTAssertEqual(store.transportTimeline.map(\.kind), [.transportError(message: "bridge disconnected")])
    }

    func testFileStoreResetClearsPendingAndResolvedState() {
        let store = FileStore()

        store.markRequested(path: "README.md", sessionId: "session-1")
        store.routeFileContent(path: "README.md", content: "hello", language: "markdown")
        XCTAssertEqual(store.fileState(for: "README.md", sessionId: "session-1")?.content, "hello")

        store.reset()

        XCTAssertNil(store.fileState(for: "README.md", sessionId: "session-1"))
        XCTAssertEqual(store.files(for: "session-1"), [])
    }
}

private extension StoreResetTests {
    func makeSession(id: String) -> SessionInfo {
        .init(
            id: id,
            agentType: .codex,
            workDir: "/tmp/repo",
            state: .thinking,
            createdAt: 1_700_000_100,
            lastActiveAt: 1_700_000_101
        )
    }
}
