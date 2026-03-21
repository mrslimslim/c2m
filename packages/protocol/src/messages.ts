/**
 * Wire protocol — messages exchanged between the phone and the bridge
 * over WebSocket (JSON serialized).
 */

import type { AgentEvent } from "./events.js";
import type { SessionInfo } from "./state.js";

// ─── E2E Handshake ──────────────────────────────────────────────────

export interface HandshakeMessage {
  type: "handshake";
  phone_pubkey: string;  // base64 raw X25519 public key
  otp: string;
}

export interface HandshakeOkMessage {
  type: "handshake_ok";
  encrypted: boolean;
  clientId?: string;
}

// ─── Session Configuration ──────────────────────────────────────────

export interface SessionConfig {
  model?: string;
  approvalPolicy?: "never" | "on-request" | "on-failure" | "untrusted";
  sandboxMode?: "read-only" | "workspace-write" | "danger-full-access";
}

// ─── Phone → Bridge ──────────────────────────────────────────────────

export interface CommandMessage {
  type: "command";
  /** User's natural language instruction */
  text: string;
  /** Target session, or empty to start a new session */
  sessionId?: string;
  /** Optional session configuration (model, approval, sandbox) */
  config?: SessionConfig;
}

export interface CancelMessage {
  type: "cancel";
  sessionId: string;
}

export interface FileRequestMessage {
  type: "file_req";
  path: string;
  sessionId: string;
}

export interface DeleteSessionMessage {
  type: "delete_session";
  sessionId: string;
}

export interface ListSessionsMessage {
  type: "list_sessions";
}

export interface PingMessage {
  type: "ping";
  ts: number;
}

export type PhoneMessage =
  | CommandMessage
  | CancelMessage
  | FileRequestMessage
  | DeleteSessionMessage
  | ListSessionsMessage
  | PingMessage;

// ─── Bridge → Phone ──────────────────────────────────────────────────

export interface EventMessage {
  type: "event";
  sessionId: string;
  event: AgentEvent;
  timestamp: number;
}

export interface SessionListMessage {
  type: "session_list";
  sessions: SessionInfo[];
}

export interface FileContentMessage {
  type: "file_content";
  path: string;
  content: string;
  language: string;
}

export interface PongMessage {
  type: "pong";
  latencyMs: number;
}

export interface ErrorResponseMessage {
  type: "error";
  message: string;
}

export type BridgeMessage =
  | EventMessage
  | SessionListMessage
  | FileContentMessage
  | PongMessage
  | ErrorResponseMessage;

// ─── E2E Encrypted Wire Format ───────────────────────────────────────

export interface EncryptedWireMessage {
  v: 1;
  nonce: string;       // 12 bytes, base64
  ciphertext: string;  // base64
  tag: string;         // 16 bytes, base64 (GCM auth tag)
}
