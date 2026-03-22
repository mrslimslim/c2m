import XCTest

final class SessionAliasLookupSourceTests: XCTestCase {
    func testAppModelSessionLookupsResolveSessionAliasesBeforeReadingStores() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertTrue(
            source.contains("let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID"),
            "AppModel session lookups should resolve aliased temporary session IDs before querying view data."
        )
        XCTAssertTrue(
            source.contains("sessions.first(where: { $0.id == resolvedSessionID })"),
            "AppModel should use the canonical session ID when reading the published session list."
        )
        XCTAssertTrue(
            source.contains("timelineStore.timeline(for: resolvedSessionID)"),
            "AppModel should use the canonical session ID when reading the session timeline."
        )
        XCTAssertTrue(
            source.contains("fileStore.files(for: resolvedSessionID)"),
            "AppModel should use the canonical session ID when reading session file state."
        )
    }

    private func loadAppSource(at relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
