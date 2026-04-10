use serde::{Deserialize, Serialize};

use crate::state::{AgentState, FileChange, TokenUsage};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CommandExecStatus {
    Running,
    Done,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentEvent {
    Status {
        state: AgentState,
        message: String,
    },
    Thinking {
        text: String,
    },
    CodeChange {
        changes: Vec<FileChange>,
    },
    CommandExec {
        command: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        output: Option<String>,
        #[serde(default, rename = "exitCode", skip_serializing_if = "Option::is_none")]
        exit_code: Option<i64>,
        status: CommandExecStatus,
    },
    AgentMessage {
        text: String,
    },
    Error {
        message: String,
    },
    TurnCompleted {
        summary: String,
        #[serde(rename = "filesChanged")]
        files_changed: Vec<String>,
        #[serde(default)]
        usage: Option<TokenUsage>,
    },
}
