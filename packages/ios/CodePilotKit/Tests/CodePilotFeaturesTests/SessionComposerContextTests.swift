import XCTest
@testable import CodePilotFeatures
import CodePilotProtocol

final class SessionComposerContextTests: XCTestCase {
    func testDetectsActiveFileSearchTriggerFromDraftTail() {
        let context = SessionComposerContext(draft: "@turnv")

        XCTAssertEqual(context.activeFileSearchQuery, "turnv")
    }

    func testDetectsActiveFileSearchTriggerFromTrailingTokenWithinDraft() {
        let context = SessionComposerContext(draft: "Explain @turnv")

        XCTAssertEqual(context.activeFileSearchQuery, "turnv")
    }

    func testSelectingFileConvertsTailIntoChipAndLeavesRemainingDraft() {
        var context = SessionComposerContext(draft: "@turnv explain this")

        context.insertFile(
            .init(
                path: "Sources/TurnView.swift",
                displayName: "TurnView.swift",
                directoryHint: "Sources"
            )
        )

        XCTAssertEqual(context.selectedFiles.map(\.path), ["Sources/TurnView.swift"])
        XCTAssertEqual(context.draft, " explain this")
    }

    func testSelectingFileReplacesTrailingQueryWhilePreservingLeadingText() {
        var context = SessionComposerContext(draft: "Explain @turnv")

        context.insertFile(
            .init(
                path: "Sources/TurnView.swift",
                displayName: "TurnView.swift",
                directoryHint: "Sources"
            )
        )

        XCTAssertEqual(context.selectedFiles.map(\.path), ["Sources/TurnView.swift"])
        XCTAssertEqual(context.draft, "Explain ")
    }

    func testSerializedSendTextPrefixesSelectedFilesAsPlainTextMentions() {
        var context = SessionComposerContext(draft: "Explain this view")
        context.selectedFiles = [
            .init(
                path: "Sources/TurnView.swift",
                displayName: "TurnView.swift",
                directoryHint: "Sources"
            )
        ]

        XCTAssertEqual(context.serializedCommandText, "@Sources/TurnView.swift Explain this view")
    }
}
