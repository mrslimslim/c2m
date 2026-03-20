import Foundation

public enum CommandExecStatus: String, Codable, Equatable, Sendable {
    case running
    case done
    case failed
}

public enum AgentEvent: Codable, Equatable, Sendable {
    case status(state: AgentState, message: String)
    case thinking(text: String)
    case codeChange(changes: [FileChange])
    case commandExec(command: String, output: String?, exitCode: Int?, status: CommandExecStatus)
    case agentMessage(text: String)
    case error(message: String)
    case turnCompleted(summary: String, filesChanged: [String], usage: TokenUsage?)

    enum CodingKeys: String, CodingKey {
        case type
        case state
        case message
        case text
        case changes
        case command
        case output
        case exitCode
        case status
        case summary
        case filesChanged
        case usage
    }

    enum EventType: String, Codable {
        case status
        case thinking
        case codeChange = "code_change"
        case commandExec = "command_exec"
        case agentMessage = "agent_message"
        case error
        case turnCompleted = "turn_completed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)

        switch type {
        case .status:
            self = .status(
                state: try container.decode(AgentState.self, forKey: .state),
                message: try container.decode(String.self, forKey: .message)
            )
        case .thinking:
            self = .thinking(text: try container.decode(String.self, forKey: .text))
        case .codeChange:
            self = .codeChange(changes: try container.decode([FileChange].self, forKey: .changes))
        case .commandExec:
            self = .commandExec(
                command: try container.decode(String.self, forKey: .command),
                output: try container.decodeIfPresent(String.self, forKey: .output),
                exitCode: try container.decodeIfPresent(Int.self, forKey: .exitCode),
                status: try container.decode(CommandExecStatus.self, forKey: .status)
            )
        case .agentMessage:
            self = .agentMessage(text: try container.decode(String.self, forKey: .text))
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        case .turnCompleted:
            self = .turnCompleted(
                summary: try container.decode(String.self, forKey: .summary),
                filesChanged: try container.decodeIfPresent([String].self, forKey: .filesChanged) ?? [],
                usage: try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .status(state, message):
            try container.encode(EventType.status, forKey: .type)
            try container.encode(state, forKey: .state)
            try container.encode(message, forKey: .message)
        case let .thinking(text):
            try container.encode(EventType.thinking, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .codeChange(changes):
            try container.encode(EventType.codeChange, forKey: .type)
            try container.encode(changes, forKey: .changes)
        case let .commandExec(command, output, exitCode, status):
            try container.encode(EventType.commandExec, forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(output, forKey: .output)
            try container.encodeIfPresent(exitCode, forKey: .exitCode)
            try container.encode(status, forKey: .status)
        case let .agentMessage(text):
            try container.encode(EventType.agentMessage, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .error(message):
            try container.encode(EventType.error, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .turnCompleted(summary, filesChanged, usage):
            try container.encode(EventType.turnCompleted, forKey: .type)
            try container.encode(summary, forKey: .summary)
            try container.encode(filesChanged, forKey: .filesChanged)
            try container.encode(usage, forKey: .usage)
        }
    }
}
