import Foundation

public enum SlashCommandKind: String, Codable, Equatable, Sendable {
    case workflow
    case bridgeAction = "bridge_action"
    case clientAction = "client_action"
    case insertText = "insert_text"
}

public enum SlashAvailability: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
    case hidden
}

public enum SlashMenuPresentation: String, Codable, Equatable, Sendable {
    case list
    case grid
}

public enum SlashOptionBadge: String, Codable, Equatable, Sendable {
    case `default`
    case recommended
    case experimental
}

public enum SlashSessionConfigField: String, Codable, Equatable, Sendable {
    case model
    case modelReasoningEffort
    case approvalPolicy
    case sandboxMode
}

public enum SlashActionArgumentValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .double(double)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected string, int, double, or bool slash action argument"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        }
    }
}

public enum SlashEffect: Codable, Equatable, Sendable {
    case setSessionConfig(field: SlashSessionConfigField, value: String)
    case setInputText(value: String)
    case clearInputText

    enum CodingKeys: String, CodingKey {
        case type
        case field
        case value
    }

    enum EffectType: String, Codable {
        case setSessionConfig = "set_session_config"
        case setInputText = "set_input_text"
        case clearInputText = "clear_input_text"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EffectType.self, forKey: .type) {
        case .setSessionConfig:
            self = .setSessionConfig(
                field: try container.decode(SlashSessionConfigField.self, forKey: .field),
                value: try container.decode(String.self, forKey: .value)
            )
        case .setInputText:
            self = .setInputText(value: try container.decode(String.self, forKey: .value))
        case .clearInputText:
            self = .clearInputText
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .setSessionConfig(field, value):
            try container.encode(EffectType.setSessionConfig, forKey: .type)
            try container.encode(field, forKey: .field)
            try container.encode(value, forKey: .value)
        case let .setInputText(value):
            try container.encode(EffectType.setInputText, forKey: .type)
            try container.encode(value, forKey: .value)
        case .clearInputText:
            try container.encode(EffectType.clearInputText, forKey: .type)
        }
    }
}

public struct SlashActionMeta: Codable, Equatable, Sendable {
    public let inputText: String?
    public let arguments: [String: SlashActionArgumentValue]?

    public init(inputText: String? = nil, arguments: [String: SlashActionArgumentValue]? = nil) {
        self.inputText = inputText
        self.arguments = arguments
    }
}

public struct SlashMenuOption: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?
    public let badges: [SlashOptionBadge]?
    public let effects: [SlashEffect]?
    public let next: SlashMenuNode?

    public init(
        id: String,
        label: String,
        description: String? = nil,
        badges: [SlashOptionBadge]? = nil,
        effects: [SlashEffect]? = nil,
        next: SlashMenuNode? = nil
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.badges = badges
        self.effects = effects
        self.next = next
    }
}

public struct SlashMenuNode: Codable, Equatable, Sendable {
    public let title: String
    public let helperText: String?
    public let presentation: SlashMenuPresentation
    public let options: [SlashMenuOption]

    public init(
        title: String,
        helperText: String? = nil,
        presentation: SlashMenuPresentation,
        options: [SlashMenuOption]
    ) {
        self.title = title
        self.helperText = helperText
        self.presentation = presentation
        self.options = options
    }
}

public struct SlashCommandMeta: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String
    public let kind: SlashCommandKind
    public let availability: SlashAvailability
    public let disabledReason: String?
    public let searchTerms: [String]?
    public let menu: SlashMenuNode?
    public let action: SlashActionMeta?

    public init(
        id: String,
        label: String,
        description: String,
        kind: SlashCommandKind,
        availability: SlashAvailability,
        disabledReason: String? = nil,
        searchTerms: [String]? = nil,
        menu: SlashMenuNode? = nil,
        action: SlashActionMeta? = nil
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.kind = kind
        self.availability = availability
        self.disabledReason = disabledReason
        self.searchTerms = searchTerms
        self.menu = menu
        self.action = action
    }
}

public struct SlashCatalogMessage: Codable, Equatable, Sendable {
    public let capability: String
    public let adapter: AgentType
    public let adapterVersion: String?
    public let catalogVersion: String
    public let defaults: SessionConfig
    public let commands: [SlashCommandMeta]

    public init(
        capability: String = BridgeCapability.slashCatalogV1,
        adapter: AgentType,
        adapterVersion: String? = nil,
        catalogVersion: String,
        defaults: SessionConfig = .init(),
        commands: [SlashCommandMeta]
    ) {
        self.capability = capability
        self.adapter = adapter
        self.adapterVersion = adapterVersion
        self.catalogVersion = catalogVersion
        self.defaults = defaults
        self.commands = commands
    }
}

public struct SlashActionMessage: Codable, Equatable, Sendable {
    public let commandId: String
    public let sessionId: String?
    public let arguments: [String: SlashActionArgumentValue]?

    public init(
        commandId: String,
        sessionId: String? = nil,
        arguments: [String: SlashActionArgumentValue]? = nil
    ) {
        self.commandId = commandId
        self.sessionId = sessionId
        self.arguments = arguments
    }
}

public struct SlashActionResultMessage: Codable, Equatable, Sendable {
    public let commandId: String
    public let ok: Bool
    public let message: String?

    public init(commandId: String, ok: Bool, message: String? = nil) {
        self.commandId = commandId
        self.ok = ok
        self.message = message
    }
}
