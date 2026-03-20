import Foundation

public enum AgentState: String, Codable, Equatable, Sendable {
    case idle
    case thinking
    case coding
    case runningCommand = "running_command"
    case waitingApproval = "waiting_approval"
    case error
}

public enum AgentType: String, Codable, Equatable, Sendable {
    case codex
    case claude
}

public enum FileChangeKind: String, Codable, Equatable, Sendable {
    case add
    case delete
    case update
}

public struct FileChange: Codable, Equatable, Sendable {
    public let path: String
    public let kind: FileChangeKind

    public init(path: String, kind: FileChangeKind) {
        self.path = path
        self.kind = kind
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }
}

public struct SessionInfo: Codable, Equatable, Sendable {
    public let id: String
    public let agentType: AgentType
    public let workDir: String
    public let state: AgentState
    public let createdAt: Int
    public let lastActiveAt: Int

    public init(
        id: String,
        agentType: AgentType,
        workDir: String,
        state: AgentState,
        createdAt: Int,
        lastActiveAt: Int
    ) {
        self.id = id
        self.agentType = agentType
        self.workDir = workDir
        self.state = state
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}
