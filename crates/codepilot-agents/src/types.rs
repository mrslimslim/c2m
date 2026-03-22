use std::{
    fmt::{Display, Formatter},
    path::PathBuf,
};

use codepilot_protocol::{
    events::AgentEvent,
    messages::{ApprovalPolicy, ModelReasoningEffort, SandboxMode},
    state::{AgentType, SessionInfo},
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionOptions {
    pub work_dir: PathBuf,
    pub model: Option<String>,
    pub model_reasoning_effort: Option<ModelReasoningEffort>,
    pub approval_policy: Option<ApprovalPolicy>,
    pub sandbox_mode: Option<SandboxMode>,
}

#[derive(Debug, Clone)]
pub struct AgentError(String);

impl AgentError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl Display for AgentError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for AgentError {}

pub type Result<T> = std::result::Result<T, AgentError>;

pub trait AgentAdapter: Send {
    fn name(&self) -> AgentType;
    fn start_session(&mut self, options: SessionOptions) -> Result<SessionInfo>;
    fn execute(
        &mut self,
        session_id: &str,
        input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        options: Option<SessionOptions>,
    ) -> Result<()>;
    fn resume_session(&mut self, session_id: &str) -> Result<SessionInfo>;
    fn cancel(&mut self, session_id: &str) -> Result<()>;
    fn delete_session(&mut self, session_id: &str) -> Result<()>;
}
