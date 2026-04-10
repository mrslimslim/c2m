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

    func testSlashMenuSourceUsesWorkflowProjectionInsteadOfHardCodedCommands() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Theme/SlashCommandMenu.swift"
        )

        XCTAssertTrue(
            source.contains("workflow.projection("),
            "The slash menu should render from projected workflow metadata rather than local hard-coded command lists."
        )
        XCTAssertFalse(
            source.contains("enum SlashCommands"),
            "The slash menu should no longer keep a hard-coded slash command catalog in app source."
        )
    }

    func testComposerSourcesInstantiateSharedSlashWorkflowState() throws {
        let sessionDetailSource = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )
        let projectDetailSource = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Projects/ProjectDetailView.swift"
        )

        XCTAssertTrue(
            sessionDetailSource.contains("@State private var slashWorkflow = SlashWorkflowState()"),
            "The session composer should keep a shared slash workflow state instance for recursive menus."
        )
        XCTAssertTrue(
            projectDetailSource.contains("@State private var slashWorkflow = SlashWorkflowState()"),
            "The new-session composer should reuse the same slash workflow state model as the session composer."
        )
        XCTAssertTrue(
            sessionDetailSource.contains("workflow: $slashWorkflow")
                && projectDetailSource.contains("workflow: $slashWorkflow"),
            "Both composers should pass the shared workflow state into SlashCommandMenu."
        )
    }

    func testSlashMenuSourceConstrainsHeightAndWrapsEntriesInVerticalScrollView() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Theme/SlashCommandMenu.swift"
        )

        XCTAssertTrue(
            source.contains("ScrollView(.vertical"),
            "The slash popup should wrap its entries in a vertical scroll view so long command lists remain reachable."
        )
        XCTAssertTrue(
            source.contains(".frame(maxHeight: 320)"),
            "The slash popup should cap its height so overflow scrolls inside the menu instead of breaking interaction."
        )
    }

    func testSessionDetailSourceIncludesComposerFileChipsAndSessionSwitcher() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("SessionSwitcherSheet("),
            "Session detail should present a searchable session switcher from the header."
        )
        XCTAssertTrue(
            source.contains("ComposerFileChipRow("),
            "Session detail should render selected file chips above the composer input."
        )
        XCTAssertTrue(
            source.contains("onTapGesture") && source.contains("showSessionSwitcher = true"),
            "The conversation header should open the session switcher."
        )
    }

    func testSessionDetailSourceOmitsSpeechControls() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertFalse(
            source.contains("PressToTalkButton("),
            "Session detail should not show a press-to-talk control in the composer row."
        )
        XCTAssertFalse(
            source.contains("SpeechTranscriber"),
            "Session detail should not keep the speech transcriber wired into the composer."
        )
    }

    func testSessionDetailSourceDebouncesFileSearchRequests() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("@State private var pendingFileSearchTask: Task<Void, Never>?"),
            "The session composer should track a cancellable pending file-search task so rapid typing does not flood the bridge."
        )
        XCTAssertTrue(
            source.contains("pendingFileSearchTask?.cancel()"),
            "The session composer should cancel stale file-search work when the query changes."
        )
        XCTAssertTrue(
            source.contains("Task.sleep(for: .milliseconds(180))"),
            "The session composer should debounce bridge-backed file-search requests before sending them."
        )
    }

    func testDiffViewerSourceUsesLazySectionsAndIncrementalHunkActions() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Files/DiffViewerView.swift"
        )

        XCTAssertTrue(
            source.contains("LazyVStack"),
            "The diff viewer should use lazy vertical layout so large multi-file diffs do not mount every row at once."
        )
        XCTAssertTrue(
            source.contains("Load next hunk"),
            "The diff viewer should expose incremental hunk loading rather than rendering the full patch immediately."
        )
        XCTAssertTrue(
            source.contains("Open File"),
            "The diff viewer should keep a fallback action for opening the current file contents."
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
