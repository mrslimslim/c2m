import XCTest
@testable import CodePilotFeatures

final class TimelineToolEventParserTests: XCTestCase {
    func testParserExtractsTodoListSummaryAndPrettyPrintedPayload() {
        let message = #"[todo_list] {"id":"item_1","items":[{"text":"确认本地可用的运行/验证工具并制定最小实现结构","completed":true},{"text":"先写一个最小失败验证，再实现贪吃蛇页面","completed":false}]}"#

        let presentation = TimelineToolEventParser.parse(statusMessage: message)

        XCTAssertEqual(presentation?.title, "Todo List")
        XCTAssertEqual(presentation?.summary, "1 of 2 completed")
        XCTAssertEqual(presentation?.subtitle, "item_1")
        XCTAssertEqual(presentation?.todoItems.count, 2)
        XCTAssertEqual(presentation?.todoItems.first?.text, "确认本地可用的运行/验证工具并制定最小实现结构")
        XCTAssertEqual(presentation?.todoItems.first?.isCompleted, true)
        XCTAssertEqual(presentation?.todoItems.last?.text, "先写一个最小失败验证，再实现贪吃蛇页面")
        XCTAssertEqual(presentation?.todoItems.last?.isCompleted, false)
        XCTAssertTrue(presentation?.detail.contains("\"completed\" : true") == true)
        XCTAssertTrue(presentation?.detail.contains("\"text\" : \"先写一个最小失败验证，再实现贪吃蛇页面\"") == true)
    }

    func testParserReturnsNilForPlainStatusMessages() {
        XCTAssertNil(TimelineToolEventParser.parse(statusMessage: "Processing..."))
    }

    func testParserBuildsConciseSubtitleForMCPToolCall() {
        let message = #"[mcp_tool_call] {"server":"filesystem","tool":"read_file","arguments":{"path":"README.md"}}"#

        let presentation = TimelineToolEventParser.parse(statusMessage: message)

        XCTAssertEqual(presentation?.title, "MCP Tool Call")
        XCTAssertEqual(presentation?.summary, "filesystem/read_file")
        XCTAssertEqual(presentation?.subtitle, "README.md")
        XCTAssertEqual(presentation?.todoItems, [])
        XCTAssertEqual(presentation?.metadataRows.map(\.label), ["Server", "Tool", "Path"])
        XCTAssertEqual(presentation?.metadataRows.map(\.value), ["filesystem", "read_file", "README.md"])
    }

    func testParserExtractsSearchQueriesAndMetadataForWebSearch() {
        let message = #"[web_search] {"queries":["swiftui tool card design","xcodebuild error 65"],"engine":"live","status":"completed"}"#

        let presentation = TimelineToolEventParser.parse(statusMessage: message)

        XCTAssertEqual(presentation?.title, "Web Search")
        XCTAssertEqual(presentation?.summary, "swiftui tool card design")
        XCTAssertEqual(presentation?.subtitle, "completed")
        XCTAssertEqual(presentation?.searchQueries, ["swiftui tool card design", "xcodebuild error 65"])
        XCTAssertEqual(presentation?.metadataRows.map(\.label), ["Engine", "Status"])
        XCTAssertEqual(presentation?.metadataRows.map(\.value), ["live", "completed"])
    }
}
