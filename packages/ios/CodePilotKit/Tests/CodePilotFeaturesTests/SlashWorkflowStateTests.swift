import XCTest
@testable import CodePilotFeatures
import CodePilotProtocol

final class SlashWorkflowStateTests: XCTestCase {
    func testProjectorFiltersCommandsAndAutoProjectsExactWorkflowQuery() {
        let catalog = makeCatalog()
        let state = SlashWorkflowState(catalog: catalog)

        let rootProjection = state.projection(
            query: "/",
            config: .init(model: "gpt-5.4", modelReasoningEffort: "medium")
        )
        XCTAssertEqual(rootProjection?.title, "Commands")
        XCTAssertEqual(rootProjection?.entries.map { $0.id }, ["model", "permissions", "review", "new"])
        XCTAssertEqual(rootProjection?.entries.first(where: { $0.id == "review" })?.isEnabled, false)

        let filteredProjection = state.projection(
            query: "/m",
            config: .init(model: "gpt-5.4", modelReasoningEffort: "medium")
        )
        XCTAssertEqual(filteredProjection?.entries.map { $0.id }, ["model"])

        let modelProjection = state.projection(
            query: "/model",
            config: .init(model: "gpt-5.4", modelReasoningEffort: "medium")
        )
        XCTAssertEqual(modelProjection?.title, "Select Model and Effort")
        XCTAssertEqual(modelProjection?.entries.map { $0.id }, ["gpt-5.3-codex", "gpt-5.4"])
        XCTAssertEqual(modelProjection?.entries.first(where: { $0.id == "gpt-5.4" })?.isDefault, true)
        XCTAssertEqual(modelProjection?.entries.first(where: { $0.id == "gpt-5.4" })?.isCurrent, true)

        let permissionsProjection = state.projection(
            query: "/permissions",
            config: .init()
        )
        XCTAssertEqual(permissionsProjection?.title, "Update Model Permissions")
        XCTAssertEqual(permissionsProjection?.entries.map { $0.id }, ["default", "full-access"])
        XCTAssertEqual(permissionsProjection?.entries.first(where: { $0.id == "default" })?.isDefault, true)
        XCTAssertEqual(permissionsProjection?.entries.first(where: { $0.id == "default" })?.isCurrent, true)
    }

    func testWorkflowNavigatesNestedMenusAppliesEffectsAndSupportsBackNavigation() {
        var state = SlashWorkflowState(catalog: makeCatalog())
        var config = SessionConfig(model: "gpt-5.3-codex", modelReasoningEffort: "medium")
        var inputText = "/model"

        XCTAssertEqual(
            state.selectCommand(
                id: "model",
                sessionId: "session-1",
                config: &config,
                inputText: &inputText
            ),
            .enteredMenu
        )
        XCTAssertEqual(state.projection(query: inputText, config: config)?.title, "Select Model and Effort")

        XCTAssertEqual(
            state.selectOption(
                id: "gpt-5.4",
                sessionId: "session-1",
                config: &config,
                inputText: &inputText
            ),
            .enteredMenu
        )
        XCTAssertEqual(
            state.projection(query: inputText, config: config)?.title,
            "Select Reasoning Level for gpt-5.4"
        )

        state.goBack()
        XCTAssertEqual(state.projection(query: inputText, config: config)?.title, "Select Model and Effort")

        XCTAssertEqual(
            state.selectOption(
                id: "gpt-5.4",
                sessionId: "session-1",
                config: &config,
                inputText: &inputText
            ),
            .enteredMenu
        )
        XCTAssertEqual(
            state.selectOption(
                id: "xhigh",
                sessionId: "session-1",
                config: &config,
                inputText: &inputText
            ),
            .completed
        )

        XCTAssertEqual(config.model, "gpt-5.4")
        XCTAssertEqual(config.modelReasoningEffort, "xhigh")
        XCTAssertFalse(state.canGoBack)
    }

    func testWorkflowReturnsBridgeAndClientActionsForExecutableCommands() {
        var state = SlashWorkflowState(catalog: makeCatalog(reviewEnabled: true))
        var config = SessionConfig()
        var inputText = "/review"

        XCTAssertEqual(
            state.selectCommand(
                id: "review",
                sessionId: "session-1",
                config: &config,
                inputText: &inputText
            ),
            .bridgeAction(.init(commandId: "review", sessionId: "session-1"))
        )

        inputText = "/new"
        XCTAssertEqual(
            state.selectCommand(
                id: "new",
                sessionId: nil,
                config: &config,
                inputText: &inputText
            ),
            .clientAction(commandId: "new")
        )
    }

    func testWorkflowAppliesPermissionPresetEffects() {
        var state = SlashWorkflowState(catalog: makeCatalog())
        var config = SessionConfig()
        var inputText = "/permissions"

        XCTAssertEqual(
            state.selectCommand(
                id: "permissions",
                sessionId: "session-1",
                config: &config,
                inputText: &inputText
            ),
            .enteredMenu
        )
        XCTAssertEqual(state.projection(query: inputText, config: config)?.title, "Update Model Permissions")

        XCTAssertEqual(
            state.selectOption(
                id: "full-access",
                sessionId: "session-1",
                config: &config,
                inputText: &inputText
            ),
            .completed
        )
        XCTAssertEqual(config.approvalPolicy, "never")
        XCTAssertEqual(config.sandboxMode, "danger-full-access")
    }

    func testWorkflowAppliesInputTextEffects() {
        var state = SlashWorkflowState(catalog: makeInsertTextCatalog())
        var config = SessionConfig()
        var inputText = "/prompt"

        XCTAssertEqual(
            state.selectCommand(
                id: "prompt",
                sessionId: nil,
                config: &config,
                inputText: &inputText
            ),
            .enteredMenu
        )
        XCTAssertEqual(
            state.selectOption(
                id: "explain",
                sessionId: nil,
                config: &config,
                inputText: &inputText
            ),
            .completed
        )
        XCTAssertEqual(inputText, "Explain the codebase")
    }

    private func makeCatalog(reviewEnabled: Bool = false) -> SlashCatalogMessage {
        .init(
            adapter: .codex,
            adapterVersion: "0.116.0",
            catalogVersion: "codex-0.116.0",
            defaults: .init(
                model: "gpt-5.4",
                modelReasoningEffort: "medium",
                approvalPolicy: "on-request",
                sandboxMode: "workspace-write"
            ),
            commands: [
                .init(
                    id: "model",
                    label: "/model",
                    description: "Choose what model and reasoning effort to use",
                    kind: .workflow,
                    availability: .enabled,
                    searchTerms: ["models", "reasoning"],
                    menu: .init(
                        title: "Select Model and Effort",
                        presentation: .list,
                        options: [
                            .init(
                                id: "gpt-5.3-codex",
                                label: "gpt-5.3-codex",
                                description: "Latest frontier agentic coding model.",
                                next: .init(
                                    title: "Select Reasoning Level for gpt-5.3-codex",
                                    presentation: .list,
                                    options: reasoningOptions(for: "gpt-5.3-codex")
                                )
                            ),
                            .init(
                                id: "gpt-5.4",
                                label: "gpt-5.4",
                                description: "Latest frontier agentic coding model.",
                                next: .init(
                                    title: "Select Reasoning Level for gpt-5.4",
                                    presentation: .list,
                                    options: reasoningOptions(for: "gpt-5.4")
                                )
                            ),
                        ]
                    )
                ),
                .init(
                    id: "permissions",
                    label: "/permissions",
                    description: "Choose what Codex is allowed to do",
                    kind: .workflow,
                    availability: .enabled,
                    menu: .init(
                        title: "Update Model Permissions",
                        presentation: .list,
                        options: [
                            .init(
                                id: "default",
                                label: "Default",
                                description: "Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files.",
                                effects: [
                                    .setSessionConfig(field: .approvalPolicy, value: "on-request"),
                                    .setSessionConfig(field: .sandboxMode, value: "workspace-write")
                                ]
                            ),
                            .init(
                                id: "full-access",
                                label: "Full Access",
                                description: "Codex can edit files outside this workspace and access the internet without asking for approval. Exercise caution when using.",
                                effects: [
                                    .setSessionConfig(field: .approvalPolicy, value: "never"),
                                    .setSessionConfig(field: .sandboxMode, value: "danger-full-access")
                                ]
                            )
                        ]
                    )
                ),
                .init(
                    id: "review",
                    label: "/review",
                    description: "Review my current changes and find issues",
                    kind: .bridgeAction,
                    availability: reviewEnabled ? .enabled : .disabled,
                    disabledReason: reviewEnabled ? nil : "Slash-triggered bridge reviews are not implemented yet."
                ),
                .init(
                    id: "new",
                    label: "/new",
                    description: "Start a new chat during a conversation",
                    kind: .clientAction,
                    availability: .enabled
                ),
            ]
        )
    }

    private func makeInsertTextCatalog() -> SlashCatalogMessage {
        .init(
            adapter: .codex,
            adapterVersion: "0.116.0",
            catalogVersion: "codex-0.116.0",
            defaults: .init(),
            commands: [
                .init(
                    id: "prompt",
                    label: "/prompt",
                    description: "Insert a starter prompt",
                    kind: .workflow,
                    availability: .enabled,
                    menu: .init(
                        title: "Insert Prompt",
                        presentation: .list,
                        options: [
                            .init(
                                id: "explain",
                                label: "Explain",
                                description: "Insert an explain prompt",
                                effects: [.setInputText(value: "Explain the codebase")]
                            )
                        ]
                    )
                )
            ]
        )
    }

    private func reasoningOptions(for modelId: String) -> [SlashMenuOption] {
        [
            .init(
                id: "medium",
                label: "Medium",
                description: "Balances speed and reasoning depth for everyday tasks",
                effects: [
                    .setSessionConfig(field: .model, value: modelId),
                    .setSessionConfig(field: .modelReasoningEffort, value: "medium"),
                ]
            ),
            .init(
                id: "xhigh",
                label: "Extra high",
                description: "Extra high reasoning depth for complex problems",
                effects: [
                    .setSessionConfig(field: .model, value: modelId),
                    .setSessionConfig(field: .modelReasoningEffort, value: "xhigh"),
                ]
            ),
        ]
    }
}
