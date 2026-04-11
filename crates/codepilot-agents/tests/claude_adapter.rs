use std::{collections::BTreeMap, path::PathBuf};

use codepilot_agents::{
    claude::{ClaudeAdapter, ClaudeContentBlock, ClaudeStreamEvent},
    types::{AgentAdapter, SessionOptions},
};
use codepilot_protocol::{
    events::AgentEvent,
    messages::{ApprovalPolicy, ModelReasoningEffort, SandboxMode},
};
use serde_json::json;

fn session_options() -> SessionOptions {
    SessionOptions {
        work_dir: PathBuf::from("/tmp/project"),
        model: None,
        model_reasoning_effort: Some(ModelReasoningEffort::Medium),
        approval_policy: Some(ApprovalPolicy::OnRequest),
        sandbox_mode: Some(SandboxMode::WorkspaceWrite),
    }
}

#[test]
fn claude_adapter_maps_assistant_blocks_and_result_payloads() {
    let adapter = ClaudeAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    let events = adapter
        .consume_events(
            &session.id,
            vec![
                ClaudeStreamEvent::Assistant {
                    content: vec![
                        ClaudeContentBlock::Thinking("reasoning".to_owned()),
                        ClaudeContentBlock::Text("hello from claude".to_owned()),
                    ],
                },
                ClaudeStreamEvent::Result {
                    result: "final answer".to_owned(),
                    session_id: Some("claude-session-123".to_owned()),
                },
            ],
        )
        .unwrap();

    assert!(matches!(
        &events[0],
        AgentEvent::Thinking { text } if text == "reasoning"
    ));
    assert!(matches!(
        &events[1],
        AgentEvent::AgentMessage { text } if text == "hello from claude"
    ));
    assert!(matches!(
        &events[2],
        AgentEvent::AgentMessage { text } if text == "final answer"
    ));
    assert_eq!(
        adapter.last_session_id(&session.id).as_deref(),
        Some("claude-session-123")
    );
}

#[test]
fn claude_adapter_maps_tool_use_and_tool_result_events_and_supports_cancellation() {
    let adapter = ClaudeAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    let mut bash_input = BTreeMap::new();
    bash_input.insert("command".to_owned(), json!("cargo test"));

    let mut write_input = BTreeMap::new();
    write_input.insert("file_path".to_owned(), json!("src/lib.rs"));

    let events = adapter
        .consume_events(
            &session.id,
            vec![
                ClaudeStreamEvent::ToolUse {
                    name: "Bash".to_owned(),
                    input: bash_input,
                },
                ClaudeStreamEvent::ToolUse {
                    name: "Write".to_owned(),
                    input: write_input,
                },
                ClaudeStreamEvent::ToolResult {
                    content: "tool finished".to_owned(),
                },
            ],
        )
        .unwrap();

    assert!(matches!(
        &events[0],
        AgentEvent::CommandExec { command, .. } if command == "cargo test"
    ));
    assert!(matches!(
        &events[1],
        AgentEvent::CodeChange { changes }
            if changes.len() == 1 && changes[0].path == "src/lib.rs"
    ));
    assert!(matches!(
        &events[2],
        AgentEvent::Status { message, .. } if message == "tool finished"
    ));

    adapter.cancel(&session.id).unwrap();
    adapter.delete_session(&session.id).unwrap();
    assert!(adapter.resume_session(&session.id).is_err());
}

#[test]
fn claude_adapter_normalizes_absolute_file_change_paths_within_the_work_dir() {
    let adapter = ClaudeAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    let mut write_input = BTreeMap::new();
    write_input.insert("file_path".to_owned(), json!("/tmp/project/src/lib.rs"));

    let events = adapter
        .consume_events(
            &session.id,
            vec![ClaudeStreamEvent::ToolUse {
                name: "Write".to_owned(),
                input: write_input,
            }],
        )
        .unwrap();

    assert!(matches!(
        &events[0],
        AgentEvent::CodeChange { changes }
            if changes.len() == 1 && changes[0].path == "src/lib.rs"
    ));
}

#[test]
fn claude_adapter_start_session_uses_epoch_millisecond_timestamps() {
    let adapter = ClaudeAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    assert!(
        session.created_at > 1_700_000_000_000_i64,
        "created_at should be a real epoch-millisecond timestamp, got {}",
        session.created_at
    );
    assert!(
        session.last_active_at >= session.created_at,
        "last_active_at should be initialized from the same wall clock, got created_at={} last_active_at={}",
        session.created_at,
        session.last_active_at
    );
}

#[test]
fn claude_adapter_generates_unique_temp_ids_with_timestamp_sequence() {
    let adapter = ClaudeAdapter::new();
    let first = adapter.start_session(session_options()).unwrap();
    let second = adapter.start_session(session_options()).unwrap();

    assert!(first.id.starts_with("claude-"));
    assert!(second.id.starts_with("claude-"));
    assert_ne!(first.id, second.id);

    let first_parts = first.id.split('-').collect::<Vec<_>>();
    let second_parts = second.id.split('-').collect::<Vec<_>>();
    assert_eq!(first_parts.len(), 3);
    assert_eq!(second_parts.len(), 3);

    let first_ts = first_parts[1].parse::<i64>().unwrap();
    let second_ts = second_parts[1].parse::<i64>().unwrap();
    assert!(second_ts >= first_ts);

    let first_seq = i64::from_str_radix(first_parts[2], 16).unwrap();
    let second_seq = i64::from_str_radix(second_parts[2], 16).unwrap();
    assert_eq!(second_seq, first_seq + 1);
}
