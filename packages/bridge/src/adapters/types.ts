/**
 * AgentAdapter — unified interface for controlling different AI coding agents.
 */

import type { AgentEvent } from "@codepilot/protocol";
import type { ModelReasoningEffort, SessionConfig, SessionInfo } from "@codepilot/protocol";

export interface SessionOptions {
  model?: string;
  modelReasoningEffort?: ModelReasoningEffort;
  /** Working directory for the agent */
  workDir: string;
  /** Codex approval policy */
  approvalPolicy?: SessionConfig["approvalPolicy"];
  /** Codex sandbox mode */
  sandboxMode?: SessionConfig["sandboxMode"];
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
    opts?: SessionOptions,
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
   * Remove a session and release any resources associated with it.
   */
  deleteSession(sessionId: string): void;

  /**
   * Dispose of all resources.
   */
  dispose(): void;
}
