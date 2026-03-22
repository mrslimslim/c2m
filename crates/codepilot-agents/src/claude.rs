use std::collections::{BTreeMap, HashMap};

use codepilot_protocol::{
    events::{AgentEvent, CommandExecStatus},
    state::{AgentState, AgentType, FileChange, FileChangeKind, SessionInfo},
};
use serde_json::Value;

use crate::types::{AgentAdapter, AgentError, Result, SessionOptions};

#[derive(Debug, Clone, PartialEq)]
pub enum ClaudeContentBlock {
    Text(String),
    Thinking(String),
    ToolUse {
        name: String,
        input: BTreeMap<String, Value>,
    },
    ToolResult {
        content: String,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ClaudeStreamEvent {
    Assistant {
        content: Vec<ClaudeContentBlock>,
    },
    Result {
        result: String,
        session_id: Option<String>,
    },
    ToolUse {
        name: String,
        input: BTreeMap<String, Value>,
    },
    ToolResult {
        content: String,
    },
}

#[derive(Debug, Clone)]
struct ActiveSession {
    info: SessionInfo,
    last_session_id: Option<String>,
    cancelled: bool,
}

pub struct ClaudeAdapter {
    sessions: HashMap<String, ActiveSession>,
    counter: u64,
}

impl ClaudeAdapter {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            counter: 0,
        }
    }

    pub fn last_session_id(&self, session_id: &str) -> Option<String> {
        self.sessions
            .get(session_id)
            .and_then(|session| session.last_session_id.clone())
    }

    pub fn consume_events(
        &mut self,
        session_id: &str,
        events: Vec<ClaudeStreamEvent>,
    ) -> Result<Vec<AgentEvent>> {
        let session = self
            .sessions
            .get_mut(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;

        let mut mapped = Vec::new();
        for event in events {
            match event {
                ClaudeStreamEvent::Assistant { content } => {
                    for block in content {
                        mapped.extend(Self::map_content_block(session, block));
                    }
                }
                ClaudeStreamEvent::Result { result, session_id } => {
                    if let Some(session_id) = session_id {
                        session.last_session_id = Some(session_id);
                    }
                    mapped.push(AgentEvent::AgentMessage { text: result });
                }
                ClaudeStreamEvent::ToolUse { name, input } => {
                    mapped.extend(Self::map_content_block(
                        session,
                        ClaudeContentBlock::ToolUse { name, input },
                    ));
                }
                ClaudeStreamEvent::ToolResult { content } => {
                    mapped.extend(Self::map_content_block(
                        session,
                        ClaudeContentBlock::ToolResult { content },
                    ));
                }
            }
        }

        Ok(mapped)
    }

    fn map_content_block(
        session: &mut ActiveSession,
        block: ClaudeContentBlock,
    ) -> Vec<AgentEvent> {
        match block {
            ClaudeContentBlock::Text(text) => vec![AgentEvent::AgentMessage { text }],
            ClaudeContentBlock::Thinking(text) => {
                session.info.state = AgentState::Thinking;
                vec![AgentEvent::Thinking { text }]
            }
            ClaudeContentBlock::ToolUse { name, input } => {
                if name.eq_ignore_ascii_case("bash") {
                    session.info.state = AgentState::RunningCommand;
                    vec![AgentEvent::CommandExec {
                        command: input
                            .get("command")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        output: None,
                        exit_code: None,
                        status: CommandExecStatus::Running,
                    }]
                } else if name.eq_ignore_ascii_case("write") || name.eq_ignore_ascii_case("edit") {
                    session.info.state = AgentState::Coding;
                    let path = input
                        .get("file_path")
                        .or_else(|| input.get("path"))
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    vec![AgentEvent::CodeChange {
                        changes: vec![FileChange {
                            path,
                            kind: if name.eq_ignore_ascii_case("write") {
                                FileChangeKind::Add
                            } else {
                                FileChangeKind::Update
                            },
                        }],
                    }]
                } else {
                    vec![AgentEvent::Status {
                        state: session.info.state,
                        message: format!("Tool: {name}"),
                    }]
                }
            }
            ClaudeContentBlock::ToolResult { content } => vec![AgentEvent::Status {
                state: session.info.state,
                message: content,
            }],
        }
    }
}

impl Default for ClaudeAdapter {
    fn default() -> Self {
        Self::new()
    }
}

impl AgentAdapter for ClaudeAdapter {
    fn name(&self) -> AgentType {
        AgentType::Claude
    }

    fn start_session(&mut self, options: SessionOptions) -> Result<SessionInfo> {
        self.counter += 1;
        let id = format!("claude-{}", self.counter);
        let info = SessionInfo {
            id: id.clone(),
            agent_type: AgentType::Claude,
            work_dir: options.work_dir.to_string_lossy().into_owned(),
            state: AgentState::Idle,
            created_at: self.counter as i64,
            last_active_at: self.counter as i64,
        };
        self.sessions.insert(
            id.clone(),
            ActiveSession {
                info: info.clone(),
                last_session_id: None,
                cancelled: false,
            },
        );
        Ok(info)
    }

    fn execute(
        &mut self,
        session_id: &str,
        input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        _options: Option<SessionOptions>,
    ) -> Result<()> {
        let session = self
            .sessions
            .get_mut(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        session.info.state = AgentState::Thinking;
        on_event(AgentEvent::Status {
            state: AgentState::Thinking,
            message: input.to_owned(),
        });
        Ok(())
    }

    fn resume_session(&mut self, session_id: &str) -> Result<SessionInfo> {
        self.sessions
            .get(session_id)
            .map(|session| session.info.clone())
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))
    }

    fn cancel(&mut self, session_id: &str) -> Result<()> {
        let session = self
            .sessions
            .get_mut(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        session.cancelled = true;
        session.info.state = AgentState::Idle;
        Ok(())
    }

    fn delete_session(&mut self, session_id: &str) -> Result<()> {
        self.sessions
            .remove(session_id)
            .map(|_| ())
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))
    }
}
