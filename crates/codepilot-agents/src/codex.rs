use std::collections::HashMap;

use codepilot_protocol::{
    events::{AgentEvent, CommandExecStatus},
    state::{AgentState, AgentType, FileChange, FileChangeKind, SessionInfo, TokenUsage},
};

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

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActiveSession {
    info: SessionInfo,
    options: SessionOptions,
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
        _options: Option<SessionOptions>,
    ) -> Result<()> {
        let event = AgentEvent::Status {
            state: AgentState::Thinking,
            message: input.to_owned(),
        };
        on_event(event);
        let canonical = self
            .canonical_session_id(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        if let Some(session) = self.sessions.get_mut(&canonical) {
            session.info.state = AgentState::Thinking;
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
            session.info.state = AgentState::Idle;
        }
        Ok(())
    }

    fn delete_session(&mut self, session_id: &str) -> Result<()> {
        let canonical = self
            .canonical_session_id(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        self.sessions.remove(&canonical);
        self.aliases.retain(|_, value| value != &canonical);
        Ok(())
    }
}
