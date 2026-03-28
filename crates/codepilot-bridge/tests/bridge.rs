use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use codepilot_bridge::{
    bridge::{
        AgentAdapter, Bridge, BridgeOptions, DiffServiceApi, SessionOptions,
        handle_runtime_message,
    },
    transport::types::TransportClient,
};
use codepilot_core::session_store::event_log::{
    SessionEventLogStore, SessionEventLogStoreOptions,
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

fn run_git(work_dir: &PathBuf, args: &[&str]) {
    let status = Command::new("git")
        .args(args)
        .current_dir(work_dir)
        .status()
        .unwrap();
    assert!(status.success(), "git {:?} failed", args);
}

fn init_git_repo(work_dir: &PathBuf) {
    run_git(work_dir, &["init"]);
    run_git(work_dir, &["config", "user.email", "codepilot@example.com"]);
    run_git(work_dir, &["config", "user.name", "CodePilot"]);
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
    start_calls: AtomicUsize,
    execute_calls: AtomicUsize,
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
        self.start_calls.fetch_add(1, Ordering::Relaxed);
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
        self.execute_calls.fetch_add(1, Ordering::Relaxed);
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
        self.cancel_calls.lock().unwrap().push(session_id.to_owned());
        Ok(())
    }

    fn delete_session(&self, _session_id: &str) -> codepilot_agents::types::Result<()> {
        Ok(())
    }
}

#[derive(Default)]
struct RemappingAdapter {
    canonical_session_id: Mutex<Option<String>>,
    execute_calls: Mutex<Vec<String>>,
}

impl AgentAdapter for RemappingAdapter {
    fn name(&self) -> AgentType {
        AgentType::Codex
    }

    fn start_session(
        &self,
        options: SessionOptions,
    ) -> codepilot_agents::types::Result<SessionInfo> {
        Ok(SessionInfo {
            id: "codex-1".to_owned(),
            agent_type: AgentType::Codex,
            work_dir: options.work_dir.to_string_lossy().into_owned(),
            state: AgentState::Idle,
            created_at: 1_000,
            last_active_at: 1_000,
        })
    }

    fn execute(
        &self,
        session_id: &str,
        input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        _options: Option<SessionOptions>,
    ) -> codepilot_agents::types::Result<()> {
        self.execute_calls.lock().unwrap().push(session_id.to_owned());
        let mut canonical = self.canonical_session_id.lock().unwrap();
        if canonical.is_none() {
            *canonical = Some("real-session-1".to_owned());
        }
        on_event(AgentEvent::AgentMessage {
            text: input.to_owned(),
        });
        Ok(())
    }

    fn resume_session(&self, session_id: &str) -> codepilot_agents::types::Result<SessionInfo> {
        Ok(SessionInfo {
            id: self
                .canonical_session_id
                .lock()
                .unwrap()
                .clone()
                .unwrap_or_else(|| session_id.to_owned()),
            agent_type: AgentType::Codex,
            work_dir: "/tmp/project".to_owned(),
            state: AgentState::Idle,
            created_at: 1_000,
            last_active_at: 1_001,
        })
    }

    fn cancel(&self, _session_id: &str) -> codepilot_agents::types::Result<()> {
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

struct StrictSessionAdapter {
    next_session_id: String,
    started_sessions: Mutex<Vec<String>>,
    executed_sessions: Mutex<Vec<String>>,
}

impl StrictSessionAdapter {
    fn new(next_session_id: &str) -> Arc<Self> {
        Arc::new(Self {
            next_session_id: next_session_id.to_owned(),
            started_sessions: Mutex::new(Vec::new()),
            executed_sessions: Mutex::new(Vec::new()),
        })
    }
}

impl AgentAdapter for StrictSessionAdapter {
    fn name(&self) -> AgentType {
        AgentType::Codex
    }

    fn start_session(
        &self,
        options: SessionOptions,
    ) -> codepilot_agents::types::Result<SessionInfo> {
        self.started_sessions
            .lock()
            .unwrap()
            .push(self.next_session_id.clone());
        Ok(SessionInfo {
            id: self.next_session_id.clone(),
            agent_type: AgentType::Codex,
            work_dir: options.work_dir.to_string_lossy().into_owned(),
            state: AgentState::Idle,
            created_at: 2_000,
            last_active_at: 2_000,
        })
    }

    fn execute(
        &self,
        session_id: &str,
        input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        _options: Option<SessionOptions>,
    ) -> codepilot_agents::types::Result<()> {
        let started = self.started_sessions.lock().unwrap().clone();
        if !started.iter().any(|started_session| started_session == session_id) {
            return Err(codepilot_agents::types::AgentError::new(format!(
                "execute called for unknown live session: {session_id}"
            )));
        }

        self.executed_sessions
            .lock()
            .unwrap()
            .push(session_id.to_owned());
        on_event(AgentEvent::AgentMessage {
            text: input.to_owned(),
        });
        Ok(())
    }

    fn resume_session(&self, session_id: &str) -> codepilot_agents::types::Result<SessionInfo> {
        Ok(SessionInfo {
            id: session_id.to_owned(),
            agent_type: AgentType::Codex,
            work_dir: "/tmp/project".to_owned(),
            state: AgentState::Idle,
            created_at: 2_000,
            last_active_at: 2_000,
        })
    }

    fn cancel(&self, _session_id: &str) -> codepilot_agents::types::Result<()> {
        Ok(())
    }

    fn delete_session(&self, _session_id: &str) -> codepilot_agents::types::Result<()> {
        Ok(())
    }
}

struct BlockingAdapter {
    started_tx: Mutex<mpsc::Sender<String>>,
    cancel_tx: Mutex<mpsc::Sender<String>>,
    release_rx: Mutex<mpsc::Receiver<()>>,
    session: Mutex<Option<SessionInfo>>,
}

impl BlockingAdapter {
    fn new(
        started_tx: mpsc::Sender<String>,
        cancel_tx: mpsc::Sender<String>,
        release_rx: mpsc::Receiver<()>,
    ) -> Self {
        Self {
            started_tx: Mutex::new(started_tx),
            cancel_tx: Mutex::new(cancel_tx),
            release_rx: Mutex::new(release_rx),
            session: Mutex::new(None),
        }
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
        let session = SessionInfo {
            id: "blocking-session".to_owned(),
            agent_type: AgentType::Codex,
            work_dir: options.work_dir.to_string_lossy().into_owned(),
            state: AgentState::Idle,
            created_at: 1_000,
            last_active_at: 1_000,
        };
        *self.session.lock().unwrap() = Some(session.clone());
        Ok(session)
    }

    fn execute(
        &self,
        session_id: &str,
        _input: &str,
        on_event: &mut dyn FnMut(AgentEvent),
        _options: Option<SessionOptions>,
    ) -> codepilot_agents::types::Result<()> {
        self.started_tx
            .lock()
            .unwrap()
            .send(session_id.to_owned())
            .unwrap();
        self.release_rx.lock().unwrap().recv().unwrap();
        on_event(AgentEvent::Status {
            state: AgentState::Idle,
            message: "released".to_owned(),
        });
        Ok(())
    }

    fn resume_session(&self, session_id: &str) -> codepilot_agents::types::Result<SessionInfo> {
        Ok(self
            .session
            .lock()
            .unwrap()
            .clone()
            .unwrap_or(SessionInfo {
                id: session_id.to_owned(),
                agent_type: AgentType::Codex,
                work_dir: "/tmp/project".to_owned(),
                state: AgentState::Idle,
                created_at: 1_000,
                last_active_at: 1_000,
            }))
    }

    fn cancel(&self, session_id: &str) -> codepilot_agents::types::Result<()> {
        self.cancel_tx
            .lock()
            .unwrap()
            .send(session_id.to_owned())
            .unwrap();
        Ok(())
    }

    fn delete_session(&self, _session_id: &str) -> codepilot_agents::types::Result<()> {
        Ok(())
    }
}

fn wait_until(deadline: Duration, predicate: impl Fn() -> bool) {
    let start = Instant::now();
    while Instant::now().duration_since(start) < deadline {
        if predicate() {
            return;
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert!(predicate(), "condition was not met before timeout");
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

#[test]
fn runtime_message_handler_allows_ping_and_cancel_while_command_is_running() {
    let work_dir = unique_temp_dir("codepilot-bridge-runtime");
    fs::create_dir_all(&work_dir).unwrap();

    let (started_tx, started_rx) = mpsc::channel();
    let (cancel_tx, cancel_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(BlockingAdapter::new(
        started_tx,
        cancel_tx,
        release_rx,
    )));

    let shared = Arc::new(Mutex::new(bridge));
    let client = RecordingClient::new("client-1");

    handle_runtime_message(
        shared.clone(),
        client.clone(),
        PhoneMessage::Command {
            text: "block".to_owned(),
            session_id: None,
            config: None,
        },
    );

    let session_id = started_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("command should start executing");

    handle_runtime_message(
        shared.clone(),
        client.clone(),
        PhoneMessage::Ping { ts: 0 },
    );
    wait_until(Duration::from_secs(1), || {
        client
            .messages()
            .iter()
            .any(|message| matches!(message, BridgeMessage::Pong { .. }))
    });

    handle_runtime_message(
        shared.clone(),
        client.clone(),
        PhoneMessage::Cancel {
            session_id: session_id.clone(),
        },
    );
    assert_eq!(
        cancel_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("cancel should reach the running adapter"),
        session_id
    );

    release_tx.send(()).unwrap();
    wait_until(Duration::from_secs(1), || {
        client.messages().iter().any(|message| matches!(
            message,
            BridgeMessage::Event {
                event: AgentEvent::Status { message, .. },
                ..
            } if message == "released"
        ))
    });
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
    fs::write(work_dir.join("docs/turnview-guide.md"), "# Turnview\n").unwrap();
    fs::write(
        work_dir.join("src/nested/turnview-panel.rs"),
        "pub fn render() {}\n",
    )
    .unwrap();
    fs::write(work_dir.join("src/other.rs"), "pub fn other() {}\n").unwrap();

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
fn bridge_starts_a_fresh_live_session_when_a_new_process_receives_a_stale_session_id() {
    let work_dir = unique_temp_dir("codepilot-bridge-stale-session");
    fs::create_dir_all(&work_dir).unwrap();

    let mut seed_bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir: work_dir.clone(),
    });
    seed_bridge
        .persist_and_dispatch_event(
            "session-1",
            AgentEvent::AgentMessage {
                text: "persisted history".to_owned(),
            },
        )
        .unwrap();

    let adapter = StrictSessionAdapter::new("fresh-session-1");
    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(adapter.clone());

    let client = RecordingClient::new("client-1");
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::Command {
                text: "new turn".to_owned(),
                session_id: Some("session-1".to_owned()),
                config: None,
            },
        )
        .unwrap();

    assert_eq!(
        adapter.started_sessions.lock().unwrap().as_slice(),
        ["fresh-session-1"]
    );
    assert_eq!(
        adapter.executed_sessions.lock().unwrap().as_slice(),
        ["fresh-session-1"]
    );
    assert!(client.messages().iter().any(|message| matches!(
        message,
        BridgeMessage::Event {
            session_id,
            event: AgentEvent::AgentMessage { text },
            ..
        } if session_id == "fresh-session-1" && text == "new turn"
    )));
}

#[test]
fn bridge_new_wires_a_real_diff_service_for_diff_requests() {
    let work_dir = unique_temp_dir("codepilot-bridge-real-diff");
    fs::create_dir_all(work_dir.join("Sources")).unwrap();
    init_git_repo(&work_dir);

    let file_path = work_dir.join("Sources/App.swift");
    fs::write(&file_path, "import Foundation\nlet value = 1\n").unwrap();
    run_git(&work_dir, &["add", "."]);
    run_git(&work_dir, &["commit", "-m", "initial"]);

    fs::write(
        &file_path,
        "import Foundation\nlet value = 2\nlet label = \"ok\"\n",
    )
    .unwrap();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir: work_dir.clone(),
    });
    bridge
        .persist_and_dispatch_event(
            "session-1",
            AgentEvent::CodeChange {
                changes: vec![FileChange {
                    path: "Sources/App.swift".to_owned(),
                    kind: FileChangeKind::Update,
                }],
            },
        )
        .unwrap();

    let client = RecordingClient::new("client-1");
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::DiffReq {
                session_id: "session-1".to_owned(),
                event_id: 1,
            },
        )
        .unwrap();

    assert!(client.messages().iter().any(|message| matches!(
        message,
        BridgeMessage::DiffContent {
            session_id,
            event_id,
            files,
        } if session_id == "session-1"
            && *event_id == 1
            && files.len() == 1
            && files[0].path == "Sources/App.swift"
            && !files[0].loaded_hunks.is_empty()
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

#[test]
fn bridge_queues_canonical_live_events_while_replaying_a_temporary_alias() {
    let work_dir = unique_temp_dir("codepilot-bridge-replay-alias");
    fs::create_dir_all(&work_dir).unwrap();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(RemappingAdapter::default()));

    let original = RecordingClient::new("client-original");
    let replaying = RecordingClient::new("client-replay");

    bridge
        .handle_message(
            original.clone(),
            PhoneMessage::Command {
                text: "hello".to_owned(),
                session_id: None,
                config: None,
            },
        )
        .unwrap();

    bridge.begin_replay(replaying.clone(), "codex-1");
    bridge
        .handle_message(
            original.clone(),
            PhoneMessage::Command {
                text: "again".to_owned(),
                session_id: Some("real-session-1".to_owned()),
                config: None,
            },
        )
        .unwrap();

    assert!(
        replaying.messages().is_empty(),
        "canonical live events should queue until alias-based replay finishes"
    );

    bridge
        .complete_replay(replaying.clone(), "codex-1", 0)
        .unwrap();

    let replay_messages = replaying.messages();
    let replay_event_ids = replay_messages
        .iter()
        .filter_map(|message| match message {
            BridgeMessage::Event { event_id, .. } => Some(*event_id),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(replay_event_ids, vec![1, 2]);
    assert!(replay_messages.iter().all(|message| match message {
        BridgeMessage::Event { session_id, .. } => session_id == "real-session-1",
        BridgeMessage::SessionSyncComplete { session_id, .. } => session_id == "real-session-1",
        _ => true,
    }));
}

#[test]
fn bridge_remaps_temporary_session_ids_to_the_canonical_thread_id_after_execute() {
    let work_dir = unique_temp_dir("codepilot-bridge-remap");
    fs::create_dir_all(&work_dir).unwrap();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(RemappingAdapter::default()));

    let client = RecordingClient::new("client-1");

    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::Command {
                text: "hello".to_owned(),
                session_id: None,
                config: None,
            },
        )
        .unwrap();

    let session_lists = client
        .messages()
        .into_iter()
        .filter_map(|message| match message {
            BridgeMessage::SessionList { sessions } => Some(sessions),
            _ => None,
        })
        .collect::<Vec<_>>();
    let latest_sessions = session_lists.last().expect("expected a session list");
    assert_eq!(latest_sessions.len(), 1);
    assert_eq!(latest_sessions[0].id, "real-session-1");

    client.clear();
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::SyncSession {
                session_id: "codex-1".to_owned(),
                after_event_id: 0,
            },
        )
        .unwrap();

    let replay_messages = client.messages();
    assert!(replay_messages.iter().any(|message| matches!(
        message,
        BridgeMessage::Event {
            session_id,
            event: AgentEvent::AgentMessage { text },
            ..
        } if session_id == "real-session-1" && text == "hello"
    )));
    assert!(replay_messages.iter().any(|message| matches!(
        message,
        BridgeMessage::SessionSyncComplete {
            session_id,
            latest_event_id,
            resolved_session_id,
        } if session_id == "real-session-1"
            && *latest_event_id == 1
            && resolved_session_id.as_deref() == Some("real-session-1")
    )));

    client.clear();
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::Command {
                text: "again".to_owned(),
                session_id: Some("codex-1".to_owned()),
                config: None,
            },
        )
        .unwrap();

    let follow_up_messages = client.messages();
    assert!(follow_up_messages.iter().any(|message| matches!(
        message,
        BridgeMessage::Event {
            session_id,
            event: AgentEvent::AgentMessage { text },
            ..
        } if session_id == "real-session-1" && text == "again"
    )));
}

#[test]
fn bridge_prefers_live_temporary_session_ids_over_persisted_aliases_from_previous_runs() {
    let work_dir = unique_temp_dir("codepilot-bridge-live-temp-id");
    fs::create_dir_all(&work_dir).unwrap();

    let event_store = SessionEventLogStore::new(SessionEventLogStoreOptions {
        work_dir: work_dir.clone(),
        home_dir: None,
    });
    event_store
        .append_event(
            "old-real-session",
            1_700_000_000_000,
            AgentEvent::Status {
                state: AgentState::Idle,
                message: "old".to_owned(),
            },
        )
        .unwrap();
    event_store
        .remap_session_alias("codex-1", "old-real-session")
        .unwrap();

    let mut bridge = Bridge::new(BridgeOptions {
        agent: "codex".to_owned(),
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir,
    });
    bridge.set_adapter(Arc::new(RemappingAdapter::default()));

    let client = RecordingClient::new("client-1");
    bridge
        .handle_message(
            client.clone(),
            PhoneMessage::Command {
                text: "hello".to_owned(),
                session_id: None,
                config: None,
            },
        )
        .unwrap();

    let messages = client.messages();
    assert!(
        !messages.iter().any(|message| matches!(
            message,
            BridgeMessage::Event { session_id, .. } if session_id == "old-real-session"
        )),
        "live temporary session IDs should not be rewritten to a persisted alias from a previous bridge run"
    );

    let latest_session_list = messages
        .iter()
        .filter_map(|message| match message {
            BridgeMessage::SessionList { sessions } => Some(sessions.clone()),
            _ => None,
        })
        .last()
        .expect("expected a session list broadcast");
    assert_eq!(
        latest_session_list.iter().map(|session| session.id.clone()).collect::<Vec<_>>(),
        vec!["real-session-1".to_owned()]
    );
}
