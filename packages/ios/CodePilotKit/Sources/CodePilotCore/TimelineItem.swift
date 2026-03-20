import Foundation
import CodePilotProtocol

public struct TimelineItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
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
    }

    public let timestamp: Int
    public let kind: Kind

    public init(timestamp: Int, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }
}
