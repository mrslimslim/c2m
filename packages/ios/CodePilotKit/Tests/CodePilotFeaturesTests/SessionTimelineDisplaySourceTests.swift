import XCTest

final class SessionTimelineDisplaySourceTests: XCTestCase {
    func testSessionDetailSourceRendersStructuredToolCardsForToolStatusMessages() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("TimelineToolEventParser.parse(statusMessage: message)"),
            "Tool-like status events should be parsed into structured cards instead of rendering as raw inline text."
        )
        XCTAssertTrue(
            source.contains("ToolEventCard("),
            "Parsed tool events should render with a dedicated card view."
        )
    }

    func testSessionDetailSourceShowsTodoListItemsInlineInsideToolCards() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("if !presentation.todoItems.isEmpty {"),
            "Todo list tool cards should render parsed checklist items inline instead of forcing users to expand raw JSON."
        )
        XCTAssertTrue(
            source.contains("ForEach(Array(presentation.todoItems.enumerated()), id: \\.offset)"),
            "Todo list tool cards should iterate over each parsed todo item."
        )
        XCTAssertTrue(
            source.contains("checkmark.circle.fill") && source.contains("circle"),
            "Todo list rows should visually distinguish completed and pending work."
        )
    }

    func testSessionDetailSourceShowsSearchQueriesAndMetadataInlineForToolCards() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains("if !presentation.searchQueries.isEmpty {"),
            "Web search tool cards should render parsed search queries inline."
        )
        XCTAssertTrue(
            source.contains("if !presentation.metadataRows.isEmpty {"),
            "Specialized tool cards should render labeled metadata rows inline."
        )
        XCTAssertTrue(
            source.contains("Text(\"Queries\")") && source.contains("row.label"),
            "Tool cards should label their query and metadata sections instead of showing only a single summary line."
        )
    }

    func testSessionDetailSourceAllowsCommandCardsToExpandBeyondASingleLine() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/Sessions/SessionDetailView.swift"
        )

        XCTAssertTrue(
            source.contains(".lineLimit(isExpanded ? nil : 3)"),
            "Long command lines should preview across multiple lines and expand fully when opened."
        )
        XCTAssertFalse(
            source.contains(
                """
                Text(command)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(CPTheme.terminalText)
                        .lineLimit(1)
                """
            ),
            "Command execution cards should no longer hard-truncate the command to a single line."
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
