use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::{Arc, Condvar, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_agents::types::AgentError;
use codepilot_bridge::{
    bridge::{
        AgentAdapter, Bridge, BridgeOptions, DiffServiceApi, SessionOptions, handle_runtime_message,
    },
    transport::types::TransportClient,
};
use codepilot_protocol::{
    events::AgentEvent,
    messages::{BridgeMessage, PhoneMessage},
    state::{
        AgentState, AgentType, DiffFile, DiffHunk, DiffLine, DiffLineKind, FileChange,
        FileChangeKind, SessionInfo,
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
    start_calls: Mutex<usize>,
    execute_calls: Mutex<usize>,
    cancel_calls: Mutex<Vec<String>>,
}

impl AgentAdapter for FakeAdapter {
    fn name(&self) -> AgentType {
        AgentType::Codex
    }

    fn start_session(
        &self,
        options: SessionOptions,
    ) -> codepilot_agents::types::Result<SessionInfo> {
        *self.start_calls.lock().unwrap() += 1;
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
        &self,
        _session_id: &str,
        input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        _options: Option<SessionOptions>,
    ) -> codepilot_agents::types::Result<()> {
        *self.execute_calls.lock().unwrap() += 1;
        on_event(AgentEvent::Status {
            state: AgentState::Thinking,
            message: input.to_owned(),
        });
        Ok(())
    }

    fn resume_session(&self, session_id: &str) -> codepilot_agents::types::Result<SessionInfo> {
        Ok(SessionInfo {
            id: session_id.to_owned(),
            agent_type: AgentType::Codex,
            work_dir: "/tmp/project".to_owned(),
            state: AgentState::Idle,
            created_at: 1_000,
            last_active_at: 1_000,
        })
    }

    fn cancel(&self, session_id: &str) -> codepilot_agents::types::Result<()> {
        self.cancel_calls
            .lock()
            .unwrap()
            .push(session_id.to_owned());
        Ok(())
    }

    fn delete_session(&self, _session_id: &str) -> codepilot_agents::types::Result<()> {
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

struct FailingDiffService;

impl DiffServiceApi for FailingDiffService {
    fn load_diff(
        &self,
        _session_id: &str,
        _event_id: u64,
    ) -> codepilot_bridge::bridge::Result<(String, u64, Vec<DiffFile>)> {
        Err(std::io::Error::other("No event found for session session-1 and eventId 42").into())
    }

    fn load_more_hunks(
        &self,
        _session_id: &str,
        _event_id: u64,
        _path: &str,
        _after_hunk_index: u64,
    ) -> codepilot_bridge::bridge::Result<(String, u64, String, Vec<DiffHunk>, Option<u64>)> {
        Err(std::io::Error::other("No diff file found for path Sources/App.swift").into())
    }
}

fn make_bridge(work_dir: PathBuf) -> Bridge {
    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(FakeAdapter::default()));
    bridge.set_adapter_version(Some("0.116.0".to_owned()));
    bridge.set_diff_service(Box::new(FakeDiffService::default()));
    bridge
}

#[derive(Default)]
struct BlockingAdapterState {
    cancel_calls: Vec<String>,
    delete_calls: Vec<String>,
    execute_completed: bool,
    execute_started: bool,
    released: bool,
}

#[derive(Default)]
struct BlockingAdapter {
    state: Mutex<BlockingAdapterState>,
    state_changed: Condvar,
}

impl BlockingAdapter {
    fn wait_for_execute_start(&self, timeout_ms: u64) -> bool {
        self.wait_for(timeout_ms, |state| state.execute_started)
    }

    fn wait_for_cancel(&self, timeout_ms: u64) -> bool {
        self.wait_for(timeout_ms, |state| !state.cancel_calls.is_empty())
    }

    fn wait_for_delete(&self, timeout_ms: u64) -> bool {
        self.wait_for(timeout_ms, |state| !state.delete_calls.is_empty())
    }

    fn wait_for_execute_completion(&self, timeout_ms: u64) -> bool {
        self.wait_for(timeout_ms, |state| state.execute_completed)
    }

    fn release_execute(&self) {
        let mut state = self.state.lock().unwrap();
        state.released = true;
        self.state_changed.notify_all();
    }

    fn wait_for(&self, timeout_ms: u64, predicate: impl Fn(&BlockingAdapterState) -> bool) -> bool {
        let state = self.state.lock().unwrap();
        let timeout = std::time::Duration::from_millis(timeout_ms);
        let (state, _) = self
            .state_changed
            .wait_timeout_while(state, timeout, |state| !predicate(state))
            .unwrap();
        predicate(&state)
    }
}

impl AgentAdapter for BlockingAdapter {
    fn name(&self) -> AgentType {
        AgentType::Codex
    }

    fn start_session(
        &self,
        options: SessionOptions,
    ) -> codepilot_agents::types::Result<SessionInfo> {
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
        &self,
        _session_id: &str,
        _input: &str,
        _on_event: &mut dyn FnMut(AgentEvent),
        _options: Option<SessionOptions>,
    ) -> codepilot_agents::types::Result<()> {
        let mut state = self.state.lock().unwrap();
        state.execute_started = true;
        self.state_changed.notify_all();

        let timeout = std::time::Duration::from_secs(2);
        let (mut state, wait_result) = self
            .state_changed
            .wait_timeout_while(state, timeout, |state| !state.released)
            .unwrap();
        if !state.released && wait_result.timed_out() {
            state.execute_completed = true;
            self.state_changed.notify_all();
            return Err(AgentError::new("timed out waiting for cancellation"));
        }

        state.execute_completed = true;
        self.state_changed.notify_all();
        Ok(())
    }

    fn resume_session(&self, session_id: &str) -> codepilot_agents::types::Result<SessionInfo> {
        Ok(SessionInfo {
            id: session_id.to_owned(),
            agent_type: AgentType::Codex,
            work_dir: "/tmp/project".to_owned(),
            state: AgentState::Idle,
            created_at: 1_000,
            last_active_at: 1_000,
        })
    }

    fn cancel(&self, session_id: &str) -> codepilot_agents::types::Result<()> {
        let mut state = self.state.lock().unwrap();
        state.cancel_calls.push(session_id.to_owned());
        state.released = true;
        self.state_changed.notify_all();
        Ok(())
    }

    fn delete_session(&self, session_id: &str) -> codepilot_agents::types::Result<()> {
        let mut state = self.state.lock().unwrap();
        state.delete_calls.push(session_id.to_owned());
        state.released = true;
        self.state_changed.notify_all();
        Ok(())
    }
}

struct CodeChangeAdapter {
    changes: Vec<FileChange>,
}

impl AgentAdapter for CodeChangeAdapter {
    fn name(&self) -> AgentType {
        AgentType::Codex
    }

    fn start_session(
        &self,
        options: SessionOptions,
    ) -> codepilot_agents::types::Result<SessionInfo> {
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
        &self,
        _session_id: &str,
        _input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        _options: Option<SessionOptions>,
    ) -> codepilot_agents::types::Result<()> {
        on_event(AgentEvent::CodeChange {
            changes: self.changes.clone(),
        });
        Ok(())
    }

    fn resume_session(&self, session_id: &str) -> codepilot_agents::types::Result<SessionInfo> {
        Ok(SessionInfo {
            id: session_id.to_owned(),
            agent_type: AgentType::Codex,
            work_dir: "/tmp/project".to_owned(),
            state: AgentState::Idle,
            created_at: 1_000,
            last_active_at: 1_000,
        })
    }

    fn cancel(&self, _session_id: &str) -> codepilot_agents::types::Result<()> {
        Ok(())
    }

    fn delete_session(&self, _session_id: &str) -> codepilot_agents::types::Result<()> {
        Ok(())
    }
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
fn bridge_returns_project_scoped_file_search_results() {
    let work_dir = unique_temp_dir("codepilot-bridge-file-search");
    let work_dir_string = work_dir.to_string_lossy().into_owned();
    fs::create_dir_all(work_dir.join("docs")).unwrap();
    fs::create_dir_all(work_dir.join("src/nested")).unwrap();
    fs::create_dir_all(work_dir.join(".git")).unwrap();
    fs::write(work_dir.join("docs/turnview-guide.md"), "# Turnview\n").unwrap();
    fs::write(
        work_dir.join("src/nested/turnview-panel.rs"),
        "pub fn render() {}\n",
    )
    .unwrap();
    fs::write(work_dir.join("src/other.rs"), "pub fn other() {}\n").unwrap();
    fs::write(work_dir.join(".git/turnview-hidden.txt"), "ignore me\n").unwrap();

    let mut bridge = make_bridge(work_dir.clone());
    let client = RecordingClient::new("client-1");

    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::FileSearchReq {
                session_id: "session-1".to_owned(),
                query: "turnview".to_owned(),
                limit: 12,
            },
        )
        .unwrap();

    assert!(client.messages().iter().any(|message| matches!(
        message,
        BridgeMessage::FileSearchResults {
            session_id,
            query,
            results,
        } if session_id == "session-1"
            && query == "turnview"
            && results.iter().map(|result| result.path.as_str()).eq([
                "docs/turnview-guide.md",
                "src/nested/turnview-panel.rs",
            ])
            && results
                .iter()
                .all(|result| !result.path.starts_with(&work_dir_string))
    )));
}

#[test]
fn bridge_routes_diff_failures_as_contextual_diff_errors() {
    let work_dir = unique_temp_dir("codepilot-bridge-diff-error");
    fs::create_dir_all(&work_dir).unwrap();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(FakeAdapter::default()));
    bridge.set_diff_service(Box::new(FailingDiffService));

    let client = RecordingClient::new("client-1");

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

    let messages = client.messages();
    assert!(messages.iter().any(|message| matches!(
        message,
        BridgeMessage::DiffError {
            session_id,
            event_id,
            path: None,
            message,
        } if session_id == "session-1" && *event_id == 42 && message.contains("No event found")
    )));
    assert!(messages.iter().any(|message| matches!(
        message,
        BridgeMessage::DiffError {
            session_id,
            event_id,
            path: Some(path),
            message,
        } if session_id == "session-1"
            && *event_id == 42
            && path == "Sources/App.swift"
            && message.contains("No diff file found")
    )));
}

#[test]
fn bridge_routes_file_failures_as_contextual_file_errors() {
    let work_dir = unique_temp_dir("codepilot-bridge-file-error");
    fs::create_dir_all(&work_dir).unwrap();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(FakeAdapter::default()));

    let client = RecordingClient::new("client-1");

    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::FileReq {
                path: "README.md".to_owned(),
                session_id: "session-1".to_owned(),
            },
        )
        .unwrap();

    let messages = client.messages();
    assert!(messages.iter().any(|message| matches!(
        message,
        BridgeMessage::FileError {
            session_id,
            path,
            message,
        } if session_id == "session-1"
            && path == "README.md"
            && message.contains("No such file")
    )));
}

#[test]
fn bridge_allows_absolute_file_requests_that_point_inside_the_work_dir() {
    let work_dir = unique_temp_dir("codepilot-bridge-absolute-file");
    fs::create_dir_all(work_dir.join("src")).unwrap();
    let file_path = work_dir.join("src/lib.rs");
    fs::write(&file_path, "pub fn run() {}\n").unwrap();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(FakeAdapter::default()));

    let client = RecordingClient::new("client-1");
    let absolute = file_path.to_string_lossy().into_owned();

    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::FileReq {
                path: absolute.clone(),
                session_id: "session-1".to_owned(),
            },
        )
        .unwrap();

    assert!(client.messages().iter().any(|message| matches!(
        message,
        BridgeMessage::FileContent { path, content, .. }
            if path == &absolute && content.contains("pub fn run")
    )));
}

#[test]
fn bridge_uses_default_diff_service_for_real_diff_requests() {
    let work_dir = unique_temp_dir("codepilot-bridge-real-diff");
    fs::create_dir_all(&work_dir).unwrap();
    fs::write(work_dir.join("README.md"), "# Hello\n").unwrap();

    run_git(&work_dir, &["init"]);
    run_git(&work_dir, &["config", "user.email", "tests@example.com"]);
    run_git(&work_dir, &["config", "user.name", "CodePilot Tests"]);
    run_git(&work_dir, &["add", "README.md"]);
    run_git(&work_dir, &["commit", "-m", "initial"]);
    fs::write(work_dir.join("README.md"), "# Hello\n\nUpdated line\n").unwrap();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(CodeChangeAdapter {
        changes: vec![FileChange {
            path: "README.md".to_owned(),
            kind: FileChangeKind::Update,
        }],
    }));

    let client = RecordingClient::new("client-1");

    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::Command {
                text: "make a change".to_owned(),
                session_id: None,
                config: None,
            },
        )
        .unwrap();
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::DiffReq {
                session_id: "session-1".to_owned(),
                event_id: 1,
            },
        )
        .unwrap();

    let messages = client.messages();
    assert!(messages.iter().any(|message| matches!(
        message,
        BridgeMessage::DiffContent {
            session_id,
            event_id,
            files,
        } if session_id == "session-1"
            && *event_id == 1
            && files.iter().any(|file| file.path == "README.md" && !file.loaded_hunks.is_empty())
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
fn bridge_session_list_keeps_busy_state_while_the_turn_is_still_streaming() {
    let work_dir = unique_temp_dir("codepilot-bridge-streaming-state");
    fs::create_dir_all(&work_dir).unwrap();

    let mut bridge = make_bridge(work_dir);
    let client = RecordingClient::new("client-1");

    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::Command {
                text: "kick off".to_owned(),
                session_id: None,
                config: None,
            },
        )
        .unwrap();

    bridge
        .persist_and_dispatch_event(
            "session-1",
            AgentEvent::CommandExec {
                command: "swift test".to_owned(),
                output: Some("ok".to_owned()),
                exit_code: Some(0),
                status: codepilot_protocol::events::CommandExecStatus::Done,
            },
        )
        .unwrap();
    bridge
        .persist_and_dispatch_event(
            "session-1",
            AgentEvent::AgentMessage {
                text: "Continuing with the answer".to_owned(),
            },
        )
        .unwrap();

    client.clear();
    bridge
        .handle_message(client.clone(), PhoneMessage::ListSessions {})
        .unwrap();

    assert!(client.messages().iter().any(|message| matches!(
        message,
        BridgeMessage::SessionList { sessions }
            if sessions
                .iter()
                .any(|session| session.id == "session-1" && session.state == AgentState::Thinking)
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

#[test]
fn runtime_command_execution_allows_cancel_while_the_session_is_running() {
    let work_dir = unique_temp_dir("codepilot-bridge-runtime-cancel");
    fs::create_dir_all(&work_dir).unwrap();

    let adapter = Arc::new(BlockingAdapter::default());
    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(adapter.clone());
    let bridge = Arc::new(Mutex::new(bridge));
    let client = RecordingClient::new("client-1");

    handle_runtime_message(
        bridge.clone(),
        client.clone(),
        PhoneMessage::Command {
            text: "sleep forever".to_owned(),
            session_id: None,
            config: None,
        },
    );

    assert!(adapter.wait_for_execute_start(500));

    let bridge_for_cancel = bridge.clone();
    let client_for_cancel = client.clone();
    let cancel_thread = std::thread::spawn(move || {
        handle_runtime_message(
            bridge_for_cancel,
            client_for_cancel,
            PhoneMessage::Cancel {
                session_id: "session-1".to_owned(),
            },
        );
    });

    let cancel_reached_adapter = adapter.wait_for_cancel(500);
    if !cancel_reached_adapter {
        adapter.release_execute();
    }

    cancel_thread.join().unwrap();
    assert!(adapter.wait_for_execute_completion(500));
    assert!(
        cancel_reached_adapter,
        "cancel should reach the adapter before the command finishes"
    );
}

#[test]
fn runtime_command_execution_allows_delete_while_the_session_is_running() {
    let work_dir = unique_temp_dir("codepilot-bridge-runtime-delete");
    fs::create_dir_all(&work_dir).unwrap();

    let adapter = Arc::new(BlockingAdapter::default());
    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(adapter.clone());
    let bridge = Arc::new(Mutex::new(bridge));
    let client = RecordingClient::new("client-1");

    handle_runtime_message(
        bridge.clone(),
        client.clone(),
        PhoneMessage::Command {
            text: "sleep forever".to_owned(),
            session_id: None,
            config: None,
        },
    );

    assert!(adapter.wait_for_execute_start(500));

    let bridge_for_delete = bridge.clone();
    let client_for_delete = client.clone();
    let delete_thread = std::thread::spawn(move || {
        handle_runtime_message(
            bridge_for_delete,
            client_for_delete,
            PhoneMessage::DeleteSession {
                session_id: "session-1".to_owned(),
            },
        );
    });

    let delete_reached_adapter = adapter.wait_for_delete(500);
    if !delete_reached_adapter {
        adapter.release_execute();
    }

    delete_thread.join().unwrap();
    assert!(adapter.wait_for_execute_completion(500));
    assert!(
        delete_reached_adapter,
        "delete_session should reach the adapter before the command finishes"
    );
}

fn run_git(work_dir: &PathBuf, args: &[&str]) {
    let output = Command::new("git")
        .args(args)
        .current_dir(work_dir)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
}
