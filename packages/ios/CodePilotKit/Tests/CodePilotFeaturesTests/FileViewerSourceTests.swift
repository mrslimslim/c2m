import XCTest

final class FileViewerSourceTests: XCTestCase {
    func testFileViewerSourceUsesSingleAxisScrollingAndSyntaxHighlighting() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Files/FileViewerView.swift"
        )

        XCTAssertTrue(
            source.contains("ScrollView(.vertical)"),
            "The file viewer should prefer a stable vertical scroller instead of a freeform two-axis canvas."
        )
        XCTAssertFalse(
            source.contains("ScrollView([.horizontal, .vertical])"),
            "The file viewer should no longer use a dual-axis scroll view that can feel like the file drifts under touch."
        )
        XCTAssertTrue(
            source.contains("CodeSyntaxHighlighter"),
            "The file viewer should define a lightweight syntax highlighter so code is easier to scan."
        )
        XCTAssertTrue(
            source.contains("CPTheme.shortPath(file.path)"),
            "The file viewer should surface compact file metadata above the code block."
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
