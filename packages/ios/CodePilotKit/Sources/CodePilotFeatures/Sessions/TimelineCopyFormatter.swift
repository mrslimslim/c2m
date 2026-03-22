import Foundation
import CodePilotCore
import CodePilotProtocol

public struct TimelineCopyPayload: Equatable, Sendable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

public enum TimelineCopyFormatter {
    public static func transcript(for items: [TimelineItem], agentType: AgentType?) -> String {
        items
            .compactMap { block(for: $0, agentType: agentType) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public static func copyPayload(for item: TimelineItem, agentType: AgentType?) -> TimelineCopyPayload? {
        guard let text = block(for: item, agentType: agentType) else {
            return nil
        }

        switch item.kind {
        case .userCommand:
            return TimelineCopyPayload(title: "Copy Prompt", text: text)
        case .agentMessage, .thinking:
            return TimelineCopyPayload(title: "Copy Message", text: text)
        case .commandExec:
            return TimelineCopyPayload(title: "Copy Command", text: text)
        case .codeChange, .turnCompleted:
            return TimelineCopyPayload(title: "Copy Summary", text: text)
        case .sessionError, .transportError:
            return TimelineCopyPayload(title: "Copy Error", text: text)
        case .status, .system:
            return TimelineCopyPayload(title: "Copy Status", text: text)
        }
    }

    private static func block(for item: TimelineItem, agentType: AgentType?) -> String? {
        switch item.kind {
        case let .userCommand(text):
            return "You: \(text)"

        case let .agentMessage(text):
            return "\(assistantLabel(for: agentType)): \(text)"

        case let .thinking(text):
            return "Thinking: \(text)"

        case let .codeChange(changes):
            guard !changes.isEmpty else { return nil }
            return (["Files Changed:"] + changes.map { "- \($0.path)" }).joined(separator: "\n")

        case let .commandExec(command, output, exitCode, _):
            var lines = ["Command: \(command)"]
            if let output, !output.isEmpty {
                lines.append("Output:")
                lines.append(output)
            }
            if let exitCode {
                lines.append("Exit Code: \(exitCode)")
            }
            return lines.joined(separator: "\n")

        case let .turnCompleted(summary, filesChanged, _):
            var lines = ["Summary: \(summary)"]
            if !filesChanged.isEmpty {
                lines.append("Files Changed:")
                lines.append(contentsOf: filesChanged.map { "- \($0)" })
            }
            return lines.joined(separator: "\n")

        case let .status(_, message):
            guard !message.isEmpty else { return nil }
            return "Status: \(message)"

        case let .sessionError(message):
            return "Error: \(message)"

        case let .transportError(message):
            return "Connection Error: \(message)"

        case let .system(message):
            guard !message.isEmpty else { return nil }
            return "System: \(message)"
        }
    }

    private static func assistantLabel(for agentType: AgentType?) -> String {
        switch agentType {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case nil:
            return "Assistant"
        }
    }
}
