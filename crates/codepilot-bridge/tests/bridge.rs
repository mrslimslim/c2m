use std::{
    fs,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_bridge::{
    bridge::{AgentAdapter, Bridge, BridgeOptions, DiffServiceApi, SessionOptions},
    transport::types::TransportClient,
};
use codepilot_protocol::{
    events::AgentEvent,
    messages::{BridgeMessage, PhoneMessage},
    state::{
        AgentState, AgentType, DiffFile, DiffHunk, DiffLine, DiffLineKind, FileChangeKind,
        SessionInfo,
    },
};

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("{prefix}-{suffix}"))
}

#[derive(Default)]
struct RecordingClient {
    id: String,
    sent: Mutex<Vec<BridgeMessage>>,
}

impl RecordingClient {
    fn new(id: &str) -> Arc<Self> {
        Arc::new(Self {
            id: id.to_owned(),
            sent: Mutex::new(Vec::new()),
        })
    }

    fn messages(&self) -> Vec<BridgeMessage> {
        self.sent.lock().unwrap().clone()
    }

    fn clear(&self) {
        self.sent.lock().unwrap().clear();
    }
}

impl TransportClient for RecordingClient {
    fn id(&self) -> &str {
        &self.id
    }

    fn send(&self, message: BridgeMessage) {
        self.sent.lock().unwrap().push(message);
    }
}

#[derive(Default)]
struct FakeAdapter {
    start_calls: usize,
    execute_calls: usize,
    cancel_calls: Vec<String>,
}

impl AgentAdapter for FakeAdapter {
    fn name(&self) -> AgentType {
        AgentType::Codex
    }

    fn start_session(
        &mut self,
        options: SessionOptions,
    ) -> codepilot_agents::types::Result<SessionInfo> {
        self.start_calls += 1;
        Ok(SessionInfo {
            id: "session-1".to_owned(),
            agent_type: AgentType::Codex,
            work_dir: options.work_dir.to_string_lossy().into_owned(),
            state: AgentState::Idle,
            created_at: 1_000,
            last_active_at: 1_000,
        })
    }

    fn execute(
        &mut self,
        _session_id: &str,
        input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        _options: Option<SessionOptions>,
    ) -> codepilot_agents::types::Result<()> {
        self.execute_calls += 1;
        on_event(AgentEvent::Status {
            state: AgentState::Thinking,
            message: input.to_owned(),
        });
        Ok(())
    }

    fn resume_session(&mut self, session_id: &str) -> codepilot_agents::types::Result<SessionInfo> {
        Ok(SessionInfo {
            id: session_id.to_owned(),
            agent_type: AgentType::Codex,
            work_dir: "/tmp/project".to_owned(),
            state: AgentState::Idle,
            created_at: 1_000,
            last_active_at: 1_000,
        })
    }

    fn cancel(&mut self, session_id: &str) -> codepilot_agents::types::Result<()> {
        self.cancel_calls.push(session_id.to_owned());
        Ok(())
    }

    fn delete_session(&mut self, _session_id: &str) -> codepilot_agents::types::Result<()> {
        Ok(())
    }
}

#[derive(Default)]
struct FakeDiffService {
    requests: Mutex<Vec<String>>,
}

impl DiffServiceApi for FakeDiffService {
    fn load_diff(
        &self,
        session_id: &str,
        event_id: u64,
    ) -> codepilot_bridge::bridge::Result<(String, u64, Vec<DiffFile>)> {
        self.requests
            .lock()
            .unwrap()
            .push(format!("diff:{session_id}:{event_id}"));
        Ok((
            session_id.to_owned(),
            event_id,
            vec![DiffFile {
                path: "Sources/App.swift".to_owned(),
                kind: FileChangeKind::Update,
                added_lines: None,
                deleted_lines: None,
                is_truncated: false,
                truncation_reason: None,
                total_hunk_count: 1,
                loaded_hunks: Vec::new(),
                next_hunk_index: None,
            }],
        ))
    }

    fn load_more_hunks(
        &self,
        session_id: &str,
        event_id: u64,
        path: &str,
        after_hunk_index: u64,
    ) -> codepilot_bridge::bridge::Result<(String, u64, String, Vec<DiffHunk>, Option<u64>)> {
        self.requests.lock().unwrap().push(format!(
            "hunks:{session_id}:{event_id}:{path}:{after_hunk_index}"
        ));
        Ok((
            session_id.to_owned(),
            event_id,
            path.to_owned(),
            vec![DiffHunk {
                old_start: 3,
                old_line_count: 1,
                new_start: 3,
                new_line_count: 2,
                lines: vec![DiffLine {
                    kind: DiffLineKind::Add,
                    text: "+print(value)".to_owned(),
                }],
            }],
            None,
        ))
    }
}

fn make_bridge(work_dir: PathBuf) -> Bridge {
    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Box::new(FakeAdapter::default()));
    bridge.set_adapter_version(Some("0.116.0".to_owned()));
    bridge.set_diff_service(Box::new(FakeDiffService::default()));
    bridge
}

#[test]
fn bridge_routes_command_cancel_file_diff_and_slash_messages() {
    let work_dir = unique_temp_dir("codepilot-bridge");
    fs::create_dir_all(&work_dir).unwrap();
    fs::write(work_dir.join("README.md"), "# Hello\n").unwrap();

    let mut bridge = make_bridge(work_dir.clone());
    let client = RecordingClient::new("client-1");

    bridge.handle_client_connected(client.clone());
    let initial = client.messages();
    assert!(matches!(initial[0], BridgeMessage::SessionList { .. }));
    assert!(matches!(initial[1], BridgeMessage::SlashCatalog { .. }));
    client.clear();

    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::Command {
                text: "event-1".to_owned(),
                session_id: None,
                config: None,
            },
        )
        .unwrap();
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::Cancel {
                session_id: "session-1".to_owned(),
            },
        )
        .unwrap();
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::FileReq {
                path: "README.md".to_owned(),
                session_id: "session-1".to_owned(),
            },
        )
        .unwrap();
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::DiffReq {
                session_id: "session-1".to_owned(),
                event_id: 42,
            },
        )
        .unwrap();
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::DiffHunksReq {
                session_id: "session-1".to_owned(),
                event_id: 42,
                path: "Sources/App.swift".to_owned(),
                after_hunk_index: 1,
            },
        )
        .unwrap();
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::SlashAction {
                session_id: Some("session-1".to_owned()),
                command_id: "review".to_owned(),
                arguments: None,
            },
        )
        .unwrap();

    let messages = client.messages();
    assert!(
        messages
            .iter()
            .any(|message| matches!(message, BridgeMessage::Event { event_id: 1, .. }))
    );
    assert!(
        messages
            .iter()
            .any(|message| matches!(message, BridgeMessage::Event { event_id: 2, .. }))
    );
    assert!(messages.iter().any(|message| matches!(
        message,
        BridgeMessage::FileContent { path, language, .. }
            if path == "README.md" && language == "markdown"
    )));
    assert!(
        messages
            .iter()
            .any(|message| matches!(message, BridgeMessage::DiffContent { event_id: 42, .. }))
    );
    assert!(messages.iter().any(|message| matches!(
        message,
        BridgeMessage::DiffHunksContent { event_id: 42, .. }
    )));
    assert!(messages.iter().any(|message| matches!(
        message,
        BridgeMessage::SlashActionResult {
            command_id,
            ok,
            message: Some(message),
        } if command_id == "review" && !ok && message.contains("not implemented")
    )));
}

#[test]
fn bridge_replays_only_events_after_the_requested_cursor_for_sync_session() {
    let work_dir = unique_temp_dir("codepilot-bridge");
    fs::create_dir_all(&work_dir).unwrap();

    let mut bridge = make_bridge(work_dir);
    let original = RecordingClient::new("client-original");
    let reconnect = RecordingClient::new("client-reconnect");

    bridge
        .handle_message(
            original.clone(),
            PhoneMessage::Command {
                text: "event-1".to_owned(),
                session_id: None,
                config: None,
            },
        )
        .unwrap();
    bridge
        .handle_message(
            original.clone(),
            PhoneMessage::Command {
                text: "event-2".to_owned(),
                session_id: Some("session-1".to_owned()),
                config: None,
            },
        )
        .unwrap();
    bridge
        .handle_message(
            original.clone(),
            PhoneMessage::Command {
                text: "event-3".to_owned(),
                session_id: Some("session-1".to_owned()),
                config: None,
            },
        )
        .unwrap();

    bridge
        .handle_message(
            reconnect.clone(),
            PhoneMessage::SyncSession {
                session_id: "session-1".to_owned(),
                after_event_id: 1,
            },
        )
        .unwrap();

    let messages = reconnect.messages();
    let event_ids = messages
        .iter()
        .filter_map(|message| match message {
            BridgeMessage::Event { event_id, .. } => Some(*event_id),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(event_ids, vec![2, 3]);
    assert!(messages.iter().any(|message| matches!(
        message,
        BridgeMessage::SessionSyncComplete {
            session_id,
            latest_event_id,
            ..
        } if session_id == "session-1" && *latest_event_id == 3
    )));
}

#[test]
fn bridge_queues_live_events_for_replaying_clients_and_flushes_in_event_id_order() {
    let work_dir = unique_temp_dir("codepilot-bridge");
    fs::create_dir_all(&work_dir).unwrap();

    let mut bridge = make_bridge(work_dir);
    let original = RecordingClient::new("client-original");
    let replaying = RecordingClient::new("client-replay");

    bridge
        .handle_message(
            original.clone(),
            PhoneMessage::Command {
                text: "event-1".to_owned(),
                session_id: None,
                config: None,
            },
        )
        .unwrap();
    bridge
        .handle_message(
            original.clone(),
            PhoneMessage::Command {
                text: "event-2".to_owned(),
                session_id: Some("session-1".to_owned()),
                config: None,
            },
        )
        .unwrap();

    bridge.begin_replay(replaying.clone(), "session-1");
    bridge
        .handle_message(
            original.clone(),
            PhoneMessage::Command {
                text: "event-3".to_owned(),
                session_id: Some("session-1".to_owned()),
                config: None,
            },
        )
        .unwrap();

    assert!(replaying.messages().is_empty());

    let flushed = bridge
        .complete_replay(replaying.clone(), "session-1", 0)
        .unwrap();
    assert_eq!(
        flushed
            .iter()
            .map(|event| event.event_id)
            .collect::<Vec<_>>(),
        vec![1, 2, 3]
    );

    let replay_messages = replaying.messages();
    let replay_event_ids = replay_messages
        .iter()
        .filter_map(|message| match message {
            BridgeMessage::Event { event_id, .. } => Some(*event_id),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(replay_event_ids, vec![1, 2, 3]);
}
