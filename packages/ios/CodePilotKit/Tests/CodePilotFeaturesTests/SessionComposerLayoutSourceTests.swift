import XCTest

final class SessionComposerLayoutSourceTests: XCTestCase {
    func testComposerSourceCentersRowAndAddsChipTopPadding() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("HStack(alignment: .center, spacing: 8)"),
            "The session composer row should center-align the slash button, text field, and send button."
        )
        XCTAssertTrue(
            source.contains(
                """
                ConfigChips(config: $sessionConfig)
                                    .padding(.top, 6)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
                """
            ),
            "Selected config chips should have top breathing room before the composer field."
        )
    }

    func testComposerSourceUsesConsistentButtonHitAreas() throws {
        let sessionDetailSource = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )
        let slashMenuSource = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Theme/SlashCommandMenu.swift"
        )

        XCTAssertTrue(
            sessionDetailSource.contains(".frame(width: 40, height: 40)"),
            "The send button should reserve a stable 40pt hit area so it can stay centered beside the input."
        )
        XCTAssertTrue(
            slashMenuSource.contains(".frame(width: 40, height: 40)"),
            "The slash hint button should reserve a stable 40pt hit area so it can stay centered beside the input."
        )
    }

    func testComposerSourceUsesInlineKeyboardDismissControlInsteadOfKeyboardToolbar() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertFalse(
            source.contains("ToolbarItemGroup(placement: .keyboard)"),
            "The session composer should avoid a keyboard accessory toolbar so it does not trigger toolbar width constraint warnings during keyboard presentation."
        )
        XCTAssertTrue(
            source.contains("if isComposerFocused {") && source.contains("keyboard.chevron.compact.down"),
            "The session composer should render an inline keyboard-dismiss control when the composer has focus."
        )
        XCTAssertTrue(
            source.contains("private func dismissComposerKeyboard()"),
            "The session composer should centralize its inline keyboard dismissal behavior."
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
