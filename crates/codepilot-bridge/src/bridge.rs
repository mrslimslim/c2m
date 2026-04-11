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
    diff::service::DiffService,
    security::validate_file_request_path,
    session_store::event_log::{
        PersistedSessionEvent, SessionEventLogStore, SessionEventLogStoreOptions,
    },
    slash::{actions::dispatch_slash_action, catalog::build_slash_catalog},
};
use codepilot_protocol::{
    events::{AgentEvent, CommandExecStatus},
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

impl DiffServiceApi for DiffService {
    fn load_diff(&self, session_id: &str, event_id: u64) -> Result<(String, u64, Vec<DiffFile>)> {
        let content = self
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
    queued_events: Vec<PersistedSessionEvent>,
}

struct PreparedCommand {
    adapter: Arc<dyn AgentAdapter>,
    execution_id: u64,
    execution_options: Option<SessionOptions>,
    session_id: String,
    text: String,
}

pub struct Bridge {
    adapter: Option<Arc<dyn AgentAdapter>>,
    connected_clients: HashMap<String, Arc<dyn TransportClient>>,
    diff_service: Box<dyn DiffServiceApi>,
    next_execution_id: u64,
    options: BridgeOptions,
    replay_states: HashMap<String, ReplayState>,
    active_execution_id_by_session: HashMap<String, u64>,
    session_aliases: HashMap<String, String>,
    session_event_store: SessionEventLogStore,
    sessions: HashMap<String, SessionInfo>,
    terminated_execution_ids: HashSet<u64>,
    adapter_version: Option<String>,
}

impl Bridge {
    pub fn new(options: BridgeOptions) -> Self {
        let session_event_store = SessionEventLogStore::new(SessionEventLogStoreOptions {
            work_dir: options.work_dir.clone(),
            home_dir: None,
        });
        let diff_service = DiffService::new_with_default_loader(
            options.work_dir.clone(),
            Arc::new(session_event_store.clone()),
        );

        Self {
            adapter: None,
            connected_clients: HashMap::new(),
            diff_service: Box::new(diff_service),
            next_execution_id: 1,
            options,
            replay_states: HashMap::new(),
            active_execution_id_by_session: HashMap::new(),
            session_aliases: HashMap::new(),
            session_event_store,
            sessions: HashMap::new(),
            terminated_execution_ids: HashSet::new(),
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
            } => {
                let prepared = self.prepare_command(&text, session_id, config)?;
                self.execute_prepared_command(prepared)
            }
            PhoneMessage::Cancel { session_id } => {
                let resolved_session_id = self.resolve_runtime_session_id(&session_id);
                if let Some(adapter) = self.adapter.as_ref() {
                    adapter.cancel(&session_id)?;
                }
                if let Some(execution_id) = self
                    .active_execution_id_by_session
                    .get(&resolved_session_id)
                    .copied()
                {
                    self.terminated_execution_ids.insert(execution_id);
                }
                self.persist_and_dispatch_event(
                    &resolved_session_id,
                    AgentEvent::Status {
                        state: AgentState::Idle,
                        message: "Cancelled".to_owned(),
                    },
                )?;
                Ok(())
            }
            PhoneMessage::FileReq { path, session_id } => {
                match self.handle_file_request(client.clone(), &path) {
                    Ok(()) => {}
                    Err(error) => {
                        client.send(BridgeMessage::FileError {
                            session_id,
                            path,
                            message: error.to_string(),
                        });
                    }
                }
                Ok(())
            }
            PhoneMessage::FileSearchReq {
                session_id,
                query,
                limit,
            } => self.handle_file_search(client, &session_id, &query, limit),
            PhoneMessage::DeleteSession { session_id } => {
                let resolved_session_id = self.resolve_runtime_session_id(&session_id);
                if let Some(adapter) = self.adapter.as_ref() {
                    adapter.delete_session(&session_id)?;
                }
                if let Some(execution_id) = self
                    .active_execution_id_by_session
                    .get(&resolved_session_id)
                    .copied()
                {
                    self.terminated_execution_ids.insert(execution_id);
                }
                self.remove_session(&resolved_session_id);
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
                match self.diff_service.load_diff(&session_id, event_id) {
                    Ok((session_id, event_id, files)) => {
                        client.send(BridgeMessage::DiffContent {
                            session_id,
                            event_id,
                            files,
                        });
                    }
                    Err(error) => {
                        client.send(BridgeMessage::DiffError {
                            session_id,
                            event_id,
                            path: None,
                            message: error.to_string(),
                        });
                    }
                }
                Ok(())
            }
            PhoneMessage::DiffHunksReq {
                session_id,
                event_id,
                path,
                after_hunk_index,
            } => {
                match self.diff_service.load_more_hunks(
                    &session_id,
                    event_id,
                    &path,
                    after_hunk_index,
                ) {
                    Ok((session_id, event_id, path, hunks, next_hunk_index)) => {
                        client.send(BridgeMessage::DiffHunksContent {
                            session_id,
                            event_id,
                            path,
                            hunks,
                            next_hunk_index,
                        });
                    }
                    Err(error) => {
                        client.send(BridgeMessage::DiffError {
                            session_id,
                            event_id,
                            path: Some(path),
                            message: error.to_string(),
                        });
                    }
                }
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

    fn handle_file_request(&self, client: Arc<dyn TransportClient>, path: &str) -> Result<()> {
        let normalized_request_path = self.normalize_file_request_path(path);
        let resolved = validate_file_request_path(
            &self.options.work_dir,
            Path::new(&normalized_request_path),
        )?;
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
            path: if Path::new(path).is_absolute() {
                path.to_owned()
            } else if relative.is_empty() {
                path.to_owned()
            } else {
                relative
            },
            content,
            language,
        });
        Ok(())
    }

    fn normalize_file_request_path(&self, path: &str) -> String {
        let requested = Path::new(path);
        if !requested.is_absolute() {
            return path.to_owned();
        }

        let canonical_work_dir = fs::canonicalize(&self.options.work_dir)
            .unwrap_or_else(|_| self.options.work_dir.clone());
        let resolved = fs::canonicalize(requested).unwrap_or_else(|_| requested.to_path_buf());
        resolved
            .strip_prefix(&canonical_work_dir)
            .ok()
            .map(|relative| {
                relative
                    .to_string_lossy()
                    .trim_start_matches('/')
                    .to_owned()
            })
            .filter(|relative| !relative.is_empty())
            .unwrap_or_else(|| path.to_owned())
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

    fn prepare_command(
        &mut self,
        text: &str,
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
                let session = adapter.start_session(session_options.clone())?;
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

        let execution_id = self.next_execution_id;
        self.next_execution_id += 1;
        self.active_execution_id_by_session
            .insert(session_id.clone(), execution_id);

        Ok(PreparedCommand {
            adapter,
            execution_id,
            execution_options: config.map(|_| session_options.clone()),
            session_id,
            text: text.to_owned(),
        })
    }

    fn execute_prepared_command(&mut self, prepared: PreparedCommand) -> Result<()> {
        let session_id = prepared.session_id.clone();
        let execution_id = prepared.execution_id;
        let result = Self::run_prepared_command(prepared, |event| {
            if self.should_ignore_execution_event(execution_id) {
                return Ok(());
            }
            self.persist_and_dispatch_event(&session_id, event)
                .map(|_| ())
        });
        self.finish_command_execution(&session_id, execution_id, result)
    }

    fn run_prepared_command<F>(prepared: PreparedCommand, mut persist_event: F) -> Result<()>
    where
        F: FnMut(AgentEvent) -> Result<()>,
    {
        let mut callback_error = None;
        let execute_result = prepared.adapter.execute(
            &prepared.session_id,
            &prepared.text,
            &mut |event| {
                if callback_error.is_some() {
                    return;
                }

                if let Err(error) = persist_event(event) {
                    callback_error = Some(error);
                }
            },
            prepared.execution_options.clone(),
        );

        if let Some(error) = callback_error {
            return Err(error);
        }

        execute_result?;
        Ok(())
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

    fn resolve_runtime_session_id(&self, session_id: &str) -> String {
        if self.sessions.contains_key(session_id) {
            return session_id.to_owned();
        }

        self.resolve_canonical_session_id(session_id)
            .unwrap_or_else(|_| session_id.to_owned())
    }

    fn remove_session(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
        self.active_execution_id_by_session.remove(session_id);
    }

    fn should_ignore_execution_event(&self, execution_id: u64) -> bool {
        self.terminated_execution_ids.contains(&execution_id)
    }

    fn finish_command_execution(
        &mut self,
        session_id: &str,
        execution_id: u64,
        result: Result<()>,
    ) -> Result<()> {
        if self.active_execution_id_by_session.get(session_id) == Some(&execution_id) {
            self.active_execution_id_by_session.remove(session_id);
        }

        if self.terminated_execution_ids.remove(&execution_id) {
            return Ok(());
        }

        result
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
            if let Some(state) = Self::display_state_for_event(&persisted.event) {
                session.state = state;
            }
            session.last_active_at = persisted.timestamp;
        }
    }

    fn display_state_for_event(event: &AgentEvent) -> Option<AgentState> {
        match event {
            AgentEvent::Status { state, .. } => Some(*state),
            AgentEvent::Thinking { .. } => Some(AgentState::Thinking),
            AgentEvent::CodeChange { .. } => Some(AgentState::Coding),
            AgentEvent::CommandExec { status, .. } => Some(match status {
                CommandExecStatus::Running => AgentState::RunningCommand,
                CommandExecStatus::Done | CommandExecStatus::Failed => AgentState::Thinking,
            }),
            AgentEvent::AgentMessage { .. } => Some(AgentState::Thinking),
            AgentEvent::TurnCompleted { .. } => Some(AgentState::Idle),
            AgentEvent::Error { .. } => Some(AgentState::Error),
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
        let query_lower = trimmed_query.to_lowercase();
        let capped_limit = limit.min(MAX_FILE_SEARCH_RESULTS) as usize;
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
            std::thread::spawn(move || {
                dispatch_runtime_command(bridge, client, text, session_id, config);
            });
        }
        other => dispatch_runtime_message(bridge, client, other),
    }
}

fn dispatch_runtime_command(
    bridge: SharedBridge,
    client: Arc<dyn TransportClient>,
    text: String,
    session_id: Option<String>,
    config: Option<SessionConfig>,
) {
    let prepared = bridge
        .lock()
        .map_err(|_| BridgeError::new("failed to lock bridge"))
        .and_then(|mut bridge| bridge.prepare_command(&text, session_id, config));

    let result = match prepared {
        Ok(prepared) => {
            let prepared_session_id = prepared.session_id.clone();
            let execution_id = prepared.execution_id;
            let result = Bridge::run_prepared_command(prepared, |event| {
                let mut bridge = bridge
                    .lock()
                    .map_err(|_| BridgeError::new("failed to lock bridge"))?;
                if bridge.should_ignore_execution_event(execution_id) {
                    return Ok(());
                }
                bridge
                    .persist_and_dispatch_event(&prepared_session_id, event)
                    .map(|_| ())
            });

            bridge
                .lock()
                .map_err(|_| BridgeError::new("failed to lock bridge"))
                .and_then(|mut bridge| {
                    bridge.finish_command_execution(&prepared_session_id, execution_id, result)
                })
        }
        Err(error) => Err(error),
    };

    if let Err(error) = result {
        client.send(BridgeMessage::Error {
            message: error.to_string(),
        });
    }
}

fn dispatch_runtime_message(
    bridge: SharedBridge,
    client: Arc<dyn TransportClient>,
    message: PhoneMessage,
) {
    let result = bridge
        .lock()
        .map_err(|_| BridgeError::new("failed to lock bridge"))
        .and_then(|mut bridge| bridge.handle_message(client.clone(), message));
    if let Err(error) = result {
        client.send(BridgeMessage::Error {
            message: error.to_string(),
        });
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
