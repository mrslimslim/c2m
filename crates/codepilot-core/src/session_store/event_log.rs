use crate::session_store::path::{default_session_event_log_path, default_session_index_path};
use codepilot_protocol::events::AgentEvent;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    fmt::{Display, Formatter},
    fs, io,
    path::PathBuf,
};

#[derive(Debug)]
pub enum SessionStoreError {
    Io(io::Error),
    Json(serde_json::Error),
    InvalidIndex(PathBuf),
    CorruptEventLog(PathBuf),
    AliasConflict,
}

impl Display for SessionStoreError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(err) => write!(f, "io error: {err}"),
            Self::Json(err) => write!(f, "json error: {err}"),
            Self::InvalidIndex(path) => write!(f, "invalid session index file: {}", path.display()),
            Self::CorruptEventLog(path) => {
                write!(f, "corrupt session event log: {}", path.display())
            }
            Self::AliasConflict => write!(
                f,
                "cannot remap alias with existing history into canonical session with existing history"
            ),
        }
    }
}

impl std::error::Error for SessionStoreError {}

impl From<io::Error> for SessionStoreError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<serde_json::Error> for SessionStoreError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}

pub type Result<T> = std::result::Result<T, SessionStoreError>;

#[derive(Debug, Clone)]
pub struct SessionEventLogStoreOptions {
    pub work_dir: PathBuf,
    pub home_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PersistedSessionEvent {
    pub event_id: u64,
    pub session_id: String,
    pub timestamp: i64,
    pub event: AgentEvent,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionIndexEntry {
    pub canonical_session_id: String,
    pub latest_event_id: u64,
    pub alias_session_ids: Vec<String>,
    pub log_path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SessionIndexFile {
    version: u8,
    sessions: BTreeMap<String, SessionIndexEntry>,
    aliases: BTreeMap<String, String>,
}

pub struct SessionEventLogStore {
    work_dir: PathBuf,
    home_dir: Option<PathBuf>,
}

impl SessionEventLogStore {
    pub fn new(options: SessionEventLogStoreOptions) -> Self {
        Self {
            work_dir: options.work_dir,
            home_dir: options.home_dir,
        }
    }

    pub fn append_event(
        &self,
        session_id: &str,
        timestamp: i64,
        event: AgentEvent,
    ) -> Result<PersistedSessionEvent> {
        let mut index = self.load_index_file()?;
        let canonical_session_id = self.resolve_canonical_session_id_from_index(&index, session_id);
        let mut entry = self.ensure_session_entry(&mut index, &canonical_session_id)?;
        let latest_from_log = self.read_latest_event_id(&entry.log_path)?;
        let event_id = entry.latest_event_id.max(latest_from_log) + 1;

        let persisted = PersistedSessionEvent {
            event_id,
            session_id: canonical_session_id.clone(),
            timestamp,
            event,
        };

        if let Some(parent) = entry.log_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut records = self.read_log_records(&entry.log_path)?;
        records.push(persisted.clone());
        self.write_log_records(&entry.log_path, &records)?;

        entry.latest_event_id = event_id;
        index.sessions.insert(canonical_session_id, entry);
        self.save_index_file(&index)?;

        Ok(persisted)
    }

    pub fn read_events_after(
        &self,
        session_id: &str,
        after_event_id: u64,
    ) -> Result<Vec<PersistedSessionEvent>> {
        let index = self.load_index_file()?;
        let canonical_session_id = self.resolve_canonical_session_id_from_index(&index, session_id);
        let Some(entry) = index.sessions.get(&canonical_session_id) else {
            return Ok(Vec::new());
        };

        Ok(self
            .read_log_records(&entry.log_path)?
            .into_iter()
            .filter(|record| record.event_id > after_event_id)
            .collect())
    }

    pub fn remap_session_alias(
        &self,
        alias_session_id: &str,
        canonical_session_id: &str,
    ) -> Result<()> {
        let mut index = self.load_index_file()?;
        let resolved_alias = self.resolve_canonical_session_id_from_index(&index, alias_session_id);
        let final_canonical =
            self.resolve_canonical_session_id_from_index(&index, canonical_session_id);

        let mut canonical_entry = self.ensure_session_entry(&mut index, &final_canonical)?;

        if resolved_alias != final_canonical {
            let alias_entry = index.sessions.get(&resolved_alias).cloned();
            let alias_records = alias_entry
                .as_ref()
                .map(|entry| self.read_log_records(&entry.log_path))
                .transpose()?
                .unwrap_or_default();
            let canonical_records = self.read_log_records(&canonical_entry.log_path)?;

            if !alias_records.is_empty() && !canonical_records.is_empty() {
                return Err(SessionStoreError::AliasConflict);
            }

            if !alias_records.is_empty() {
                let migrated_records = alias_records
                    .into_iter()
                    .map(|record| PersistedSessionEvent {
                        session_id: final_canonical.clone(),
                        ..record
                    })
                    .collect::<Vec<_>>();
                self.write_log_records(&canonical_entry.log_path, &migrated_records)?;
            }

            let mut aliases = canonical_entry.alias_session_ids.clone();
            if let Some(alias_entry) = alias_entry {
                aliases.extend(alias_entry.alias_session_ids);
                aliases.push(resolved_alias.clone());
                index.sessions.remove(&resolved_alias);
            }
            aliases.push(alias_session_id.to_owned());
            canonical_entry.alias_session_ids = dedupe(aliases);
        } else {
            let mut aliases = canonical_entry.alias_session_ids.clone();
            aliases.push(alias_session_id.to_owned());
            canonical_entry.alias_session_ids = dedupe(aliases);
        }

        canonical_entry.latest_event_id = self.read_latest_event_id(&canonical_entry.log_path)?;
        index
            .sessions
            .insert(final_canonical.clone(), canonical_entry.clone());

        index
            .aliases
            .insert(alias_session_id.to_owned(), final_canonical.clone());
        index
            .aliases
            .insert(resolved_alias.clone(), final_canonical.clone());

        for target in index.aliases.values_mut() {
            if *target == resolved_alias {
                *target = final_canonical.clone();
            }
        }

        self.save_index_file(&index)
    }

    pub fn resolve_session_id(&self, session_id: &str) -> Result<String> {
        let index = self.load_index_file()?;
        Ok(self.resolve_canonical_session_id_from_index(&index, session_id))
    }

    fn load_index_file(&self) -> Result<SessionIndexFile> {
        let index_path = default_session_index_path(&self.work_dir, self.home_dir.as_deref())?;
        match fs::read_to_string(&index_path) {
            Ok(raw) => {
                let parsed: SessionIndexFile = serde_json::from_str(&raw)?;
                if parsed.version != 1 {
                    return Err(SessionStoreError::InvalidIndex(index_path));
                }
                Ok(parsed)
            }
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(SessionIndexFile {
                version: 1,
                sessions: BTreeMap::new(),
                aliases: BTreeMap::new(),
            }),
            Err(err) => Err(SessionStoreError::Io(err)),
        }
    }

    fn save_index_file(&self, index: &SessionIndexFile) -> Result<()> {
        let index_path = default_session_index_path(&self.work_dir, self.home_dir.as_deref())?;
        if let Some(parent) = index_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let raw = format!("{}\n", serde_json::to_string_pretty(index)?);
        fs::write(index_path, raw)?;
        Ok(())
    }

    fn ensure_session_entry(
        &self,
        index: &mut SessionIndexFile,
        canonical_session_id: &str,
    ) -> Result<SessionIndexEntry> {
        if let Some(existing) = index.sessions.get(canonical_session_id) {
            return Ok(existing.clone());
        }

        Ok(SessionIndexEntry {
            canonical_session_id: canonical_session_id.to_owned(),
            latest_event_id: 0,
            alias_session_ids: Vec::new(),
            log_path: default_session_event_log_path(
                &self.work_dir,
                canonical_session_id,
                self.home_dir.as_deref(),
            )?,
        })
    }

    fn resolve_canonical_session_id_from_index(
        &self,
        index: &SessionIndexFile,
        session_id: &str,
    ) -> String {
        let mut visited = HashSet::new();
        let mut current = session_id.to_owned();

        loop {
            if !visited.insert(current.clone()) {
                return current;
            }

            let Some(next) = index.aliases.get(&current) else {
                return current;
            };
            current = next.clone();
        }
    }

    fn read_latest_event_id(&self, log_path: &PathBuf) -> Result<u64> {
        Ok(self
            .read_log_records(log_path)?
            .last()
            .map(|record| record.event_id)
            .unwrap_or(0))
    }

    fn read_log_records(&self, log_path: &PathBuf) -> Result<Vec<PersistedSessionEvent>> {
        match fs::read_to_string(log_path) {
            Ok(raw) => {
                let mut records = Vec::new();
                for line in raw.lines() {
                    if line.trim().is_empty() {
                        continue;
                    }
                    let record: PersistedSessionEvent = serde_json::from_str(line)
                        .map_err(|_| SessionStoreError::CorruptEventLog(log_path.clone()))?;
                    records.push(record);
                }
                Ok(records)
            }
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(err) => Err(SessionStoreError::Io(err)),
        }
    }

    fn write_log_records(
        &self,
        log_path: &PathBuf,
        records: &[PersistedSessionEvent],
    ) -> Result<()> {
        if let Some(parent) = log_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let raw = records
            .iter()
            .map(serde_json::to_string)
            .collect::<std::result::Result<Vec<_>, _>>()?
            .join("\n");
        fs::write(log_path, format!("{raw}\n"))?;
        Ok(())
    }
}

fn dedupe(values: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut ordered = Vec::new();
    for value in values {
        if seen.insert(value.clone()) {
            ordered.push(value);
        }
    }
    ordered
}
