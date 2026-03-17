/**
 * AgentAdapter — unified interface for controlling different AI coding agents.
 */

import type { AgentEvent } from "@codepilot/protocol";
import type { SessionInfo } from "@codepilot/protocol";

export interface SessionOptions {
  model?: string;
  /** Working directory for the agent */
  workDir: string;
}

export interface AgentAdapter {
  /** Human-readable name: "codex" | "claude" */
  readonly name: "codex" | "claude";

  /**
   * Start a new agent session in the given working directory.
   */
  startSession(opts: SessionOptions): Promise<SessionInfo>;

  /**
   * Send a user instruction and stream back events.
   * Returns when the turn is complete.
   */
  execute(
    sessionId: string,
    input: string,
    onEvent: (event: AgentEvent) => void,
  ): Promise<void>;

  /**
   * Resume a previously created session.
   */
  resumeSession(sessionId: string): Promise<SessionInfo>;

  /**
   * Cancel any in-progress execution.
   */
  cancel(sessionId: string): void;

  /**
   * Dispose of all resources.
   */
  dispose(): void;
}
