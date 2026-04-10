import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class FileSearchStoreTests: XCTestCase {
    func testFileSearchStoreTracksLoadingResultsAndErrorsPerSession() {
        let store = FileSearchStore()

        store.markRequested(query: "turnview", sessionId: "session-1")
        XCTAssertEqual(
            store.state(for: "session-1"),
            .init(query: "turnview", results: [], isLoading: true, errorMessage: nil)
        )

        let match = FileSearchMatch(
            path: "Sources/TurnView.swift",
            displayName: "TurnView.swift",
            directoryHint: "Sources"
        )
        store.routeResults(sessionId: "session-1", query: "turnview", results: [match])
        XCTAssertEqual(
            store.state(for: "session-1"),
            .init(query: "turnview", results: [match], isLoading: false, errorMessage: nil)
        )

        store.markFailed(query: "turnview", sessionId: "session-2", message: "Offline")
        XCTAssertEqual(
            store.state(for: "session-2"),
            .init(query: "turnview", results: [], isLoading: false, errorMessage: "Offline")
        )
    }
}
