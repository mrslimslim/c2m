use std::path::PathBuf;

use codepilot_agents::{
    codex::{CodexAdapter, CodexCommandStatus, CodexItem, CodexThreadEvent},
    types::{AgentAdapter, SessionOptions},
};
use codepilot_protocol::{
    events::AgentEvent,
    messages::{ApprovalPolicy, ModelReasoningEffort, SandboxMode},
};

fn session_options() -> SessionOptions {
    SessionOptions {
        work_dir: PathBuf::from("/tmp/project"),
        model: Some("gpt-5.4".to_owned()),
        model_reasoning_effort: Some(ModelReasoningEffort::Medium),
        approval_policy: Some(ApprovalPolicy::OnRequest),
        sandbox_mode: Some(SandboxMode::WorkspaceWrite),
    }
}

#[test]
fn codex_adapter_rebinds_temp_thread_ids_to_the_canonical_thread_id() {
    let mut adapter = CodexAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();
    let temp_id = session.id.clone();

    let events = adapter
        .consume_events(
            &temp_id,
            vec![
                CodexThreadEvent::ThreadStarted {
                    thread_id: "thread-real".to_owned(),
                },
                CodexThreadEvent::ItemCompleted {
                    item: CodexItem::AgentMessage {
                        text: "hello".to_owned(),
                    },
                },
            ],
        )
        .unwrap();

    assert_eq!(
        adapter.canonical_session_id(&temp_id).as_deref(),
        Some("thread-real")
    );
    assert_eq!(
        events,
        vec![AgentEvent::AgentMessage {
            text: "hello".to_owned(),
        }]
    );
}

#[test]
fn codex_adapter_maps_reasoning_command_execution_file_changes_and_turn_completion() {
    let mut adapter = CodexAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    let events = adapter
        .consume_events(
            &session.id,
            vec![
                CodexThreadEvent::ItemUpdated {
                    item: CodexItem::Reasoning {
                        text: "thinking hard".to_owned(),
                    },
                },
                CodexThreadEvent::ItemUpdated {
                    item: CodexItem::CommandExecution {
                        command: "cargo test".to_owned(),
                        output: Some("ok".to_owned()),
                        exit_code: Some(0),
                        status: CodexCommandStatus::Done,
                    },
                },
                CodexThreadEvent::ItemCompleted {
                    item: CodexItem::FileChange {
                        changes: vec![("src/main.rs".to_owned(), "update".to_owned())],
                    },
                },
                CodexThreadEvent::TurnCompleted {
                    input_tokens: 12,
                    cached_input_tokens: Some(2),
                    output_tokens: 9,
                },
            ],
        )
        .unwrap();

    assert!(matches!(
        &events[0],
        AgentEvent::Thinking { text } if text == "thinking hard"
    ));
    assert!(matches!(
        &events[1],
        AgentEvent::CommandExec {
            command,
            output,
            exit_code,
            ..
        } if command == "cargo test" && output.as_deref() == Some("ok") && *exit_code == Some(0)
    ));
    assert!(matches!(
        &events[2],
        AgentEvent::CodeChange { changes }
            if changes.len() == 1 && changes[0].path == "src/main.rs"
    ));
    assert!(matches!(
        &events[3],
        AgentEvent::TurnCompleted { usage: Some(usage), .. }
            if usage.input_tokens == 12 && usage.cached_input_tokens == Some(2) && usage.output_tokens == 9
    ));
}
