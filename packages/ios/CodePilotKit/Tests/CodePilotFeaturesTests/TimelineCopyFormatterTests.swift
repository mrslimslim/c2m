import XCTest
import CodePilotCore
import CodePilotFeatures
import CodePilotProtocol

final class TimelineCopyFormatterTests: XCTestCase {
    func testTranscriptIncludesReadableSpeakerLabelsAndImportantEvents() {
        let items = [
            TimelineItem(timestamp: 1, kind: .userCommand(text: "Fix the login view")),
            TimelineItem(timestamp: 2, kind: .agentMessage(text: "I updated the button state.")),
            TimelineItem(timestamp: 3, kind: .commandExec(command: "swift test", output: "Executed 3 tests", exitCode: 0, status: .done)),
            TimelineItem(timestamp: 4, kind: .turnCompleted(summary: "Done", filesChanged: ["App.swift"], usage: nil)),
        ]

        let transcript = TimelineCopyFormatter.transcript(for: items, agentType: .codex)

        XCTAssertEqual(
            transcript,
            """
            You: Fix the login view

            Codex: I updated the button state.

            Command: swift test
            Output:
            Executed 3 tests
            Exit Code: 0

            Summary: Done
            Files Changed:
            - App.swift
            """
        )
    }

    func testCopyPayloadUsesFocusedLabelsForSingleTimelineItems() {
        let commandItem = TimelineItem(
            timestamp: 10,
            kind: .commandExec(command: "npm test", output: "1 failed", exitCode: 1, status: .failed)
        )
        let errorItem = TimelineItem(timestamp: 11, kind: .transportError(message: "bridge disconnected"))

        XCTAssertEqual(
            TimelineCopyFormatter.copyPayload(for: commandItem, agentType: .claude)?.title,
            "Copy Command"
        )
        XCTAssertEqual(
            TimelineCopyFormatter.copyPayload(for: commandItem, agentType: .claude)?.text,
            """
            Command: npm test
            Output:
            1 failed
            Exit Code: 1
            """
        )
        XCTAssertEqual(
            TimelineCopyFormatter.copyPayload(for: errorItem, agentType: .claude)?.title,
            "Copy Error"
        )
        XCTAssertEqual(
            TimelineCopyFormatter.copyPayload(for: errorItem, agentType: .claude)?.text,
            "Connection Error: bridge disconnected"
        )
    }
}
