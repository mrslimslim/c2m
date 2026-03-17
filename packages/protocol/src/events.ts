/**
 * Unified agent events — both Codex SDK events and Claude stream-json events
 * are mapped to these types before being sent to the mobile client.
 */

import type { AgentState, FileChange, TokenUsage } from "./state.js";

// ─── Agent → Phone events ────────────────────────────────────────────

export interface StatusEvent {
  type: "status";
  state: AgentState;
  message: string;
}

export interface ThinkingEvent {
  type: "thinking";
  text: string;
}

export interface CodeChangeEvent {
  type: "code_change";
  changes: FileChange[];
}

export interface CommandExecEvent {
  type: "command_exec";
  command: string;
  output?: string;
  exitCode?: number;
  status: "running" | "done" | "failed";
}

export interface AgentMessageEvent {
  type: "agent_message";
  text: string;
}

export interface ErrorEvent {
  type: "error";
  message: string;
}

export interface TurnCompletedEvent {
  type: "turn_completed";
  summary: string;
  filesChanged: string[];
  usage: TokenUsage | null;
}

/**
 * Union of all possible agent events.
 */
export type AgentEvent =
  | StatusEvent
  | ThinkingEvent
  | CodeChangeEvent
  | CommandExecEvent
  | AgentMessageEvent
  | ErrorEvent
  | TurnCompletedEvent;
