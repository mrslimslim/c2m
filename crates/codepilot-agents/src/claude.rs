use std::{
    collections::{BTreeMap, HashMap, HashSet},
    io::{BufRead, BufReader, Read},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
};

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
    running_child: Option<Arc<Mutex<Child>>>,
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

    fn parse_stream_event(line: &str) -> Result<ClaudeStreamEvent> {
        let value: Value =
            serde_json::from_str(line).map_err(|error| AgentError::new(error.to_string()))?;
        let event_type = value
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| AgentError::new("claude event is missing a type"))?;

        match event_type {
            "assistant" => {
                let content = value
                    .get("message")
                    .and_then(|message| message.get("content"))
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .map(Self::parse_content_block)
                    .collect();
                Ok(ClaudeStreamEvent::Assistant { content })
            }
            "result" => Ok(ClaudeStreamEvent::Result {
                result: value
                    .get("result")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                session_id: value
                    .get("session_id")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            }),
            "tool_use" => Ok(ClaudeStreamEvent::ToolUse {
                name: value
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                input: parse_object_map(value.get("input").cloned().unwrap_or(Value::Null)),
            }),
            "tool_result" => Ok(ClaudeStreamEvent::ToolResult {
                content: value
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            }),
            _ => Err(AgentError::new(format!(
                "unsupported claude event: {event_type}"
            ))),
        }
    }

    fn parse_content_block(value: Value) -> ClaudeContentBlock {
        let block_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("text");

        match block_type {
            "thinking" => ClaudeContentBlock::Thinking(
                value
                    .get("thinking")
                    .or_else(|| value.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            ),
            "tool_use" => ClaudeContentBlock::ToolUse {
                name: value
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                input: parse_object_map(value.get("input").cloned().unwrap_or(Value::Null)),
            },
            "tool_result" => ClaudeContentBlock::ToolResult {
                content: value
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            },
            _ => ClaudeContentBlock::Text(
                value
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            ),
        }
    }
}

fn parse_object_map(value: Value) -> BTreeMap<String, Value> {
    value
        .as_object()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .collect()
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
                running_child: None,
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

        let mut args = vec![
            "-p".to_owned(),
            "--output-format".to_owned(),
            "stream-json".to_owned(),
            "--permission-mode".to_owned(),
            "acceptEdits".to_owned(),
        ];
        if let Some(last_session_id) = &session.last_session_id {
            args.push("-r".to_owned());
            args.push(last_session_id.clone());
        }
        args.push(input.to_owned());

        let mut command = Command::new("claude");
        command.args(args);
        command.current_dir(&session.info.work_dir);
        command.stdin(Stdio::null());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());

        let mut child = command.spawn().map_err(|error| {
            AgentError::new(format!(
                "Failed to spawn claude CLI: {error}. Install it with: npm install -g @anthropic-ai/claude-code"
            ))
        })?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AgentError::new("claude child process has no stdout"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| AgentError::new("claude child process has no stderr"))?;

        let child_ref = Arc::new(Mutex::new(child));
        session.running_child = Some(child_ref.clone());

        let stderr_reader = thread::spawn(move || {
            let mut stderr_output = String::new();
            let _ = BufReader::new(stderr).read_to_string(&mut stderr_output);
            stderr_output
        });

        let mut last_text = String::new();
        let mut changed_files = HashSet::new();
        for line in BufReader::new(stdout).lines() {
            let line = line.map_err(|error| AgentError::new(error.to_string()))?;
            if line.trim().is_empty() {
                continue;
            }

            let parsed = match Self::parse_stream_event(&line) {
                Ok(event) => event,
                Err(_) => continue,
            };
            let mapped = self.consume_events(session_id, vec![parsed])?;
            for event in mapped {
                match &event {
                    AgentEvent::AgentMessage { text } => last_text = text.clone(),
                    AgentEvent::CodeChange { changes } => {
                        for change in changes {
                            changed_files.insert(change.path.clone());
                        }
                    }
                    _ => {}
                }
                on_event(event);
            }
        }

        let status = child_ref
            .lock()
            .map_err(|_| AgentError::new("failed to lock claude child"))?
            .wait()
            .map_err(|error| AgentError::new(error.to_string()))?;
        let stderr_output = stderr_reader.join().unwrap_or_default();

        if let Some(session) = self.sessions.get_mut(session_id) {
            session.running_child = None;
            session.info.state = if status.success() {
                AgentState::Idle
            } else {
                AgentState::Error
            };
        }

        if !status.success() {
            return Err(AgentError::new(format!(
                "Claude CLI exited with code {}: {}",
                status.code().unwrap_or(-1),
                stderr_output.trim()
            )));
        }

        on_event(AgentEvent::TurnCompleted {
            summary: if last_text.is_empty() {
                "Turn completed".to_owned()
            } else {
                last_text.chars().take(200).collect()
            },
            files_changed: changed_files.into_iter().collect(),
            usage: None,
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
        if let Some(child) = session.running_child.take()
            && let Ok(mut child) = child.lock()
        {
            let _ = child.kill();
        }
        session.info.state = AgentState::Idle;
        Ok(())
    }

    fn delete_session(&mut self, session_id: &str) -> Result<()> {
        let session = self
            .sessions
            .remove(session_id)
            .ok_or_else(|| AgentError::new(format!("session not found: {session_id}")))?;
        if let Some(child) = session.running_child
            && let Ok(mut child) = child.lock()
        {
            let _ = child.kill();
        }
        Ok(())
    }
}
