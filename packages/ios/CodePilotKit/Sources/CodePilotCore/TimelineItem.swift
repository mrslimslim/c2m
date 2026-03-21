import Foundation
import CodePilotProtocol

public struct TimelineItem: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case system(message: String)
        case userCommand(text: String)
        case status(state: AgentState, message: String)
        case thinking(text: String)
        case agentMessage(text: String)
        case codeChange(changes: [FileChange])
        case commandExec(command: String, output: String?, exitCode: Int?, status: CommandExecStatus)
        case turnCompleted(summary: String, filesChanged: [String], usage: TokenUsage?)
        case sessionError(message: String)
        case transportError(message: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case message
            case text
            case state
            case changes
            case command
            case output
            case exitCode
            case status
            case summary
            case filesChanged
            case usage
        }

        private enum KindType: String, Codable {
            case system
            case userCommand = "user_command"
            case status
            case thinking
            case agentMessage = "agent_message"
            case codeChange = "code_change"
            case commandExec = "command_exec"
            case turnCompleted = "turn_completed"
            case sessionError = "session_error"
            case transportError = "transport_error"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(KindType.self, forKey: .type)

            switch type {
            case .system:
                self = .system(message: try container.decode(String.self, forKey: .message))
            case .userCommand:
                self = .userCommand(text: try container.decode(String.self, forKey: .text))
            case .status:
                self = .status(
                    state: try container.decode(AgentState.self, forKey: .state),
                    message: try container.decode(String.self, forKey: .message)
                )
            case .thinking:
                self = .thinking(text: try container.decode(String.self, forKey: .text))
            case .agentMessage:
                self = .agentMessage(text: try container.decode(String.self, forKey: .text))
            case .codeChange:
                self = .codeChange(changes: try container.decode([FileChange].self, forKey: .changes))
            case .commandExec:
                self = .commandExec(
                    command: try container.decode(String.self, forKey: .command),
                    output: try container.decodeIfPresent(String.self, forKey: .output),
                    exitCode: try container.decodeIfPresent(Int.self, forKey: .exitCode),
                    status: try container.decode(CommandExecStatus.self, forKey: .status)
                )
            case .turnCompleted:
                self = .turnCompleted(
                    summary: try container.decode(String.self, forKey: .summary),
                    filesChanged: try container.decodeIfPresent([String].self, forKey: .filesChanged) ?? [],
                    usage: try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
                )
            case .sessionError:
                self = .sessionError(message: try container.decode(String.self, forKey: .message))
            case .transportError:
                self = .transportError(message: try container.decode(String.self, forKey: .message))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case let .system(message):
                try container.encode(KindType.system, forKey: .type)
                try container.encode(message, forKey: .message)
            case let .userCommand(text):
                try container.encode(KindType.userCommand, forKey: .type)
                try container.encode(text, forKey: .text)
            case let .status(state, message):
                try container.encode(KindType.status, forKey: .type)
                try container.encode(state, forKey: .state)
                try container.encode(message, forKey: .message)
            case let .thinking(text):
                try container.encode(KindType.thinking, forKey: .type)
                try container.encode(text, forKey: .text)
            case let .agentMessage(text):
                try container.encode(KindType.agentMessage, forKey: .type)
                try container.encode(text, forKey: .text)
            case let .codeChange(changes):
                try container.encode(KindType.codeChange, forKey: .type)
                try container.encode(changes, forKey: .changes)
            case let .commandExec(command, output, exitCode, status):
                try container.encode(KindType.commandExec, forKey: .type)
                try container.encode(command, forKey: .command)
                try container.encodeIfPresent(output, forKey: .output)
                try container.encodeIfPresent(exitCode, forKey: .exitCode)
                try container.encode(status, forKey: .status)
            case let .turnCompleted(summary, filesChanged, usage):
                try container.encode(KindType.turnCompleted, forKey: .type)
                try container.encode(summary, forKey: .summary)
                try container.encode(filesChanged, forKey: .filesChanged)
                try container.encodeIfPresent(usage, forKey: .usage)
            case let .sessionError(message):
                try container.encode(KindType.sessionError, forKey: .type)
                try container.encode(message, forKey: .message)
            case let .transportError(message):
                try container.encode(KindType.transportError, forKey: .type)
                try container.encode(message, forKey: .message)
            }
        }
    }

    public let timestamp: Int
    public let kind: Kind

    public init(timestamp: Int, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }
}
