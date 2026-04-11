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
    let adapter = CodexAdapter::new();
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
                        id: "item-1".to_owned(),
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
    let adapter = CodexAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    let events = adapter
        .consume_events(
            &session.id,
            vec![
                CodexThreadEvent::ItemUpdated {
                    item: CodexItem::Reasoning {
                        id: "item-thinking".to_owned(),
                        text: "thinking hard".to_owned(),
                    },
                },
                CodexThreadEvent::ItemUpdated {
                    item: CodexItem::CommandExecution {
                        id: "item-command".to_owned(),
                        command: "cargo test".to_owned(),
                        output: Some("ok".to_owned()),
                        exit_code: Some(0),
                        status: CodexCommandStatus::Done,
                    },
                },
                CodexThreadEvent::ItemCompleted {
                    item: CodexItem::FileChange {
                        id: "item-files".to_owned(),
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

#[test]
fn codex_adapter_normalizes_absolute_file_change_paths_within_the_work_dir() {
    let adapter = CodexAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    let events = adapter
        .consume_events(
            &session.id,
            vec![CodexThreadEvent::ItemCompleted {
                item: CodexItem::FileChange {
                    id: "item-files".to_owned(),
                    changes: vec![("/tmp/project/src/main.rs".to_owned(), "update".to_owned())],
                },
            }],
        )
        .unwrap();

    assert!(matches!(
        &events[0],
        AgentEvent::CodeChange { changes }
            if changes.len() == 1 && changes[0].path == "src/main.rs"
    ));
}

#[test]
fn codex_adapter_start_session_uses_epoch_millisecond_timestamps() {
    let adapter = CodexAdapter::new();
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
fn codex_adapter_generates_unique_temp_ids_with_timestamp_sequence() {
    let adapter = CodexAdapter::new();
    let first = adapter.start_session(session_options()).unwrap();
    let second = adapter.start_session(session_options()).unwrap();
    assert!(first.id.starts_with("codex-"));
    assert!(second.id.starts_with("codex-"));
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

#[test]
fn codex_adapter_emits_only_incremental_text_for_streaming_items() {
    let adapter = CodexAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    let events = adapter
        .consume_events(
            &session.id,
            vec![
                CodexThreadEvent::ItemUpdated {
                    item: CodexItem::AgentMessage {
                        id: "item-agent".to_owned(),
                        text: "Hel".to_owned(),
                    },
                },
                CodexThreadEvent::ItemUpdated {
                    item: CodexItem::AgentMessage {
                        id: "item-agent".to_owned(),
                        text: "Hello".to_owned(),
                    },
                },
                CodexThreadEvent::ItemCompleted {
                    item: CodexItem::AgentMessage {
                        id: "item-agent".to_owned(),
                        text: "Hello world".to_owned(),
                    },
                },
                CodexThreadEvent::ItemUpdated {
                    item: CodexItem::Reasoning {
                        id: "item-thinking".to_owned(),
                        text: "Think".to_owned(),
                    },
                },
                CodexThreadEvent::ItemCompleted {
                    item: CodexItem::Reasoning {
                        id: "item-thinking".to_owned(),
                        text: "Thinking".to_owned(),
                    },
                },
            ],
        )
        .unwrap();

    assert_eq!(
        events,
        vec![
            AgentEvent::AgentMessage {
                text: "Hel".to_owned(),
            },
            AgentEvent::AgentMessage {
                text: "lo".to_owned(),
            },
            AgentEvent::AgentMessage {
                text: " world".to_owned(),
            },
            AgentEvent::Thinking {
                text: "Think".to_owned(),
            },
            AgentEvent::Thinking {
                text: "ing".to_owned(),
            },
        ]
    );
}

#[test]
fn codex_adapter_ignores_codex_unstable_feature_warning_items() {
    let adapter = CodexAdapter::new();
    let session = adapter.start_session(session_options()).unwrap();

    let events = adapter
        .consume_events(
            &session.id,
            vec![CodexThreadEvent::ItemCompleted {
                item: CodexItem::Other {
                    id: "item-warning".to_owned(),
                    item_type: "error".to_owned(),
                    payload: serde_json::json!({
                        "id": "item-warning",
                        "type": "error",
                        "message": "Under-development features enabled: codex_hooks. Under-development features are incomplete and may behave unpredictably. To suppress this warning, set `suppress_unstable_features_warning = true` in /path/to/.codex/config.toml."
                    }),
                },
            }],
        )
        .unwrap();

    assert!(
        events.is_empty(),
        "expected known warning item to be ignored"
    );
}
