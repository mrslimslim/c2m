use std::{
    collections::{HashMap, HashSet},
    fmt::{Display, Formatter},
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_agents::types::AgentError;
pub use codepilot_agents::types::{AgentAdapter, SessionOptions};
use codepilot_core::{
    diff::service::DiffService as CoreDiffService,
    logger::LOG,
    security::validate_file_request_path,
    session_store::event_log::{
        PersistedSessionEvent, SessionEventLogStore, SessionEventLogStoreOptions,
    },
    slash::{actions::dispatch_slash_action, catalog::build_slash_catalog},
};
use codepilot_protocol::{
    events::AgentEvent,
    messages::{BridgeMessage, PhoneMessage, SessionConfig},
    state::{AgentState, DiffFile, DiffHunk, FileSearchMatch, SessionInfo},
};

use crate::transport::types::TransportClient;

const MAX_FILE_SEARCH_RESULTS: u64 = 100;

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

impl From<AgentError> for BridgeError {
    fn from(value: AgentError) -> Self {
        Self(value.to_string())
    }
}

pub type Result<T> = std::result::Result<T, BridgeError>;
pub type PersistedBridgeEvent = PersistedSessionEvent;
pub type SharedBridge = Arc<Mutex<Bridge>>;

#[derive(Debug, Clone)]
pub struct BridgeOptions {
    pub agent: String,
    pub port: u16,
    pub host: Option<String>,
    pub work_dir: PathBuf,
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

struct CoreBackedDiffService {
    inner: CoreDiffService,
}

impl CoreBackedDiffService {
    fn new(inner: CoreDiffService) -> Self {
        Self { inner }
    }
}

impl DiffServiceApi for CoreBackedDiffService {
    fn load_diff(&self, session_id: &str, event_id: u64) -> Result<(String, u64, Vec<DiffFile>)> {
        let content = self
            .inner
            .load_diff(session_id, event_id)
            .map_err(|error| BridgeError::new(error.to_string()))?;
        Ok((content.session_id, content.event_id, content.files))
    }

    fn load_more_hunks(
        &self,
        session_id: &str,
        event_id: u64,
        path: &str,
        after_hunk_index: u64,
    ) -> Result<(String, u64, String, Vec<DiffHunk>, Option<u64>)> {
        let content = self
            .inner
            .load_more_hunks(session_id, event_id, path, after_hunk_index as usize)
            .map_err(|error| BridgeError::new(error.to_string()))?;
        Ok((
            content.session_id,
            content.event_id,
            content.path,
            content.hunks,
            content.next_hunk_index,
        ))
    }
}

#[derive(Debug, Clone)]
struct ReplayState {
    session_keys: HashSet<String>,
    queued_events: Vec<PersistedSessionEvent>,
}

struct PreparedCommand {
    adapter: Arc<dyn AgentAdapter>,
    session_id: String,
    execution_options: Option<SessionOptions>,
}

pub struct Bridge {
    adapter: Option<Arc<dyn AgentAdapter>>,
    connected_clients: HashMap<String, Arc<dyn TransportClient>>,
    diff_service: Box<dyn DiffServiceApi>,
    options: BridgeOptions,
    replay_states: HashMap<String, Arc<Mutex<ReplayState>>>,
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
        let diff_service = CoreBackedDiffService::new(CoreDiffService::new_with_default_loader(
            options.work_dir.clone(),
            Arc::new(session_event_store.clone()),
        ));

        Self {
            adapter: None,
            connected_clients: HashMap::new(),
            diff_service: Box::new(diff_service),
            options,
            replay_states: HashMap::new(),
            session_aliases: HashMap::new(),
            session_event_store,
            sessions: HashMap::new(),
            adapter_version: None,
        }
    }

    pub fn set_adapter(&mut self, adapter: Arc<dyn AgentAdapter>) {
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
        LOG.connection(&format!("{} connected", client.id()));
        client.send(BridgeMessage::SessionList {
            sessions: self.sessions.values().cloned().collect(),
        });

        if let Some(catalog) = self.slash_catalog_message() {
            client.send(catalog);
        }
    }

    pub fn handle_client_disconnected(&mut self, client_id: &str) {
        self.connected_clients.remove(client_id);
        self.replay_states
            .retain(|key, _| !key.starts_with(&format!("{client_id}:")));
        LOG.connection(&format!("{client_id} disconnected"));
    }

    pub fn handle_message(
        &mut self,
        client: Arc<dyn TransportClient>,
        message: PhoneMessage,
    ) -> Result<()> {
        self.remember_client(client.clone());
        log_phone_message(client.id(), &message);

        match message {
            PhoneMessage::Command {
                text,
                session_id,
                config,
            } => self.handle_command(client, &text, session_id, config),
            PhoneMessage::Cancel { session_id } => {
                if let Some(adapter) = self.adapter.as_mut() {
                    adapter.cancel(&session_id)?;
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
            PhoneMessage::FileSearchReq {
                session_id,
                query,
                limit,
            } => self.handle_file_search(client, &session_id, &query, limit),
            PhoneMessage::DeleteSession { session_id } => {
                if let Some(adapter) = self.adapter.as_mut() {
                    adapter.delete_session(&session_id)?;
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
        let replay_state = Arc::new(Mutex::new(ReplayState {
            session_keys: HashSet::new(),
            queued_events: Vec::new(),
        }));
        self.register_replay_state(client.id(), &replay_state, &[session_id.to_owned()]);
        if let Ok(canonical) = self.resolve_canonical_session_id(session_id)
            && canonical != session_id
        {
            self.register_replay_state(client.id(), &replay_state, &[canonical]);
        }
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
        let replay_state = self
            .replay_states
            .get(&key)
            .cloned()
            .or_else(|| self.replay_states.get(&self.replay_key(client.id(), session_id)).cloned())
            .unwrap_or_else(|| {
                let replay_state = Arc::new(Mutex::new(ReplayState {
                    session_keys: HashSet::new(),
                    queued_events: Vec::new(),
                }));
                self.register_replay_state(
                    client.id(),
                    &replay_state,
                    &[session_id.to_owned(), canonical.clone()],
                );
                replay_state
            });
        self.register_replay_state(client.id(), &replay_state, &[canonical.clone()]);

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
            let mut replay_state = replay_state
                .lock()
                .map_err(|_| BridgeError::new("failed to lock replay state"))?;
            replay_state.queued_events.sort_by_key(|event| event.event_id);
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
        self.unregister_replay_state(client.id(), &replay_state);
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
        log_persisted_event(&persisted);
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

        let prepared = self.prepare_command(session_id, config)?;
        let mut callback_error = None;
        let execute_result = prepared.adapter.execute(
            &prepared.session_id,
            text,
            &mut |event| {
                if callback_error.is_some() {
                    return;
                }

                if let Err(error) = self.persist_and_dispatch_event(&prepared.session_id, event) {
                    callback_error = Some(error);
                }
            },
            prepared.execution_options.clone(),
        );
        let refreshed_session =
            self.refresh_session_info_from_adapter(prepared.adapter.as_ref(), &prepared.session_id);

        if let Some(error) = callback_error {
            return Err(error);
        }

        execute_result?;
        if refreshed_session? {
            self.broadcast(BridgeMessage::SessionList {
                sessions: self.sessions.values().cloned().collect(),
            });
        }
        Ok(())
    }

    fn prepare_command(
        &mut self,
        session_id: Option<String>,
        config: Option<SessionConfig>,
    ) -> Result<PreparedCommand> {
        let adapter = self
            .adapter
            .clone()
            .ok_or_else(|| BridgeError::new("No agent adapter available"))?;
        let session_options = Self::build_session_options(&self.options.work_dir, config.as_ref());
        let mut broadcast_session_list = false;
        let session_id = match session_id {
            Some(existing) => {
                let canonical = self.resolve_canonical_session_id(&existing).ok();
                if let Some(canonical) = canonical
                    && self.sessions.contains_key(&canonical)
                {
                    canonical
                } else {
                    let session = adapter.start_session(session_options.clone())?;
                    let id = session.id.clone();
                    self.session_event_store.prepare_live_session(&id)?;
                    self.sessions.insert(id.clone(), session);
                    self.session_aliases.insert(id.clone(), id.clone());
                    broadcast_session_list = true;
                    id
                }
            }
            _ => {
                let session = adapter.start_session(session_options.clone())?;
                let id = session.id.clone();
                self.session_event_store.prepare_live_session(&id)?;
                self.sessions.insert(id.clone(), session);
                self.session_aliases.insert(id.clone(), id.clone());
                broadcast_session_list = true;
                id
            }
        };

        if broadcast_session_list {
            self.broadcast(BridgeMessage::SessionList {
                sessions: self.sessions.values().cloned().collect(),
            });
        }

        Ok(PreparedCommand {
            adapter,
            session_id,
            execution_options: config.map(|_| session_options.clone()),
        })
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

    fn handle_file_search(
        &self,
        client: Arc<dyn TransportClient>,
        session_id: &str,
        query: &str,
        limit: u64,
    ) -> Result<()> {
        let results = self.search_project_files(query, limit)?;
        client.send(BridgeMessage::FileSearchResults {
            session_id: session_id.to_owned(),
            query: query.to_owned(),
            results,
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

    fn refresh_session_info_from_adapter(
        &mut self,
        adapter: &dyn AgentAdapter,
        session_id: &str,
    ) -> Result<bool> {
        let session = adapter.resume_session(session_id)?;
        let resolved_session_id = self.resolve_canonical_session_id(session_id)?;

        if resolved_session_id == session.id {
            self.sessions.insert(session.id.clone(), session);
            return Ok(false);
        }

        self.session_event_store
            .remap_session_alias(&resolved_session_id, &session.id)?;
        for target in self.session_aliases.values_mut() {
            if *target == resolved_session_id {
                *target = session.id.clone();
            }
        }
        self.session_aliases
            .insert(resolved_session_id.clone(), session.id.clone());
        self.session_aliases
            .insert(session.id.clone(), session.id.clone());

        self.sessions.remove(&resolved_session_id);
        self.sessions.insert(session.id.clone(), session);
        Ok(true)
    }

    fn resolve_canonical_session_id(&self, session_id: &str) -> Result<String> {
        let mut current = session_id.to_owned();
        while let Some(next) = self.session_aliases.get(&current) {
            if next == &current {
                break;
            }
            current = next.clone();
        }
        if self.sessions.contains_key(&current) {
            return Ok(current);
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
            if let Some(replay_state) = self.replay_states.get(&key) {
                if let Ok(mut replay_state) = replay_state.lock() {
                    replay_state.queued_events.push(message.clone());
                }
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

    fn search_project_files(&self, query: &str, limit: u64) -> Result<Vec<FileSearchMatch>> {
        let trimmed_query = query.trim();
        if trimmed_query.is_empty() || limit == 0 {
            return Ok(Vec::new());
        }

        let work_dir = fs::canonicalize(&self.options.work_dir)
            .unwrap_or_else(|_| self.options.work_dir.clone());
        let capped_limit = limit.min(MAX_FILE_SEARCH_RESULTS) as usize;
        let query_lower = trimmed_query.to_lowercase();
        let mut results = Vec::new();
        Self::collect_file_search_matches(&work_dir, &work_dir, &query_lower, &mut results)?;
        results.sort_by(|left, right| left.path.cmp(&right.path));
        results.truncate(capped_limit);
        Ok(results)
    }

    fn collect_file_search_matches(
        root: &Path,
        dir: &Path,
        query_lower: &str,
        results: &mut Vec<FileSearchMatch>,
    ) -> Result<()> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            let path = entry.path();

            if file_type.is_dir() {
                if entry.file_name().to_string_lossy() == ".git" {
                    continue;
                }
                Self::collect_file_search_matches(root, &path, query_lower, results)?;
                continue;
            }

            if !file_type.is_file() {
                continue;
            }

            let relative = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if !relative.to_lowercase().contains(query_lower) {
                continue;
            }

            results.push(FileSearchMatch {
                path: relative,
                display_name: None,
                directory_hint: None,
            });
        }

        Ok(())
    }

    fn register_replay_state(
        &mut self,
        client_id: &str,
        replay_state: &Arc<Mutex<ReplayState>>,
        session_ids: &[String],
    ) {
        for session_id in session_ids {
            if session_id.is_empty() {
                continue;
            }
            if let Ok(mut replay_state_guard) = replay_state.lock() {
                replay_state_guard.session_keys.insert(session_id.clone());
            }
            self.replay_states.insert(
                self.replay_key(client_id, session_id),
                Arc::clone(replay_state),
            );
        }
    }

    fn unregister_replay_state(&mut self, client_id: &str, replay_state: &Arc<Mutex<ReplayState>>) {
        let session_keys = replay_state
            .lock()
            .map(|state| state.session_keys.clone())
            .unwrap_or_default();
        for session_id in session_keys {
            self.replay_states
                .remove(&self.replay_key(client_id, &session_id));
        }
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

pub fn handle_runtime_message(
    bridge: SharedBridge,
    client: Arc<dyn TransportClient>,
    message: PhoneMessage,
) {
    match message {
        PhoneMessage::Command {
            text,
            session_id,
            config,
        } => {
            let command_bridge = bridge.clone();
            let command_client = client.clone();
            std::thread::spawn(move || {
                if let Err(error) = execute_runtime_command(
                    command_bridge,
                    command_client.clone(),
                    text,
                    session_id,
                    config,
                ) {
                    command_client.send(BridgeMessage::Error {
                        message: error.to_string(),
                    });
                }
            });
        }
        other => {
            let result = bridge
                .lock()
                .map_err(|_| BridgeError::new("failed to lock bridge"))
                .and_then(|mut bridge| bridge.handle_message(client.clone(), other));
            if let Err(error) = result {
                client.send(BridgeMessage::Error {
                    message: error.to_string(),
                });
            }
        }
    }
}

fn execute_runtime_command(
    bridge: SharedBridge,
    _client: Arc<dyn TransportClient>,
    text: String,
    session_id: Option<String>,
    config: Option<SessionConfig>,
) -> Result<()> {
    let prepared = bridge
        .lock()
        .map_err(|_| BridgeError::new("failed to lock bridge"))?
        .prepare_command(session_id, config)?;

    let mut callback_error = None;
    let callback_session_id = prepared.session_id.clone();
    let callback_bridge = bridge.clone();
    let execute_result = prepared.adapter.execute(
        &prepared.session_id,
        &text,
        &mut |event| {
            if callback_error.is_some() {
                return;
            }

            let result = callback_bridge
                .lock()
                .map_err(|_| BridgeError::new("failed to lock bridge"))
                .and_then(|mut bridge| {
                    bridge.persist_and_dispatch_event(&callback_session_id, event)
                });
            if let Err(error) = result {
                callback_error = Some(error);
            }
        },
        prepared.execution_options.clone(),
    );

    let refreshed_session = bridge
        .lock()
        .map_err(|_| BridgeError::new("failed to lock bridge"))?
        .refresh_session_info_from_adapter(prepared.adapter.as_ref(), &prepared.session_id)?;

    if let Some(error) = callback_error {
        return Err(error);
    }

    execute_result?;

    if refreshed_session {
        let bridge = bridge
            .lock()
            .map_err(|_| BridgeError::new("failed to lock bridge"))?;
        bridge.broadcast(BridgeMessage::SessionList {
            sessions: bridge.sessions.values().cloned().collect(),
        });
    }

    Ok(())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn log_phone_message(client_id: &str, message: &PhoneMessage) {
    let detail = match message {
        PhoneMessage::Command {
            text,
            session_id,
            ..
        } => format!(
            "command session={} text={}",
            session_id.as_deref().unwrap_or("new"),
            summarize_for_log(text)
        ),
        PhoneMessage::Cancel { session_id } => format!("cancel session={session_id}"),
        PhoneMessage::FileReq { path, session_id } => {
            format!("file_req session={session_id} path={path}")
        }
        PhoneMessage::FileSearchReq {
            session_id,
            query,
            limit,
        } => format!("file_search_req session={session_id} query={query} limit={limit}"),
        PhoneMessage::DeleteSession { session_id } => format!("delete_session session={session_id}"),
        PhoneMessage::ListSessions {} => "list_sessions".to_owned(),
        PhoneMessage::Ping { ts } => format!("ping ts={ts}"),
        PhoneMessage::SyncSession {
            session_id,
            after_event_id,
        } => format!("sync_session session={session_id} after={after_event_id}"),
        PhoneMessage::DiffReq {
            session_id,
            event_id,
        } => format!("diff_req session={session_id} event={event_id}"),
        PhoneMessage::DiffHunksReq {
            session_id,
            event_id,
            path,
            after_hunk_index,
        } => format!(
            "diff_hunks_req session={session_id} event={event_id} path={path} after={after_hunk_index}"
        ),
        PhoneMessage::SlashAction {
            session_id,
            command_id,
            ..
        } => format!(
            "slash_action session={} command={command_id}",
            session_id.as_deref().unwrap_or("none")
        ),
    };

    LOG.connection(&format!("{client_id} -> {detail}"));
}

fn log_persisted_event(persisted: &PersistedSessionEvent) {
    match &persisted.event {
        AgentEvent::Status { message, .. } => {
            LOG.event(&persisted.session_id, "status", &summarize_for_log(message));
        }
        AgentEvent::Thinking { text } => {
            LOG.event(&persisted.session_id, "thinking", &summarize_for_log(text));
        }
        AgentEvent::CodeChange { changes } => {
            LOG.event(
                &persisted.session_id,
                "code_change",
                &format!("{} file(s)", changes.len()),
            );
        }
        AgentEvent::CommandExec {
            command, status, ..
        } => {
            let status = match status {
                codepilot_protocol::events::CommandExecStatus::Running => "running",
                codepilot_protocol::events::CommandExecStatus::Done => "done",
                codepilot_protocol::events::CommandExecStatus::Failed => "failed",
            };
            LOG.event(
                &persisted.session_id,
                "command_exec",
                &format!("{status}: {}", summarize_for_log(command)),
            );
        }
        AgentEvent::AgentMessage { text } => {
            LOG.event(&persisted.session_id, "agent_message", &summarize_for_log(text));
        }
        AgentEvent::Error { message } => {
            LOG.event(&persisted.session_id, "error", &summarize_for_log(message));
        }
        AgentEvent::TurnCompleted { summary, .. } => {
            LOG.event(
                &persisted.session_id,
                "turn_completed",
                &summarize_for_log(summary),
            );
        }
    }
}

fn summarize_for_log(text: &str) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= 80 {
        return compact;
    }

    let mut summary = compact.chars().take(77).collect::<String>();
    summary.push_str("...");
    summary
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
