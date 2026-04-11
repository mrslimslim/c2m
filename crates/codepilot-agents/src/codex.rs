use std::{
    collections::HashMap,
    io::{BufRead, BufReader, Read, Write},
    path::Path,
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_protocol::{
    events::{AgentEvent, CommandExecStatus},
    messages::{ApprovalPolicy, SandboxMode},
    state::{AgentState, AgentType, FileChange, FileChangeKind, SessionInfo, TokenUsage},
};
use serde_json::Value;

use crate::types::{AgentAdapter, AgentError, Result, SessionOptions};

const DEFAULT_MODEL: &str = "gpt-5.4";
const DEFAULT_REASONING_EFFORT: codepilot_protocol::messages::ModelReasoningEffort =
    codepilot_protocol::messages::ModelReasoningEffort::Medium;
const DEFAULT_APPROVAL_POLICY: codepilot_protocol::messages::ApprovalPolicy =
    codepilot_protocol::messages::ApprovalPolicy::OnRequest;
const DEFAULT_SANDBOX_MODE: codepilot_protocol::messages::SandboxMode =
    codepilot_protocol::messages::SandboxMode::WorkspaceWrite;
const UNSTABLE_FEATURE_WARNING_PREFIX: &str = "Under-development features enabled:";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexCommandStatus {
    Running,
    Done,
    Failed,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CodexItem {
    AgentMessage {
        id: String,
        text: String,
    },
    Reasoning {
        id: String,
        text: String,
    },
    CommandExecution {
        id: String,
        command: String,
        output: Option<String>,
        exit_code: Option<i64>,
        status: CodexCommandStatus,
    },
    FileChange {
        id: String,
        changes: Vec<(String, String)>,
    },
    Other {
        id: String,
        item_type: String,
        payload: serde_json::Value,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum CodexThreadEvent {
    ThreadStarted {
        thread_id: String,
    },
    TurnStarted,
    ItemStarted {
        item: CodexItem,
    },
    ItemUpdated {
        item: CodexItem,
    },
    ItemCompleted {
        item: CodexItem,
    },
    TurnCompleted {
        input_tokens: u64,
        cached_input_tokens: Option<u64>,
        output_tokens: u64,
    },
    TurnFailed {
        message: String,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Clone)]
struct ActiveSession {
    info: SessionInfo,
    text_item_snapshots: HashMap<String, String>,
    options: SessionOptions,
    running_child: Option<Arc<Mutex<Child>>>,
}

#[derive(Debug, Default)]
struct CodexState {
    sessions: HashMap<String, ActiveSession>,
    aliases: HashMap<String, String>,
}

pub struct CodexAdapter {
    state: Mutex<CodexState>,
    counter: AtomicU64,
}

impl CodexAdapter {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(CodexState::default()),
            counter: AtomicU64::new(0),
        }
    }

    fn next_session_identity(&self) -> (String, i64) {
        let now = Self::now_ms();
        let seq = self.counter.fetch_add(1, Ordering::Relaxed) + 1;
        (format!("codex-{now}-{seq:06x}"), now)
    }

    pub fn canonical_session_id(&self, session_id: &str) -> Option<String> {
        let state = self.state.lock().ok()?;
        Self::canonical_session_id_locked(&state, session_id)
    }

    fn canonical_session_id_locked(state: &CodexState, session_id: &str) -> Option<String> {
        let mut current = session_id;
        while let Some(next) = state.aliases.get(current) {
            if next == current {
                break;
            }
            current = next;
        }
        state
            .sessions
            .contains_key(current)
            .then(|| current.to_owned())
    }

    pub fn consume_events(
        &self,
        session_id: &str,
        events: Vec<CodexThreadEvent>,
    ) -> Result<Vec<AgentEvent>> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| AgentError::new("failed to lock codex adapter state"))?;
        let canonical = Self::canonical_session_id_locked(&state, session_id)
            .unwrap_or_else(|| session_id.to_owned());
        let mut session = state
            .sessions
            .remove(&canonical)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;

        let original_id = session.info.id.clone();
        let mut mapped = Vec::new();

        for event in events {
            session.info.last_active_at = Self::now_ms();
            match event {
                CodexThreadEvent::ThreadStarted { thread_id } => {
                    if thread_id != session.info.id {
                        state.aliases.insert(original_id.clone(), thread_id.clone());
                        state.aliases.insert(thread_id.clone(), thread_id.clone());
                        session.info.id = thread_id;
                    }
                }
                CodexThreadEvent::TurnStarted => {}
                CodexThreadEvent::ItemStarted { item } => {
                    mapped.extend(Self::map_item_event(&mut session, item, false));
                }
                CodexThreadEvent::ItemUpdated { item } => {
                    mapped.extend(Self::map_item_event(&mut session, item, false));
                }
                CodexThreadEvent::ItemCompleted { item } => {
                    mapped.extend(Self::map_item_event(&mut session, item, true));
                }
                CodexThreadEvent::TurnCompleted {
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                } => {
                    session.info.state = AgentState::Idle;
                    mapped.push(AgentEvent::TurnCompleted {
                        summary: "Turn completed".to_owned(),
                        files_changed: Vec::new(),
                        usage: Some(TokenUsage {
                            input_tokens,
                            output_tokens,
                            cached_input_tokens,
                        }),
                    });
                    session.text_item_snapshots.clear();
                }
                CodexThreadEvent::TurnFailed { message } | CodexThreadEvent::Error { message } => {
                    session.info.state = AgentState::Error;
                    session.text_item_snapshots.clear();
                    mapped.push(AgentEvent::Error { message });
                }
            }
        }

        let final_id = session.info.id.clone();
        state.sessions.insert(final_id.clone(), session);
        state.aliases.insert(final_id.clone(), final_id);
        Ok(mapped)
    }

    fn map_item_event(
        session: &mut ActiveSession,
        item: CodexItem,
        completed: bool,
    ) -> Vec<AgentEvent> {
        match item {
            CodexItem::AgentMessage { id, text } => Self::map_streaming_text_item(
                &mut session.text_item_snapshots,
                &id,
                &text,
                completed,
                |text| AgentEvent::AgentMessage { text },
            ),
            CodexItem::Reasoning { id, text } => {
                session.info.state = AgentState::Thinking;
                Self::map_streaming_text_item(
                    &mut session.text_item_snapshots,
                    &id,
                    &text,
                    completed,
                    |text| AgentEvent::Thinking { text },
                )
            }
            CodexItem::CommandExecution {
                id: _,
                command,
                output,
                exit_code,
                status,
            } => {
                session.info.state = AgentState::RunningCommand;
                vec![AgentEvent::CommandExec {
                    command,
                    output,
                    exit_code,
                    status: match status {
                        CodexCommandStatus::Running => CommandExecStatus::Running,
                        CodexCommandStatus::Done => CommandExecStatus::Done,
                        CodexCommandStatus::Failed => CommandExecStatus::Failed,
                    },
                }]
            }
            CodexItem::FileChange { id: _, changes } => {
                session.info.state = AgentState::Coding;
                vec![AgentEvent::CodeChange {
                    changes: changes
                        .into_iter()
                        .map(|(path, kind)| FileChange {
                            path: Self::normalize_file_change_path(
                                &session.options.work_dir,
                                &path,
                            ),
                            kind: match kind.as_str() {
                                "add" => FileChangeKind::Add,
                                "delete" => FileChangeKind::Delete,
                                _ => FileChangeKind::Update,
                            },
                        })
                        .collect(),
                }]
            }
            CodexItem::Other {
                id: _,
                item_type,
                payload,
            } => {
                if Self::should_ignore_item(&item_type, &payload) {
                    Vec::new()
                } else {
                    vec![AgentEvent::Status {
                        state: session.info.state,
                        message: format!("[{item_type}] {}", payload),
                    }]
                }
            }
        }
    }

    fn map_streaming_text_item(
        snapshots: &mut HashMap<String, String>,
        item_id: &str,
        incoming_text: &str,
        completed: bool,
        map_event: impl FnOnce(String) -> AgentEvent,
    ) -> Vec<AgentEvent> {
        let previous_text = if item_id.is_empty() {
            None
        } else {
            snapshots.get(item_id).cloned()
        };

        let delta = match previous_text.as_deref() {
            Some(previous) if incoming_text == previous => String::new(),
            Some(previous) if incoming_text.starts_with(previous) => {
                incoming_text[previous.len()..].to_owned()
            }
            _ => incoming_text.to_owned(),
        };

        if !item_id.is_empty() {
            if completed {
                snapshots.remove(item_id);
            } else {
                snapshots.insert(item_id.to_owned(), incoming_text.to_owned());
            }
        }

        if delta.is_empty() {
            Vec::new()
        } else {
            vec![map_event(delta)]
        }
    }

    fn should_ignore_item(item_type: &str, payload: &Value) -> bool {
        if item_type != "error" {
            return false;
        }

        payload
            .get("message")
            .and_then(Value::as_str)
            .is_some_and(|message| message.starts_with(UNSTABLE_FEATURE_WARNING_PREFIX))
    }

    fn normalize_file_change_path(work_dir: &Path, path: &str) -> String {
        let candidate = Path::new(path);
        if !candidate.is_absolute() {
            return path.to_owned();
        }

        let canonical_work_dir =
            std::fs::canonicalize(work_dir).unwrap_or_else(|_| work_dir.to_path_buf());
        let resolved = std::fs::canonicalize(candidate).unwrap_or_else(|_| candidate.to_path_buf());
        resolved
            .strip_prefix(&canonical_work_dir)
            .ok()
            .map(|relative| {
                relative
                    .to_string_lossy()
                    .trim_start_matches('/')
                    .to_owned()
            })
            .filter(|relative| !relative.is_empty())
            .unwrap_or_else(|| path.to_owned())
    }

    fn resolved_options(options: SessionOptions) -> SessionOptions {
        SessionOptions {
            work_dir: options.work_dir,
            model: Some(options.model.unwrap_or_else(|| DEFAULT_MODEL.to_owned())),
            model_reasoning_effort: Some(
                options
                    .model_reasoning_effort
                    .unwrap_or(DEFAULT_REASONING_EFFORT),
            ),
            approval_policy: Some(options.approval_policy.unwrap_or(DEFAULT_APPROVAL_POLICY)),
            sandbox_mode: Some(options.sandbox_mode.unwrap_or(DEFAULT_SANDBOX_MODE)),
        }
    }

    fn merge_options(current: &SessionOptions, overrides: SessionOptions) -> SessionOptions {
        SessionOptions {
            work_dir: overrides.work_dir,
            model: overrides.model.or_else(|| current.model.clone()),
            model_reasoning_effort: overrides
                .model_reasoning_effort
                .or(current.model_reasoning_effort),
            approval_policy: overrides.approval_policy.or(current.approval_policy),
            sandbox_mode: overrides.sandbox_mode.or(current.sandbox_mode),
        }
    }

    fn should_bypass_approvals_and_sandbox(options: &SessionOptions) -> bool {
        options.approval_policy == Some(ApprovalPolicy::Never)
            && options.sandbox_mode == Some(SandboxMode::DangerFullAccess)
    }

    fn now_ms() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as i64)
            .unwrap_or(0)
    }

    fn command_args(options: &SessionOptions, session_id: Option<&str>) -> Vec<String> {
        let mut args = vec!["exec".to_owned(), "--json".to_owned()];

        if Self::should_bypass_approvals_and_sandbox(options) {
            args.push("--dangerously-bypass-approvals-and-sandbox".to_owned());
        }
        if let Some(model) = &options.model {
            args.push("--model".to_owned());
            args.push(model.clone());
        }
        args.push("--config".to_owned());
        args.push("suppress_unstable_features_warning=true".to_owned());
        if let Some(sandbox_mode) = options.sandbox_mode
            && !Self::should_bypass_approvals_and_sandbox(options)
        {
            args.push("--sandbox".to_owned());
            args.push(match sandbox_mode {
                SandboxMode::ReadOnly => "read-only".to_owned(),
                SandboxMode::WorkspaceWrite => "workspace-write".to_owned(),
                SandboxMode::DangerFullAccess => "danger-full-access".to_owned(),
            });
        }

        args.push("--cd".to_owned());
        args.push(options.work_dir.to_string_lossy().into_owned());
        args.push("--skip-git-repo-check".to_owned());

        if let Some(reasoning) = options.model_reasoning_effort {
            args.push("--config".to_owned());
            args.push(format!(
                "model_reasoning_effort=\"{}\"",
                match reasoning {
                    codepilot_protocol::messages::ModelReasoningEffort::Minimal => "minimal",
                    codepilot_protocol::messages::ModelReasoningEffort::Low => "low",
                    codepilot_protocol::messages::ModelReasoningEffort::Medium => "medium",
                    codepilot_protocol::messages::ModelReasoningEffort::High => "high",
                    codepilot_protocol::messages::ModelReasoningEffort::Xhigh => "xhigh",
                }
            ));
        }
        if let Some(approval) = options.approval_policy
            && !Self::should_bypass_approvals_and_sandbox(options)
        {
            args.push("--config".to_owned());
            args.push(format!(
                "approval_policy=\"{}\"",
                match approval {
                    ApprovalPolicy::Never => "never",
                    ApprovalPolicy::OnRequest => "on-request",
                    ApprovalPolicy::OnFailure => "on-failure",
                    ApprovalPolicy::Untrusted => "untrusted",
                }
            ));
        }
        if let Some(real_session_id) = session_id
            && !real_session_id.starts_with("codex-")
        {
            args.push("resume".to_owned());
            args.push(real_session_id.to_owned());
        }

        args
    }

    fn parse_thread_event(line: &str) -> Result<Option<CodexThreadEvent>> {
        let trimmed = line.trim();
        if trimmed.is_empty() || !trimmed.starts_with('{') {
            return Ok(None);
        }

        let value: Value =
            serde_json::from_str(trimmed).map_err(|error| AgentError::new(error.to_string()))?;
        let Some(event_type) = value.get("type").and_then(Value::as_str) else {
            return Ok(None);
        };

        match event_type {
            "thread.started" => Ok(Some(CodexThreadEvent::ThreadStarted {
                thread_id: value
                    .get("thread_id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| AgentError::new("thread.started is missing thread_id"))?
                    .to_owned(),
            })),
            "turn.started" => Ok(Some(CodexThreadEvent::TurnStarted)),
            "item.started" => Ok(Some(CodexThreadEvent::ItemStarted {
                item: Self::parse_item(value.get("item").cloned().unwrap_or(Value::Null)),
            })),
            "item.updated" => Ok(Some(CodexThreadEvent::ItemUpdated {
                item: Self::parse_item(value.get("item").cloned().unwrap_or(Value::Null)),
            })),
            "item.completed" => Ok(Some(CodexThreadEvent::ItemCompleted {
                item: Self::parse_item(value.get("item").cloned().unwrap_or(Value::Null)),
            })),
            "turn.completed" => {
                let usage = value.get("usage").cloned().unwrap_or(Value::Null);
                Ok(Some(CodexThreadEvent::TurnCompleted {
                    input_tokens: usage
                        .get("input_tokens")
                        .and_then(Value::as_u64)
                        .unwrap_or(0),
                    cached_input_tokens: usage.get("cached_input_tokens").and_then(Value::as_u64),
                    output_tokens: usage
                        .get("output_tokens")
                        .and_then(Value::as_u64)
                        .unwrap_or(0),
                }))
            }
            "turn.failed" => Ok(Some(CodexThreadEvent::TurnFailed {
                message: value
                    .get("error")
                    .and_then(|error| error.get("message"))
                    .and_then(Value::as_str)
                    .or_else(|| value.get("message").and_then(Value::as_str))
                    .unwrap_or("Turn failed")
                    .to_owned(),
            })),
            "error" => Ok(Some(CodexThreadEvent::Error {
                message: value
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Unknown error")
                    .to_owned(),
            })),
            _ => Ok(None),
        }
    }

    fn parse_item(value: Value) -> CodexItem {
        let item_id = value
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let item_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned();

        match item_type.as_str() {
            "agent_message" => CodexItem::AgentMessage {
                id: item_id.clone(),
                text: value
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            },
            "reasoning" => CodexItem::Reasoning {
                id: item_id.clone(),
                text: value
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            },
            "command_execution" => CodexItem::CommandExecution {
                id: item_id.clone(),
                command: value
                    .get("command")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                output: value
                    .get("aggregated_output")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
                    .or_else(|| {
                        value
                            .get("output")
                            .and_then(Value::as_str)
                            .map(ToOwned::to_owned)
                    }),
                exit_code: value.get("exit_code").and_then(Value::as_i64),
                status: match value
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("running")
                {
                    "done" | "completed" => CodexCommandStatus::Done,
                    "failed" => CodexCommandStatus::Failed,
                    _ => CodexCommandStatus::Running,
                },
            },
            "file_change" => {
                let changes = value
                    .get("changes")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|change| {
                        (
                            change
                                .get("path")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_owned(),
                            change
                                .get("kind")
                                .and_then(Value::as_str)
                                .unwrap_or("update")
                                .to_owned(),
                        )
                    })
                    .collect();
                CodexItem::FileChange {
                    id: item_id.clone(),
                    changes,
                }
            }
            _ => CodexItem::Other {
                id: item_id,
                item_type,
                payload: value,
            },
        }
    }
}

impl Default for CodexAdapter {
    fn default() -> Self {
        Self::new()
    }
}

impl AgentAdapter for CodexAdapter {
    fn name(&self) -> AgentType {
        AgentType::Codex
    }

    fn start_session(&self, options: SessionOptions) -> Result<SessionInfo> {
        let (id, now) = self.next_session_identity();
        let resolved = Self::resolved_options(options.clone());
        let info = SessionInfo {
            id: id.clone(),
            agent_type: AgentType::Codex,
            work_dir: options.work_dir.to_string_lossy().into_owned(),
            state: AgentState::Idle,
            created_at: now,
            last_active_at: now,
        };
        let mut state = self
            .state
            .lock()
            .map_err(|_| AgentError::new("failed to lock codex adapter state"))?;
        state.sessions.insert(
            id.clone(),
            ActiveSession {
                info: info.clone(),
                text_item_snapshots: HashMap::new(),
                options: resolved,
                running_child: None,
            },
        );
        state.aliases.insert(id.clone(), id);
        Ok(info)
    }

    fn execute(
        &self,
        session_id: &str,
        input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        options: Option<SessionOptions>,
    ) -> Result<()> {
        let canonical = {
            let state = self
                .state
                .lock()
                .map_err(|_| AgentError::new("failed to lock codex adapter state"))?;
            Self::canonical_session_id_locked(&state, session_id)
                .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?
        };

        let (resolved_options, current_thread_id) = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| AgentError::new("failed to lock codex adapter state"))?;
            let session = state
                .sessions
                .get_mut(&canonical)
                .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
            if let Some(options) = options {
                session.options =
                    Self::merge_options(&session.options, Self::resolved_options(options));
                session.info.work_dir = session.options.work_dir.to_string_lossy().into_owned();
            }
            session.info.state = AgentState::Thinking;
            session.info.last_active_at = Self::now_ms();
            (session.options.clone(), session.info.id.clone())
        };

        on_event(AgentEvent::Status {
            state: AgentState::Thinking,
            message: "Processing...".to_owned(),
        });

        let mut command = Command::new("codex");
        command.args(Self::command_args(
            &resolved_options,
            Some(current_thread_id.as_str()),
        ));
        command.stdin(Stdio::piped());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());
        command.env("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "codepilot_bridge");

        let mut child = command.spawn().map_err(|error| {
            AgentError::new(format!(
                "Failed to spawn codex CLI: {error}. Install it with: npm install -g @openai/codex"
            ))
        })?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(input.as_bytes())
                .map_err(|error| AgentError::new(error.to_string()))?;
        }

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AgentError::new("codex child process has no stdout"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| AgentError::new("codex child process has no stderr"))?;

        let child_ref = Arc::new(Mutex::new(child));
        if let Ok(mut state) = self.state.lock()
            && let Some(session) = state.sessions.get_mut(&canonical)
        {
            session.running_child = Some(child_ref.clone());
        }

        let stderr_reader = thread::spawn(move || {
            let mut stderr_output = String::new();
            let _ = BufReader::new(stderr).read_to_string(&mut stderr_output);
            stderr_output
        });

        let mut active_session_id = session_id.to_owned();
        for line in BufReader::new(stdout).lines() {
            let line = line.map_err(|error| AgentError::new(error.to_string()))?;
            let Some(event) = Self::parse_thread_event(&line)? else {
                continue;
            };
            let mapped = self.consume_events(&active_session_id, vec![event])?;
            if let Some(canonical) = self.canonical_session_id(&active_session_id) {
                active_session_id = canonical;
            }
            for event in mapped {
                on_event(event);
            }
        }

        let status = child_ref
            .lock()
            .map_err(|_| AgentError::new("failed to lock codex child"))?
            .wait()
            .map_err(|error| AgentError::new(error.to_string()))?;
        let stderr_output = stderr_reader.join().unwrap_or_default();

        if let Ok(mut state) = self.state.lock()
            && let Some(canonical) = Self::canonical_session_id_locked(&state, &active_session_id)
            && let Some(session) = state.sessions.get_mut(&canonical)
        {
            session.running_child = None;
            session.info.state = if status.success() {
                AgentState::Idle
            } else {
                AgentState::Error
            };
            session.info.last_active_at = Self::now_ms();
        }

        if !status.success() {
            return Err(AgentError::new(format!(
                "Codex CLI exited with code {}: {}",
                status.code().unwrap_or(-1),
                stderr_output.trim()
            )));
        }

        Ok(())
    }

    fn resume_session(&self, session_id: &str) -> Result<SessionInfo> {
        let state = self
            .state
            .lock()
            .map_err(|_| AgentError::new("failed to lock codex adapter state"))?;
        let canonical = Self::canonical_session_id_locked(&state, session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        state
            .sessions
            .get(&canonical)
            .map(|session| session.info.clone())
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))
    }

    fn cancel(&self, session_id: &str) -> Result<()> {
        let child = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| AgentError::new("failed to lock codex adapter state"))?;
            let canonical = Self::canonical_session_id_locked(&state, session_id)
                .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
            let session = state
                .sessions
                .get_mut(&canonical)
                .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
            session.info.state = AgentState::Idle;
            session.info.last_active_at = Self::now_ms();
            session.running_child.take()
        };
        if let Some(child) = child
            && let Ok(mut child) = child.lock()
        {
            let _ = child.kill();
        }
        Ok(())
    }

    fn delete_session(&self, session_id: &str) -> Result<()> {
        let session = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| AgentError::new("failed to lock codex adapter state"))?;
            let canonical = Self::canonical_session_id_locked(&state, session_id)
                .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
            let session = state
                .sessions
                .remove(&canonical)
                .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
            state.aliases.retain(|_, value| value != &canonical);
            session
        };
        if let Some(child) = session.running_child
            && let Ok(mut child) = child.lock()
        {
            let _ = child.kill();
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{CodexAdapter, CodexThreadEvent};
    use crate::types::SessionOptions;
    use std::path::PathBuf;

    #[test]
    fn parse_thread_event_accepts_turn_started_events_from_codex_cli() {
        let parsed = CodexAdapter::parse_thread_event(r#"{"type":"turn.started"}"#);

        assert!(
            matches!(parsed, Ok(Some(CodexThreadEvent::TurnStarted))),
            "expected turn.started to parse, got {parsed:?}"
        );
    }

    #[test]
    fn parse_thread_event_ignores_unknown_event_types_from_codex_cli() {
        let parsed =
            CodexAdapter::parse_thread_event(r#"{"type":"turn.progress","message":"streaming"}"#);

        assert!(
            matches!(parsed, Ok(None)),
            "expected unknown event types to be ignored, got {parsed:?}"
        );
    }

    #[test]
    fn parse_thread_event_ignores_non_json_noise_lines() {
        let parsed = CodexAdapter::parse_thread_event("warning: transient stdout noise");

        assert!(
            matches!(parsed, Ok(None)),
            "expected non-JSON lines to be ignored, got {parsed:?}"
        );
    }

    #[test]
    fn command_args_suppress_unstable_feature_warnings() {
        let args = CodexAdapter::command_args(
            &SessionOptions {
                work_dir: PathBuf::from("/tmp/project"),
                model: None,
                model_reasoning_effort: None,
                approval_policy: None,
                sandbox_mode: None,
            },
            None,
        );

        assert!(
            args.windows(2).any(|window| {
                window == ["--config", "suppress_unstable_features_warning=true"]
            }),
            "expected command args to suppress unstable feature warnings, got {args:?}"
        );
    }
}
