import Foundation
import CodePilotProtocol

public struct SlashWorkflowProjection: Equatable, Sendable {
    public let title: String
    public let helperText: String?
    public let presentation: SlashMenuPresentation
    public let canGoBack: Bool
    public let entries: [SlashWorkflowEntry]

    public init(
        title: String,
        helperText: String? = nil,
        presentation: SlashMenuPresentation,
        canGoBack: Bool,
        entries: [SlashWorkflowEntry]
    ) {
        self.title = title
        self.helperText = helperText
        self.presentation = presentation
        self.canGoBack = canGoBack
        self.entries = entries
    }
}

public struct SlashWorkflowEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case command(SlashCommandKind)
        case option
    }

    public let id: String
    public let label: String
    public let description: String?
    public let badges: [SlashOptionBadge]
    public let kind: Kind
    public let isEnabled: Bool
    public let disabledReason: String?
    public let isDefault: Bool
    public let isCurrent: Bool
    public let hasNext: Bool

    public init(
        id: String,
        label: String,
        description: String? = nil,
        badges: [SlashOptionBadge] = [],
        kind: Kind,
        isEnabled: Bool,
        disabledReason: String? = nil,
        isDefault: Bool = false,
        isCurrent: Bool = false,
        hasNext: Bool = false
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.badges = badges
        self.kind = kind
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.isDefault = isDefault
        self.isCurrent = isCurrent
        self.hasNext = hasNext
    }
}

public struct SlashCatalogProjector: Sendable {
    private let catalog: SlashCatalogMessage?

    public init(catalog: SlashCatalogMessage?) {
        self.catalog = catalog
    }

    public func project(
        query: String,
        config: SessionConfig,
        navigationPath: [SlashMenuNode] = []
    ) -> SlashWorkflowProjection? {
        guard let catalog else {
            return nil
        }

        if let menu = navigationPath.last {
            return projectMenu(
                menu,
                currentConfig: config,
                defaultConfig: catalog.defaults,
                canGoBack: true
            )
        }

        let normalizedQuery = normalizeQuery(query)
        guard normalizedQuery.hasPrefix("/") else {
            return nil
        }

        if let exactCommand = exactWorkflowCommand(
            matching: normalizedQuery,
            commands: catalog.commands
        ), let menu = exactCommand.menu {
            return projectMenu(
                menu,
                currentConfig: config,
                defaultConfig: catalog.defaults,
                canGoBack: false
            )
        }

        let filteredCommands = filterCommands(
            matching: normalizedQuery,
            commands: catalog.commands
        )
        guard !filteredCommands.isEmpty else {
            return nil
        }

        return .init(
            title: "Commands",
            presentation: .list,
            canGoBack: false,
            entries: filteredCommands.map(projectCommand)
        )
    }

    private func projectMenu(
        _ menu: SlashMenuNode,
        currentConfig: SessionConfig,
        defaultConfig: SessionConfig,
        canGoBack: Bool
    ) -> SlashWorkflowProjection {
        let effectiveCurrentConfig = mergedConfig(
            defaults: defaultConfig,
            overrides: currentConfig
        )

        return .init(
            title: menu.title,
            helperText: menu.helperText,
            presentation: menu.presentation,
            canGoBack: canGoBack,
            entries: menu.options.map { option in
                let stableEffects = stableSessionConfigEffects(for: option)
                let isDefault = matches(
                    stableEffects: stableEffects,
                    config: defaultConfig
                )
                let isCurrent = matches(
                    stableEffects: stableEffects,
                    config: effectiveCurrentConfig
                )
                return .init(
                    id: option.id,
                    label: option.label,
                    description: option.description,
                    badges: option.badges ?? [],
                    kind: .option,
                    isEnabled: true,
                    isDefault: isDefault,
                    isCurrent: isCurrent,
                    hasNext: option.next != nil
                )
            }
        )
    }

    private func projectCommand(_ command: SlashCommandMeta) -> SlashWorkflowEntry {
        .init(
            id: command.id,
            label: command.label,
            description: command.description,
            kind: .command(command.kind),
            isEnabled: command.availability == .enabled,
            disabledReason: command.disabledReason,
            hasNext: command.menu != nil
        )
    }

    private func filterCommands(
        matching normalizedQuery: String,
        commands: [SlashCommandMeta]
    ) -> [SlashCommandMeta] {
        let needle = normalizedQuery.dropFirst()
        guard !needle.isEmpty else {
            return commands.filter { $0.availability != .hidden }
        }

        return commands.filter { command in
            guard command.availability != .hidden else {
                return false
            }
            let id = command.id.lowercased()
            let label = command.label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let query = String(needle)
            if id.hasPrefix(query) || label.hasPrefix(query) {
                return true
            }
            return (command.searchTerms ?? []).contains { term in
                term.lowercased().hasPrefix(query)
            }
        }
    }

    private func exactWorkflowCommand(
        matching normalizedQuery: String,
        commands: [SlashCommandMeta]
    ) -> SlashCommandMeta? {
        commands.first { command in
            guard command.kind == .workflow else {
                return false
            }
            guard command.availability != .hidden else {
                return false
            }
            let id = "/" + command.id.lowercased()
            let label = command.label.lowercased()
            return normalizedQuery == id || normalizedQuery == label
        }
    }

    private func stableSessionConfigEffects(
        for option: SlashMenuOption
    ) -> [SlashSessionConfigField: String] {
        let leafEffects = leafSessionConfigEffects(for: option)
        guard var stable = leafEffects.first else {
            return [:]
        }

        for effectMap in leafEffects.dropFirst() {
            stable = stable.filter { field, value in
                effectMap[field] == value
            }
        }

        return stable
    }

    private func leafSessionConfigEffects(
        for option: SlashMenuOption
    ) -> [[SlashSessionConfigField: String]] {
        let directEffects = sessionConfigEffects(from: option.effects)

        if let next = option.next {
            let descendants = leafSessionConfigEffects(in: next)
            if descendants.isEmpty {
                return directEffects.isEmpty ? [] : [directEffects]
            }
            if directEffects.isEmpty {
                return descendants
            }
            return descendants.map { descendant in
                directEffects.merging(descendant) { direct, _ in direct }
            }
        }

        return directEffects.isEmpty ? [] : [directEffects]
    }

    private func leafSessionConfigEffects(
        in menu: SlashMenuNode
    ) -> [[SlashSessionConfigField: String]] {
        menu.options.flatMap(leafSessionConfigEffects(for:))
    }

    private func sessionConfigEffects(
        from effects: [SlashEffect]?
    ) -> [SlashSessionConfigField: String] {
        (effects ?? []).reduce(into: [SlashSessionConfigField: String]()) { result, effect in
            guard case let .setSessionConfig(field, value) = effect else {
                return
            }
            result[field] = value
        }
    }

    private func mergedConfig(
        defaults: SessionConfig,
        overrides: SessionConfig
    ) -> SessionConfig {
        .init(
            model: overrides.model ?? defaults.model,
            modelReasoningEffort: overrides.modelReasoningEffort ?? defaults.modelReasoningEffort,
            approvalPolicy: overrides.approvalPolicy ?? defaults.approvalPolicy,
            sandboxMode: overrides.sandboxMode ?? defaults.sandboxMode
        )
    }

    private func matches(
        stableEffects: [SlashSessionConfigField: String],
        config: SessionConfig
    ) -> Bool {
        guard !stableEffects.isEmpty else {
            return false
        }

        return stableEffects.allSatisfy { field, expectedValue in
            sessionConfigValue(for: field, in: config) == expectedValue
        }
    }

    private func sessionConfigValue(
        for field: SlashSessionConfigField,
        in config: SessionConfig
    ) -> String? {
        switch field {
        case .model:
            return config.model
        case .modelReasoningEffort:
            return config.modelReasoningEffort
        case .approvalPolicy:
            return config.approvalPolicy
        case .sandboxMode:
            return config.sandboxMode
        }
    }

    private func normalizeQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
