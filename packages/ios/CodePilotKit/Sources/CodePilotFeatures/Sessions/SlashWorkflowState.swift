import Foundation
import CodePilotProtocol

public enum SlashWorkflowSelectionResult: Equatable, Sendable {
    case none
    case enteredMenu
    case completed
    case bridgeAction(SlashActionMessage)
    case clientAction(commandId: String)
}

public struct SlashWorkflowState: Equatable, Sendable {
    private var catalog: SlashCatalogMessage?
    private var navigationPath: [SlashMenuNode] = []

    public init(catalog: SlashCatalogMessage? = nil) {
        self.catalog = catalog
    }

    public var canGoBack: Bool {
        !navigationPath.isEmpty
    }

    public mutating func updateCatalog(_ catalog: SlashCatalogMessage?) {
        self.catalog = catalog
        navigationPath.removeAll()
    }

    public func projection(
        query: String,
        config: SessionConfig
    ) -> SlashWorkflowProjection? {
        SlashCatalogProjector(catalog: catalog).project(
            query: query,
            config: config,
            navigationPath: navigationPath
        )
    }

    @discardableResult
    public mutating func enterCommand(id: String) -> Bool {
        guard
            let command = catalog?.commands.first(where: { $0.id == id }),
            command.availability == .enabled,
            command.kind == .workflow,
            let menu = command.menu
        else {
            return false
        }

        navigationPath = [menu]
        return true
    }

    public mutating func selectCommand(
        id: String,
        sessionId: String?,
        config: inout SessionConfig,
        inputText: inout String
    ) -> SlashWorkflowSelectionResult {
        guard let command = catalog?.commands.first(where: { $0.id == id }) else {
            return .none
        }
        guard command.availability == .enabled else {
            return .none
        }

        switch command.kind {
        case .workflow:
            guard let menu = command.menu else {
                return .none
            }
            navigationPath = [menu]
            return .enteredMenu

        case .bridgeAction:
            navigationPath.removeAll()
            return .bridgeAction(
                .init(
                    commandId: command.id,
                    sessionId: sessionId,
                    arguments: command.action?.arguments
                )
            )

        case .clientAction:
            navigationPath.removeAll()
            return .clientAction(commandId: command.id)

        case .insertText:
            if let input = command.action?.inputText {
                inputText = input
            }
            navigationPath.removeAll()
            return .completed
        }
    }

    public mutating func selectOption(
        id: String,
        sessionId: String?,
        config: inout SessionConfig,
        inputText: inout String
    ) -> SlashWorkflowSelectionResult {
        guard
            let currentMenu = navigationPath.last,
            let option = currentMenu.options.first(where: { $0.id == id })
        else {
            return .none
        }

        if let next = option.next {
            navigationPath.append(next)
            return .enteredMenu
        }

        applyEffects(option.effects ?? [], config: &config, inputText: &inputText)
        navigationPath.removeAll()
        _ = sessionId
        return .completed
    }

    public mutating func goBack() {
        guard !navigationPath.isEmpty else {
            return
        }
        navigationPath.removeLast()
    }

    public mutating func reset() {
        navigationPath.removeAll()
    }

    private func applyEffects(
        _ effects: [SlashEffect],
        config: inout SessionConfig,
        inputText: inout String
    ) {
        for effect in effects {
            switch effect {
            case let .setSessionConfig(field, value):
                switch field {
                case .model:
                    config.model = value
                case .modelReasoningEffort:
                    config.modelReasoningEffort = value
                case .approvalPolicy:
                    config.approvalPolicy = value
                case .sandboxMode:
                    config.sandboxMode = value
                }
            case let .setInputText(value):
                inputText = value
            case .clearInputText:
                inputText = ""
            }
        }
    }
}
