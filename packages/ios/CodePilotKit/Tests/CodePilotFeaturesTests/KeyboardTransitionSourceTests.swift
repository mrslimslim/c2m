import XCTest

final class KeyboardTransitionSourceTests: XCTestCase {
    func testSessionDetailViewDismissesKeyboardBeforePresentingDeletionAndFileRequestFlows() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("prepareForModalTransition {") && source.contains("showDeleteConfirmation = true"),
            "Session detail should clear active text input before presenting the delete confirmation."
        )

        XCTAssertTrue(
            source.contains("prepareForModalTransition {") && source.contains("showFileRequest = true"),
            "Session detail should clear active text input before presenting the file request sheet."
        )

        XCTAssertTrue(
            source.contains("private func deleteSession()") && source.contains("prepareForModalTransition()"),
            "Session deletion should clear the keyboard session before dismissing the screen."
        )
        XCTAssertTrue(
            source.contains("DispatchQueue.main.async {") && source.contains("dismiss()"),
            "Session deletion should defer the view dismissal until after the keyboard has been asked to resign."
        )
        XCTAssertTrue(
            source.contains("@FocusState private var isFileRequestFocused: Bool"),
            "The file request sheet should manage its own text-field focus."
        )
        XCTAssertTrue(
            source.contains("private func resignActiveTextInput()"),
            "Session detail should centralize keyboard resignation for modal transitions."
        )
    }

    func testNewSessionSheetsDismissKeyboardBeforeClosing() throws {
        let projectSource = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Projects/ProjectDetailView.swift"
        )
        let sessionsSource = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionsView.swift"
        )

        XCTAssertTrue(
            projectSource.contains("private func prepareForDismiss()"),
            "Project-scoped new session sheet should resign focus before dismissing."
        )
        XCTAssertTrue(
            projectSource.contains("prepareForDismiss()\n        do {"),
            "Project-scoped new session send flow should resign focus before closing the sheet."
        )
        XCTAssertTrue(
            projectSource.contains("DispatchQueue.main.async {") && projectSource.contains("dismiss()"),
            "Project-scoped new session sheet should dismiss on the next run loop after resigning focus."
        )

        XCTAssertTrue(
            sessionsSource.contains("@FocusState private var isFocused: Bool"),
            "Global sessions sheet should track text-field focus so it can close cleanly."
        )
        XCTAssertTrue(
            sessionsSource.contains("private func prepareForDismiss()"),
            "Global sessions sheet cancel action should resign focus before dismissing."
        )
        XCTAssertTrue(
            sessionsSource.contains("prepareForDismiss()\n        do {"),
            "Global sessions sheet send flow should resign focus before closing the sheet."
        )
        XCTAssertTrue(
            sessionsSource.contains("DispatchQueue.main.async {") && sessionsSource.contains("dismiss()"),
            "Global sessions sheet should dismiss on the next run loop after resigning focus."
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
