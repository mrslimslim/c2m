import XCTest

final class SessionCopyInteractionSourceTests: XCTestCase {
    func testSessionDetailSourceAddsConversationCopyToolbarAction() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("private var conversationTranscript: String"),
            "The session detail view should build a transcript string so the full conversation can be copied in one action."
        )
        XCTAssertTrue(
            source.contains("copyConversationTranscript()"),
            "The session detail view should expose an explicit copy-conversation action."
        )
        XCTAssertTrue(
            source.contains("Label(\"Copy Conversation\", systemImage: \"doc.on.doc\")"),
            "The toolbar should advertise a dedicated copy-conversation affordance."
        )
        XCTAssertTrue(
            source.contains("Image(systemName: \"trash\")"),
            "The session detail toolbar should keep the delete-session affordance available."
        )
        XCTAssertFalse(
            source.contains("Image(systemName: \"doc.badge.plus\")"),
            "The session detail toolbar should no longer expose the add-file affordance."
        )
    }

    func testSessionDetailSourceAddsLongPressCopyMenuToTimelineCells() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("private var copyPayload: (title: String, text: String)?"),
            "Timeline cells should compute copy payloads for the kinds of items that users may want to copy."
        )
        XCTAssertTrue(
            source.contains(".contextMenu"),
            "Timeline cells should offer a long-press context menu so messages can be copied reliably."
        )
        XCTAssertTrue(
            source.contains("Label(copyPayload.title, systemImage: \"doc.on.doc\")"),
            "The long-press menu should present a clear copy action for the current timeline item."
        )
    }

    func testSessionDetailSourceNavigatesCodeChangesIntoDedicatedDiffViewer() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("DiffViewerView("),
            "Code change entries should navigate into a dedicated diff viewer screen instead of rendering full patches inline."
        )
        XCTAssertTrue(
            source.contains("View Diff"),
            "The session detail source should expose an explicit View Diff affordance for code changes."
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
