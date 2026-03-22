use std::{
    collections::HashMap,
    io::{BufRead, BufReader, Read, Write},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexCommandStatus {
    Running,
    Done,
    Failed,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CodexItem {
    AgentMessage {
        text: String,
    },
    Reasoning {
        text: String,
    },
    CommandExecution {
        command: String,
        output: Option<String>,
        exit_code: Option<i64>,
        status: CodexCommandStatus,
    },
    FileChange {
        changes: Vec<(String, String)>,
    },
    Other {
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
    options: SessionOptions,
    running_child: Option<Arc<Mutex<Child>>>,
}

pub struct CodexAdapter {
    sessions: HashMap<String, ActiveSession>,
    aliases: HashMap<String, String>,
    counter: u64,
}

impl CodexAdapter {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            aliases: HashMap::new(),
            counter: 0,
        }
    }

    pub fn canonical_session_id(&self, session_id: &str) -> Option<String> {
        let mut current = session_id;
        while let Some(next) = self.aliases.get(current) {
            if next == current {
                break;
            }
            current = next;
        }
        self.sessions
            .contains_key(current)
            .then(|| current.to_owned())
    }

    pub fn consume_events(
        &mut self,
        session_id: &str,
        events: Vec<CodexThreadEvent>,
    ) -> Result<Vec<AgentEvent>> {
        let canonical = self
            .canonical_session_id(session_id)
            .unwrap_or_else(|| session_id.to_owned());
        let mut session = self
            .sessions
            .remove(&canonical)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;

        let original_id = session.info.id.clone();
        let mut mapped = Vec::new();

        for event in events {
            match event {
                CodexThreadEvent::ThreadStarted { thread_id } => {
                    if thread_id != session.info.id {
                        self.aliases.insert(original_id.clone(), thread_id.clone());
                        self.aliases.insert(thread_id.clone(), thread_id.clone());
                        session.info.id = thread_id;
                    }
                }
                CodexThreadEvent::TurnStarted => {}
                CodexThreadEvent::ItemStarted { item }
                | CodexThreadEvent::ItemUpdated { item }
                | CodexThreadEvent::ItemCompleted { item } => {
                    mapped.extend(Self::map_item_event(&mut session, item));
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
                }
                CodexThreadEvent::TurnFailed { message } | CodexThreadEvent::Error { message } => {
                    session.info.state = AgentState::Error;
                    mapped.push(AgentEvent::Error { message });
                }
            }
        }

        let final_id = session.info.id.clone();
        self.sessions.insert(final_id.clone(), session);
        self.aliases.insert(final_id.clone(), final_id);
        Ok(mapped)
    }

    fn map_item_event(session: &mut ActiveSession, item: CodexItem) -> Vec<AgentEvent> {
        match item {
            CodexItem::AgentMessage { text } => vec![AgentEvent::AgentMessage { text }],
            CodexItem::Reasoning { text } => {
                session.info.state = AgentState::Thinking;
                vec![AgentEvent::Thinking { text }]
            }
            CodexItem::CommandExecution {
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
            CodexItem::FileChange { changes } => {
                session.info.state = AgentState::Coding;
                vec![AgentEvent::CodeChange {
                    changes: changes
                        .into_iter()
                        .map(|(path, kind)| FileChange {
                            path,
                            kind: match kind.as_str() {
                                "add" => FileChangeKind::Add,
                                "delete" => FileChangeKind::Delete,
                                _ => FileChangeKind::Update,
                            },
                        })
                        .collect(),
                }]
            }
            CodexItem::Other { item_type, payload } => vec![AgentEvent::Status {
                state: session.info.state,
                message: format!("[{item_type}] {}", payload),
            }],
        }
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

    fn command_args(options: &SessionOptions, session_id: Option<&str>) -> Vec<String> {
        let mut args = vec!["exec".to_owned(), "--experimental-json".to_owned()];

        if Self::should_bypass_approvals_and_sandbox(options) {
            args.push("--dangerously-bypass-approvals-and-sandbox".to_owned());
        }
        if let Some(model) = &options.model {
            args.push("--model".to_owned());
            args.push(model.clone());
        }
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

    fn parse_thread_event(line: &str) -> Result<CodexThreadEvent> {
        let value: Value =
            serde_json::from_str(line).map_err(|error| AgentError::new(error.to_string()))?;
        let event_type = value
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| AgentError::new("codex event is missing a type"))?;

        match event_type {
            "thread.started" => Ok(CodexThreadEvent::ThreadStarted {
                thread_id: value
                    .get("thread_id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| AgentError::new("thread.started is missing thread_id"))?
                    .to_owned(),
            }),
            "turn.started" => Ok(CodexThreadEvent::TurnStarted),
            "item.started" => Ok(CodexThreadEvent::ItemStarted {
                item: Self::parse_item(value.get("item").cloned().unwrap_or(Value::Null)),
            }),
            "item.updated" => Ok(CodexThreadEvent::ItemUpdated {
                item: Self::parse_item(value.get("item").cloned().unwrap_or(Value::Null)),
            }),
            "item.completed" => Ok(CodexThreadEvent::ItemCompleted {
                item: Self::parse_item(value.get("item").cloned().unwrap_or(Value::Null)),
            }),
            "turn.completed" => {
                let usage = value.get("usage").cloned().unwrap_or(Value::Null);
                Ok(CodexThreadEvent::TurnCompleted {
                    input_tokens: usage
                        .get("input_tokens")
                        .and_then(Value::as_u64)
                        .unwrap_or(0),
                    cached_input_tokens: usage.get("cached_input_tokens").and_then(Value::as_u64),
                    output_tokens: usage
                        .get("output_tokens")
                        .and_then(Value::as_u64)
                        .unwrap_or(0),
                })
            }
            "turn.failed" => Ok(CodexThreadEvent::TurnFailed {
                message: value
                    .get("error")
                    .and_then(|error| error.get("message"))
                    .and_then(Value::as_str)
                    .or_else(|| value.get("message").and_then(Value::as_str))
                    .unwrap_or("Turn failed")
                    .to_owned(),
            }),
            "error" => Ok(CodexThreadEvent::Error {
                message: value
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Unknown error")
                    .to_owned(),
            }),
            _ => Err(AgentError::new(format!("unsupported codex event: {event_type}"))),
        }
    }

    fn parse_item(value: Value) -> CodexItem {
        let item_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned();

        match item_type.as_str() {
            "agent_message" => CodexItem::AgentMessage {
                text: value
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            },
            "reasoning" => CodexItem::Reasoning {
                text: value
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            },
            "command_execution" => CodexItem::CommandExecution {
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
                CodexItem::FileChange { changes }
            }
            _ => CodexItem::Other {
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

    fn start_session(&mut self, options: SessionOptions) -> Result<SessionInfo> {
        self.counter += 1;
        let id = format!("codex-{}", self.counter);
        let resolved = Self::resolved_options(options.clone());
        let info = SessionInfo {
            id: id.clone(),
            agent_type: AgentType::Codex,
            work_dir: options.work_dir.to_string_lossy().into_owned(),
            state: AgentState::Idle,
            created_at: self.counter as i64,
            last_active_at: self.counter as i64,
        };
        self.sessions.insert(
            id.clone(),
            ActiveSession {
                info: info.clone(),
                options: resolved,
                running_child: None,
            },
        );
        self.aliases.insert(id.clone(), id);
        Ok(info)
    }

    fn execute(
        &mut self,
        session_id: &str,
        input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        options: Option<SessionOptions>,
    ) -> Result<()> {
        let canonical = self
            .canonical_session_id(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;

        let (resolved_options, current_thread_id) = {
            let session = self
                .sessions
                .get_mut(&canonical)
                .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
            if let Some(options) = options {
                session.options = Self::merge_options(&session.options, Self::resolved_options(options));
                session.info.work_dir = session.options.work_dir.to_string_lossy().into_owned();
            }
            session.info.state = AgentState::Thinking;
            session.info.last_active_at += 1;
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
        if let Some(session) = self.sessions.get_mut(&canonical) {
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
            let event = Self::parse_thread_event(&line)?;
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

        if let Some(canonical) = self.canonical_session_id(&active_session_id)
            && let Some(session) = self.sessions.get_mut(&canonical)
        {
            session.running_child = None;
            session.info.state = if status.success() {
                AgentState::Idle
            } else {
                AgentState::Error
            };
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

    fn resume_session(&mut self, session_id: &str) -> Result<SessionInfo> {
        let canonical = self
            .canonical_session_id(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        self.sessions
            .get(&canonical)
            .map(|session| session.info.clone())
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))
    }

    fn cancel(&mut self, session_id: &str) -> Result<()> {
        let canonical = self
            .canonical_session_id(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        if let Some(session) = self.sessions.get_mut(&canonical) {
            if let Some(child) = session.running_child.take()
                && let Ok(mut child) = child.lock()
            {
                let _ = child.kill();
            }
            session.info.state = AgentState::Idle;
        }
        Ok(())
    }

    fn delete_session(&mut self, session_id: &str) -> Result<()> {
        let canonical = self
            .canonical_session_id(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        if let Some(session) = self.sessions.remove(&canonical)
            && let Some(child) = session.running_child
            && let Ok(mut child) = child.lock()
        {
            let _ = child.kill();
        }
        self.aliases.retain(|_, value| value != &canonical);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::CodexAdapter;

    #[test]
    fn parse_thread_event_accepts_turn_started_events_from_codex_cli() {
        let parsed = CodexAdapter::parse_thread_event(r#"{"type":"turn.started"}"#);

        assert!(parsed.is_ok(), "expected turn.started to parse, got {parsed:?}");
    }
}
