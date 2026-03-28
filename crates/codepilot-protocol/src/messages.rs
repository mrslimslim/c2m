use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Number;

use crate::{
    events::AgentEvent,
    state::{AgentType, DiffFile, DiffHunk, FileSearchMatch, SessionInfo},
};

pub const SESSION_REPLAY_CAPABILITY: &str = "session_replay_v1";
pub const SLASH_CATALOG_CAPABILITY: &str = "slash_catalog_v1";

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum HandshakeMessageType {
    #[serde(rename = "handshake")]
    Handshake,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum HandshakeOkMessageType {
    #[serde(rename = "handshake_ok")]
    HandshakeOk,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HandshakeMessage {
    #[serde(rename = "type")]
    pub message_type: HandshakeMessageType,
    #[serde(rename = "phone_pubkey")]
    pub phone_pubkey: String,
    pub otp: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HandshakeOkMessage {
    #[serde(rename = "type")]
    pub message_type: HandshakeOkMessageType,
    pub encrypted: bool,
    #[serde(default, rename = "clientId", skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ModelReasoningEffort {
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ApprovalPolicy {
    #[serde(rename = "never")]
    Never,
    #[serde(rename = "on-request")]
    OnRequest,
    #[serde(rename = "on-failure")]
    OnFailure,
    #[serde(rename = "untrusted")]
    Untrusted,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum SandboxMode {
    #[serde(rename = "read-only")]
    ReadOnly,
    #[serde(rename = "workspace-write")]
    WorkspaceWrite,
    #[serde(rename = "danger-full-access")]
    DangerFullAccess,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_reasoning_effort: Option<ModelReasoningEffort>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<ApprovalPolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<SandboxMode>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SlashCommandKind {
    Workflow,
    BridgeAction,
    ClientAction,
    InsertText,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SlashAvailability {
    Enabled,
    Disabled,
    Hidden,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SlashMenuPresentation {
    List,
    Grid,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SlashOptionBadge {
    Default,
    Recommended,
    Experimental,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum SlashActionArgumentValue {
    String(String),
    Number(Number),
    Boolean(bool),
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum SlashSessionConfigField {
    #[serde(rename = "model")]
    Model,
    #[serde(rename = "modelReasoningEffort")]
    ModelReasoningEffort,
    #[serde(rename = "approvalPolicy")]
    ApprovalPolicy,
    #[serde(rename = "sandboxMode")]
    SandboxMode,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SlashEffect {
    SetSessionConfig {
        field: SlashSessionConfigField,
        value: String,
    },
    SetInputText {
        value: String,
    },
    ClearInputText {},
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SlashActionMeta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arguments: Option<BTreeMap<String, SlashActionArgumentValue>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SlashMenuOption {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub badges: Option<Vec<SlashOptionBadge>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effects: Option<Vec<SlashEffect>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<Box<SlashMenuNode>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SlashMenuNode {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub helper_text: Option<String>,
    pub presentation: SlashMenuPresentation,
    pub options: Vec<SlashMenuOption>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SlashCommandMeta {
    pub id: String,
    pub label: String,
    pub description: String,
    pub kind: SlashCommandKind,
    pub availability: SlashAvailability,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disabled_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_terms: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub menu: Option<SlashMenuNode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<SlashActionMeta>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PhoneMessage {
    Command {
        text: String,
        #[serde(default, rename = "sessionId", skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        config: Option<SessionConfig>,
    },
    Cancel {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    FileReq {
        path: String,
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    FileSearchReq {
        #[serde(rename = "sessionId")]
        session_id: String,
        query: String,
        limit: u64,
    },
    DeleteSession {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    ListSessions {},
    Ping {
        ts: i64,
    },
    SyncSession {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "afterEventId")]
        after_event_id: u64,
    },
    DiffReq {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "eventId")]
        event_id: u64,
    },
    DiffHunksReq {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "eventId")]
        event_id: u64,
        path: String,
        #[serde(rename = "afterHunkIndex")]
        after_hunk_index: u64,
    },
    SlashAction {
        #[serde(default, rename = "sessionId", skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(rename = "commandId")]
        command_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        arguments: Option<BTreeMap<String, SlashActionArgumentValue>>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BridgeMessage {
    Event {
        #[serde(rename = "sessionId")]
        session_id: String,
        event: AgentEvent,
        #[serde(rename = "eventId")]
        event_id: u64,
        timestamp: i64,
    },
    SessionList {
        sessions: Vec<SessionInfo>,
    },
    FileContent {
        path: String,
        content: String,
        language: String,
    },
    FileSearchResults {
        #[serde(rename = "sessionId")]
        session_id: String,
        query: String,
        results: Vec<FileSearchMatch>,
    },
    Pong {
        #[serde(rename = "latencyMs")]
        latency_ms: i64,
    },
    Error {
        message: String,
    },
    SessionSyncComplete {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "latestEventId")]
        latest_event_id: u64,
        #[serde(
            default,
            rename = "resolvedSessionId",
            skip_serializing_if = "Option::is_none"
        )]
        resolved_session_id: Option<String>,
    },
    DiffContent {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "eventId")]
        event_id: u64,
        files: Vec<DiffFile>,
    },
    DiffHunksContent {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "eventId")]
        event_id: u64,
        path: String,
        hunks: Vec<DiffHunk>,
        #[serde(
            default,
            rename = "nextHunkIndex",
            skip_serializing_if = "Option::is_none"
        )]
        next_hunk_index: Option<u64>,
    },
    SlashCatalog {
        capability: String,
        adapter: AgentType,
        #[serde(
            default,
            rename = "adapterVersion",
            skip_serializing_if = "Option::is_none"
        )]
        adapter_version: Option<String>,
        #[serde(rename = "catalogVersion")]
        catalog_version: String,
        defaults: SessionConfig,
        commands: Vec<SlashCommandMeta>,
    },
    SlashActionResult {
        #[serde(rename = "commandId")]
        command_id: String,
        ok: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EncryptedWireMessage {
    pub v: u8,
    pub nonce: String,
    pub ciphertext: String,
    pub tag: String,
}
