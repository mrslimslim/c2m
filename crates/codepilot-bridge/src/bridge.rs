use std::{
    collections::HashMap,
    fmt::{Display, Formatter},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_core::{
    security::validate_file_request_path,
    session_store::event_log::{
        PersistedSessionEvent, SessionEventLogStore, SessionEventLogStoreOptions,
    },
    slash::{actions::dispatch_slash_action, catalog::build_slash_catalog},
};
use codepilot_protocol::{
    events::AgentEvent,
    messages::{
        ApprovalPolicy, BridgeMessage, ModelReasoningEffort, PhoneMessage, SandboxMode,
        SessionConfig,
    },
    state::{AgentState, AgentType, DiffFile, DiffHunk, SessionInfo},
};

use crate::transport::types::TransportClient;

#[derive(Debug)]
pub struct BridgeError(String);

impl BridgeError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl Display for BridgeError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for BridgeError {}

impl From<std::io::Error> for BridgeError {
    fn from(value: std::io::Error) -> Self {
        Self(value.to_string())
    }
}

impl From<codepilot_core::session_store::event_log::SessionStoreError> for BridgeError {
    fn from(value: codepilot_core::session_store::event_log::SessionStoreError) -> Self {
        Self(value.to_string())
    }
}

pub type Result<T> = std::result::Result<T, BridgeError>;
pub type PersistedBridgeEvent = PersistedSessionEvent;

#[derive(Debug, Clone)]
pub struct BridgeOptions {
    pub agent: String,
    pub port: u16,
    pub host: Option<String>,
    pub work_dir: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionOptions {
    pub work_dir: PathBuf,
    pub model: Option<String>,
    pub model_reasoning_effort: Option<ModelReasoningEffort>,
    pub approval_policy: Option<ApprovalPolicy>,
    pub sandbox_mode: Option<SandboxMode>,
}

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
    fn cancel(&mut self, session_id: &str);
    fn delete_session(&mut self, session_id: &str);
}

pub trait DiffServiceApi: Send + Sync {
    fn load_diff(&self, session_id: &str, event_id: u64) -> Result<(String, u64, Vec<DiffFile>)>;
    fn load_more_hunks(
        &self,
        session_id: &str,
        event_id: u64,
        path: &str,
        after_hunk_index: u64,
    ) -> Result<(String, u64, String, Vec<DiffHunk>, Option<u64>)>;
}

struct UnavailableDiffService;

impl DiffServiceApi for UnavailableDiffService {
    fn load_diff(&self, _session_id: &str, _event_id: u64) -> Result<(String, u64, Vec<DiffFile>)> {
        Err(BridgeError::new("diff service is unavailable"))
    }

    fn load_more_hunks(
        &self,
        _session_id: &str,
        _event_id: u64,
        _path: &str,
        _after_hunk_index: u64,
    ) -> Result<(String, u64, String, Vec<DiffHunk>, Option<u64>)> {
        Err(BridgeError::new("diff service is unavailable"))
    }
}

#[derive(Debug, Clone)]
struct ReplayState {
    queued_events: Vec<PersistedSessionEvent>,
}

pub struct Bridge {
    adapter: Option<Box<dyn AgentAdapter>>,
    connected_clients: HashMap<String, Arc<dyn TransportClient>>,
    diff_service: Box<dyn DiffServiceApi>,
    options: BridgeOptions,
    replay_states: HashMap<String, ReplayState>,
    session_aliases: HashMap<String, String>,
    session_event_store: SessionEventLogStore,
    sessions: HashMap<String, SessionInfo>,
    adapter_version: Option<String>,
}

impl Bridge {
    pub fn new(options: BridgeOptions) -> Self {
        let session_event_store = SessionEventLogStore::new(SessionEventLogStoreOptions {
            work_dir: options.work_dir.clone(),
            home_dir: None,
        });

        Self {
            adapter: None,
            connected_clients: HashMap::new(),
            diff_service: Box::new(UnavailableDiffService),
            options,
            replay_states: HashMap::new(),
            session_aliases: HashMap::new(),
            session_event_store,
            sessions: HashMap::new(),
            adapter_version: None,
        }
    }

    pub fn set_adapter(&mut self, adapter: Box<dyn AgentAdapter>) {
        self.adapter = Some(adapter);
    }

    pub fn set_diff_service(&mut self, diff_service: Box<dyn DiffServiceApi>) {
        self.diff_service = diff_service;
    }

    pub fn set_adapter_version(&mut self, adapter_version: Option<String>) {
        self.adapter_version = adapter_version;
    }

    pub fn handle_client_connected(&mut self, client: Arc<dyn TransportClient>) {
        self.remember_client(client.clone());
        client.send(BridgeMessage::SessionList {
            sessions: self.sessions.values().cloned().collect(),
        });

        if let Some(catalog) = self.slash_catalog_message() {
            client.send(catalog);
        }
    }

    pub fn handle_message(
        &mut self,
        client: Arc<dyn TransportClient>,
        message: PhoneMessage,
    ) -> Result<()> {
        self.remember_client(client.clone());

        match message {
            PhoneMessage::Command {
                text,
                session_id,
                config,
            } => self.handle_command(client, &text, session_id, config),
            PhoneMessage::Cancel { session_id } => {
                if let Some(adapter) = self.adapter.as_mut() {
                    adapter.cancel(&session_id);
                }
                self.persist_and_dispatch_event(
                    &session_id,
                    AgentEvent::Status {
                        state: AgentState::Idle,
                        message: "Cancelled".to_owned(),
                    },
                )?;
                Ok(())
            }
            PhoneMessage::FileReq {
                path,
                session_id: _,
            } => self.handle_file_request(client, &path),
            PhoneMessage::DeleteSession { session_id } => {
                if let Some(adapter) = self.adapter.as_mut() {
                    adapter.delete_session(&session_id);
                }
                self.sessions.remove(&session_id);
                self.broadcast(BridgeMessage::SessionList {
                    sessions: self.sessions.values().cloned().collect(),
                });
                Ok(())
            }
            PhoneMessage::ListSessions {} => {
                client.send(BridgeMessage::SessionList {
                    sessions: self.sessions.values().cloned().collect(),
                });
                Ok(())
            }
            PhoneMessage::Ping { ts } => {
                client.send(BridgeMessage::Pong {
                    latency_ms: now_ms() - ts,
                });
                Ok(())
            }
            PhoneMessage::SyncSession {
                session_id,
                after_event_id,
            } => {
                self.begin_replay(client.clone(), &session_id);
                let _ = self.complete_replay(client, &session_id, after_event_id)?;
                Ok(())
            }
            PhoneMessage::DiffReq {
                session_id,
                event_id,
            } => {
                let (session_id, event_id, files) =
                    self.diff_service.load_diff(&session_id, event_id)?;
                client.send(BridgeMessage::DiffContent {
                    session_id,
                    event_id,
                    files,
                });
                Ok(())
            }
            PhoneMessage::DiffHunksReq {
                session_id,
                event_id,
                path,
                after_hunk_index,
            } => {
                let (session_id, event_id, path, hunks, next_hunk_index) = self
                    .diff_service
                    .load_more_hunks(&session_id, event_id, &path, after_hunk_index)?;
                client.send(BridgeMessage::DiffHunksContent {
                    session_id,
                    event_id,
                    path,
                    hunks,
                    next_hunk_index,
                });
                Ok(())
            }
            PhoneMessage::SlashAction {
                session_id: _,
                command_id,
                arguments: _,
            } => {
                let result = dispatch_slash_action(&command_id);
                client.send(BridgeMessage::SlashActionResult {
                    command_id,
                    ok: result.ok,
                    message: result.message,
                });
                Ok(())
            }
        }
    }

    pub fn begin_replay(&mut self, client: Arc<dyn TransportClient>, session_id: &str) {
        self.remember_client(client.clone());
        self.replay_states.insert(
            self.replay_key(client.id(), session_id),
            ReplayState {
                queued_events: Vec::new(),
            },
        );
    }

    pub fn complete_replay(
        &mut self,
        client: Arc<dyn TransportClient>,
        session_id: &str,
        after_event_id: u64,
    ) -> Result<Vec<PersistedSessionEvent>> {
        self.remember_client(client.clone());
        let canonical = self.resolve_canonical_session_id(session_id)?;
        let key = self.replay_key(client.id(), &canonical);

        let mut flushed = self
            .session_event_store
            .read_events_after(&canonical, after_event_id)?;
        let mut latest_event_id = if flushed.is_empty() {
            self.latest_event_id(&canonical)?
        } else {
            flushed
                .last()
                .map(|event| event.event_id)
                .unwrap_or(after_event_id)
        };

        for event in &flushed {
            client.send(Self::to_event_message(event.clone()));
        }

        let queued = {
            let replay_state = self
                .replay_states
                .entry(key.clone())
                .or_insert(ReplayState {
                    queued_events: Vec::new(),
                });
            replay_state
                .queued_events
                .sort_by_key(|event| event.event_id);
            replay_state
                .queued_events
                .iter()
                .filter(|event| event.event_id > latest_event_id)
                .cloned()
                .collect::<Vec<_>>()
        };
        for event in &queued {
            latest_event_id = event.event_id;
            client.send(Self::to_event_message(event.clone()));
        }
        flushed.extend(queued);

        client.send(BridgeMessage::SessionSyncComplete {
            session_id: canonical.clone(),
            latest_event_id,
            resolved_session_id: (canonical != session_id).then_some(canonical.clone()),
        });
        self.replay_states.remove(&key);
        Ok(flushed)
    }

    pub fn persist_and_dispatch_event(
        &mut self,
        session_id: &str,
        event: AgentEvent,
    ) -> Result<PersistedSessionEvent> {
        let canonical = self.resolve_canonical_session_id(session_id)?;
        let persisted = self
            .session_event_store
            .append_event(&canonical, now_ms(), event)?;
        self.update_session_state(&persisted);
        self.dispatch_persisted_event(&persisted);
        Ok(persisted)
    }

    fn handle_command(
        &mut self,
        client: Arc<dyn TransportClient>,
        text: &str,
        session_id: Option<String>,
        config: Option<SessionConfig>,
    ) -> Result<()> {
        if self.adapter.is_none() {
            client.send(BridgeMessage::Error {
                message: "No agent adapter available".to_owned(),
            });
            return Ok(());
        }

        let session_options = Self::build_session_options(&self.options.work_dir, config.as_ref());
        let mut broadcast_session_list = false;
        let session_id = match session_id {
            Some(existing) if self.sessions.contains_key(&existing) => existing,
            Some(existing)
                if self
                    .session_event_store
                    .resolve_session_id(&existing)
                    .is_ok() =>
            {
                self.resolve_canonical_session_id(&existing)?
            }
            _ => {
                let session = {
                    let adapter = self.adapter.as_mut().expect("adapter checked above");
                    adapter.start_session(session_options.clone())?
                };
                let id = session.id.clone();
                self.sessions.insert(id.clone(), session);
                broadcast_session_list = true;
                id
            }
        };

        if broadcast_session_list {
            self.broadcast(BridgeMessage::SessionList {
                sessions: self.sessions.values().cloned().collect(),
            });
        }

        let mut events = Vec::new();
        {
            let adapter = self.adapter.as_mut().expect("adapter checked above");
            adapter.execute(
                &session_id,
                text,
                &mut |event| events.push(event),
                config.map(|_| session_options.clone()),
            )?;
        }

        for event in events {
            self.persist_and_dispatch_event(&session_id, event)?;
        }

        Ok(())
    }

    fn handle_file_request(&self, client: Arc<dyn TransportClient>, path: &str) -> Result<()> {
        let resolved = validate_file_request_path(&self.options.work_dir, Path::new(path))?;
        let canonical_work_dir = fs::canonicalize(&self.options.work_dir)
            .unwrap_or_else(|_| self.options.work_dir.clone());
        let relative = resolved
            .strip_prefix(&canonical_work_dir)
            .unwrap_or(&resolved)
            .to_string_lossy()
            .trim_start_matches('/')
            .to_owned();
        let content = fs::read_to_string(&resolved)?;
        let language = detect_language(&resolved);
        client.send(BridgeMessage::FileContent {
            path: if relative.is_empty() {
                path.to_owned()
            } else {
                relative
            },
            content,
            language,
        });
        Ok(())
    }

    fn broadcast(&self, message: BridgeMessage) {
        for client in self.connected_clients.values() {
            client.send(message.clone());
        }
    }

    fn remember_client(&mut self, client: Arc<dyn TransportClient>) {
        self.connected_clients
            .insert(client.id().to_owned(), client);
    }

    fn resolve_canonical_session_id(&self, session_id: &str) -> Result<String> {
        let mut current = session_id.to_owned();
        while let Some(next) = self.session_aliases.get(&current) {
            if next == &current {
                break;
            }
            current = next.clone();
        }
        Ok(self.session_event_store.resolve_session_id(&current)?)
    }

    fn latest_event_id(&self, session_id: &str) -> Result<u64> {
        Ok(self
            .session_event_store
            .read_events_after(session_id, 0)?
            .last()
            .map(|event| event.event_id)
            .unwrap_or(0))
    }

    fn dispatch_persisted_event(&mut self, persisted: &PersistedSessionEvent) {
        let message = persisted.clone();
        for client in self.connected_clients.values() {
            let key = self.replay_key(client.id(), &persisted.session_id);
            if let Some(replay_state) = self.replay_states.get_mut(&key) {
                replay_state.queued_events.push(message.clone());
                continue;
            }
            client.send(Self::to_event_message(message.clone()));
        }
    }

    fn update_session_state(&mut self, persisted: &PersistedSessionEvent) {
        if let Some(session) = self.sessions.get_mut(&persisted.session_id) {
            match &persisted.event {
                AgentEvent::Status { state, .. } => session.state = *state,
                AgentEvent::TurnCompleted { .. } => session.state = AgentState::Idle,
                AgentEvent::Error { .. } => session.state = AgentState::Error,
                _ => {}
            }
            session.last_active_at = persisted.timestamp;
        }
    }

    fn to_event_message(persisted: PersistedSessionEvent) -> BridgeMessage {
        BridgeMessage::Event {
            session_id: persisted.session_id,
            event: persisted.event,
            event_id: persisted.event_id,
            timestamp: persisted.timestamp,
        }
    }

    fn slash_catalog_message(&self) -> Option<BridgeMessage> {
        let adapter = self.adapter.as_ref()?;
        let catalog =
            build_slash_catalog(codepilot_core::slash::catalog::BuildSlashCatalogOptions {
                adapter: adapter.name(),
                adapter_version: self.adapter_version.clone(),
            });
        Some(BridgeMessage::SlashCatalog {
            capability: catalog.capability,
            adapter: catalog.adapter,
            adapter_version: catalog.adapter_version,
            catalog_version: catalog.catalog_version,
            defaults: catalog.defaults,
            commands: catalog.commands,
        })
    }

    fn replay_key(&self, client_id: &str, session_id: &str) -> String {
        format!("{client_id}:{session_id}")
    }

    fn build_session_options(work_dir: &Path, config: Option<&SessionConfig>) -> SessionOptions {
        SessionOptions {
            work_dir: work_dir.to_path_buf(),
            model: config.and_then(|config| config.model.clone()),
            model_reasoning_effort: config.and_then(|config| config.model_reasoning_effort),
            approval_policy: config.and_then(|config| config.approval_policy),
            sandbox_mode: config.and_then(|config| config.sandbox_mode),
        }
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn detect_language(path: &Path) -> String {
    match path
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or_default()
    {
        "ts" | "tsx" => "typescript",
        "js" | "jsx" => "javascript",
        "py" => "python",
        "rs" => "rust",
        "go" => "go",
        "java" => "java",
        "swift" => "swift",
        "json" => "json",
        "yaml" | "yml" => "yaml",
        "md" => "markdown",
        "css" => "css",
        "html" => "html",
        other => other,
    }
    .to_owned()
}
