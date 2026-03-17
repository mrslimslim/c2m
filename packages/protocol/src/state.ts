/**
 * Agent state machine — represents the current state of the AI coding agent.
 */
export type AgentState =
  | "idle"
  | "thinking"
  | "coding"
  | "running_command"
  | "waiting_approval"
  | "error";

/**
 * Token usage information for a completed turn.
 */
export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cachedInputTokens?: number;
}

/**
 * A single file change reported by the agent.
 */
export interface FileChange {
  path: string;
  kind: "add" | "delete" | "update";
}

/**
 * Information about a running or completed agent session.
 */
export interface SessionInfo {
  id: string;
  agentType: "codex" | "claude";
  workDir: string;
  state: AgentState;
  createdAt: number;
  lastActiveAt: number;
}
