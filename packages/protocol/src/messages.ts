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

export const SESSION_REPLAY_CAPABILITY = "session_replay_v1";
export const SLASH_CATALOG_CAPABILITY = "slash_catalog_v1";

export type ModelReasoningEffort = "minimal" | "low" | "medium" | "high" | "xhigh";

export interface HandshakeOkMessage {
  type: "handshake_ok";
  encrypted: boolean;
  clientId?: string;
  capabilities?: string[];
}

// ─── Session Configuration ──────────────────────────────────────────

export interface SessionConfig {
  model?: string;
  modelReasoningEffort?: ModelReasoningEffort;
  approvalPolicy?: "never" | "on-request" | "on-failure" | "untrusted";
  sandboxMode?: "read-only" | "workspace-write" | "danger-full-access";
}

// ─── Slash Catalog ────────────────────────────────────────────────────

export type SlashCommandKind = "workflow" | "bridge_action" | "client_action" | "insert_text";
export type SlashAvailability = "enabled" | "disabled" | "hidden";
export type SlashMenuPresentation = "list" | "grid";
export type SlashOptionBadge = "default" | "recommended" | "experimental";
export type SlashActionArgumentValue = string | number | boolean;
export type SlashSessionConfigField =
  | "model"
  | "modelReasoningEffort"
  | "approvalPolicy"
  | "sandboxMode";

export type SlashEffect =
  | {
      type: "set_session_config";
      field: SlashSessionConfigField;
      value: string;
    }
  | {
      type: "set_input_text";
      value: string;
    }
  | {
      type: "clear_input_text";
    };

export interface SlashActionMeta {
  inputText?: string;
  arguments?: Record<string, SlashActionArgumentValue>;
}

export interface SlashMenuOption {
  id: string;
  label: string;
  description?: string;
  badges?: SlashOptionBadge[];
  effects?: SlashEffect[];
  next?: SlashMenuNode;
}

export interface SlashMenuNode {
  title: string;
  helperText?: string;
  presentation: SlashMenuPresentation;
  options: SlashMenuOption[];
}

export interface SlashCommandMeta {
  id: string;
  label: string;
  description: string;
  kind: SlashCommandKind;
  availability: SlashAvailability;
  disabledReason?: string;
  searchTerms?: string[];
  menu?: SlashMenuNode;
  action?: SlashActionMeta;
}

export interface SlashCatalogMessage {
  type: "slash_catalog";
  capability: typeof SLASH_CATALOG_CAPABILITY;
  adapter: SessionInfo["agentType"];
  adapterVersion?: string;
  catalogVersion: string;
  defaults: SessionConfig;
  commands: SlashCommandMeta[];
}

export interface SlashActionMessage {
  type: "slash_action";
  sessionId?: string;
  commandId: string;
  arguments?: Record<string, SlashActionArgumentValue>;
}

export interface SlashActionResultMessage {
  type: "slash_action_result";
  commandId: string;
  ok: boolean;
  message?: string;
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

export interface SyncSessionMessage {
  type: "sync_session";
  sessionId: string;
  afterEventId: number;
}

export type PhoneMessage =
  | CommandMessage
  | CancelMessage
  | FileRequestMessage
  | DeleteSessionMessage
  | ListSessionsMessage
  | PingMessage
  | SyncSessionMessage
  | SlashActionMessage;

// ─── Bridge → Phone ──────────────────────────────────────────────────

export interface EventMessage {
  type: "event";
  sessionId: string;
  event: AgentEvent;
  eventId: number;
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

export interface SessionSyncCompleteMessage {
  type: "session_sync_complete";
  sessionId: string;
  latestEventId: number;
  resolvedSessionId?: string;
}

export type BridgeMessage =
  | EventMessage
  | SessionListMessage
  | FileContentMessage
  | PongMessage
  | ErrorResponseMessage
  | SessionSyncCompleteMessage
  | SlashCatalogMessage
  | SlashActionResultMessage;

// ─── E2E Encrypted Wire Format ───────────────────────────────────────

export interface EncryptedWireMessage {
  v: 1;
  nonce: string;       // 12 bytes, base64
  ciphertext: string;  // base64
  tag: string;         // 16 bytes, base64 (GCM auth tag)
}
