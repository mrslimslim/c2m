import XCTest

final class CTunnelStreamingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStreamingReplyGrowsWithinSingleTimelineMessage() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-streaming"]
        app.launch()

        let projectCard = app.buttons["project.card.ui-test-streaming"]
        XCTAssertTrue(projectCard.waitForExistence(timeout: 5))
        projectCard.tap()

        let sessionCard = app.buttons["session.card.ui-test-session"]
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 5))
        sessionCard.tap()

        let composerInput = resolveComposerInput(in: app)
        XCTAssertTrue(composerInput.waitForExistence(timeout: 5))
        composerInput.tap()
        composerInput.typeText("hello")

        let sendButton = app.buttons["session.composer.send"]
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        let message = timelineAgentMessage(in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        let firstLabel = message.label

        let finalReply = "Hello, CTunnel."
        let finalPredicate = NSPredicate(format: "label CONTAINS %@", finalReply)
        expectation(for: finalPredicate, evaluatedWith: message)
        waitForExpectations(timeout: 3)

        XCTAssertTrue(message.label.contains(finalReply))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "timeline.agentMessage").count, 1)
        XCTAssertFalse(message.label.contains("Under-development features enabled"))
        XCTAssertFalse(message.label.contains("codex_hooks"))
        XCTAssertLessThan(firstLabel.count, message.label.count)
    }

    private func resolveComposerInput(in app: XCUIApplication) -> XCUIElement {
        let textView = app.textViews["session.composer.input"]
        if textView.exists {
            return textView
        }

        let textField = app.textFields["session.composer.input"]
        if textField.exists {
            return textField
        }

        return app.descendants(matching: .any)["session.composer.input"]
    }

    private func timelineAgentMessage(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["timeline.agentMessage"]
    }
}
