use crate::{
    diff::parser::{ParsedDiffFile, parse_unified_diff},
    session_store::event_log::SessionEventLogStore,
};
use codepilot_protocol::{
    events::AgentEvent,
    state::{DiffFile, DiffHunk, FileChange},
};
use std::{
    collections::HashMap,
    fmt::{Display, Formatter},
    path::PathBuf,
    sync::{Arc, Mutex},
};

const DEFAULT_CACHE_TTL_MS: i64 = 15_000;
const DEFAULT_HUNK_PAGE_SIZE: usize = 1;
const MAX_HUNKS_PER_FILE: usize = 50;
const MAX_LINES_PER_HUNK: usize = 400;

#[derive(Debug)]
pub struct DiffServiceError(String);

impl DiffServiceError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl Display for DiffServiceError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DiffServiceError {}

pub type Result<T> = std::result::Result<T, DiffServiceError>;

pub type LoadDiffText = Arc<dyn Fn(&FileChange) -> Result<String> + Send + Sync>;
pub type NowFn = Arc<dyn Fn() -> i64 + Send + Sync>;

#[derive(Clone)]
pub struct DiffServiceOptions {
    pub work_dir: PathBuf,
    pub event_store: Arc<SessionEventLogStore>,
    pub cache_ttl_ms: i64,
    pub hunk_page_size: usize,
    pub load_diff_text: LoadDiffText,
    pub now: NowFn,
}

#[derive(Debug, Clone)]
struct CachedDiffEntry {
    expires_at: i64,
    files: Vec<ParsedDiffFile>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffContent {
    pub session_id: String,
    pub event_id: u64,
    pub files: Vec<DiffFile>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffHunksContent {
    pub session_id: String,
    pub event_id: u64,
    pub path: String,
    pub hunks: Vec<DiffHunk>,
    pub next_hunk_index: Option<u64>,
}

pub struct DiffService {
    event_store: Arc<SessionEventLogStore>,
    cache_ttl_ms: i64,
    hunk_page_size: usize,
    load_diff_text: LoadDiffText,
    now: NowFn,
    #[allow(dead_code)]
    work_dir: PathBuf,
    cache: Mutex<HashMap<String, CachedDiffEntry>>,
}

impl DiffService {
    pub fn new(options: DiffServiceOptions) -> Self {
        Self {
            event_store: options.event_store,
            cache_ttl_ms: if options.cache_ttl_ms == 0 {
                DEFAULT_CACHE_TTL_MS
            } else {
                options.cache_ttl_ms
            },
            hunk_page_size: if options.hunk_page_size == 0 {
                DEFAULT_HUNK_PAGE_SIZE
            } else {
                options.hunk_page_size
            },
            load_diff_text: options.load_diff_text,
            now: options.now,
            work_dir: options.work_dir,
            cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn load_diff(&self, session_id: &str, event_id: u64) -> Result<DiffContent> {
        let files = self.files_for_event(session_id, event_id)?;
        Ok(DiffContent {
            session_id: session_id.to_owned(),
            event_id,
            files: files
                .iter()
                .map(|file| file.to_initial_diff_file(self.hunk_page_size))
                .collect(),
        })
    }

    pub fn load_more_hunks(
        &self,
        session_id: &str,
        event_id: u64,
        path: &str,
        after_hunk_index: usize,
    ) -> Result<DiffHunksContent> {
        let files = self.files_for_event(session_id, event_id)?;
        let file = files
            .iter()
            .find(|entry| entry.path == path)
            .ok_or_else(|| DiffServiceError::new(format!("No diff file found for path {path}")))?;

        let hunks = file
            .hunks
            .iter()
            .skip(after_hunk_index)
            .take(self.hunk_page_size)
            .cloned()
            .collect::<Vec<_>>();
        let next_index = after_hunk_index + hunks.len();

        Ok(DiffHunksContent {
            session_id: session_id.to_owned(),
            event_id,
            path: path.to_owned(),
            hunks,
            next_hunk_index: if next_index < file.hunks.len() {
                Some(next_index as u64)
            } else {
                None
            },
        })
    }

    fn files_for_event(&self, session_id: &str, event_id: u64) -> Result<Vec<ParsedDiffFile>> {
        let cache_key = format!("{session_id}:{event_id}");
        if let Some(cached) = self.cache.lock().unwrap().get(&cache_key).cloned() {
            if cached.expires_at > (self.now)() {
                return Ok(cached.files);
            }
        }

        let events = self
            .event_store
            .read_events_after(session_id, event_id.saturating_sub(1))
            .map_err(|error| DiffServiceError::new(error.to_string()))?;
        let target = events
            .into_iter()
            .find(|record| record.event_id == event_id)
            .ok_or_else(|| {
                DiffServiceError::new(format!(
                    "No event found for session {session_id} and eventId {event_id}"
                ))
            })?;

        let AgentEvent::CodeChange { changes } = target.event else {
            return Err(DiffServiceError::new(format!(
                "Event {event_id} is not a code_change event"
            )));
        };

        let files = changes
            .iter()
            .map(|change| {
                let diff_text = (self.load_diff_text)(change)?;
                let parsed = parse_unified_diff(&diff_text, std::slice::from_ref(change))
                    .into_iter()
                    .next()
                    .unwrap_or(ParsedDiffFile {
                        path: change.path.clone(),
                        kind: change.kind,
                        added_lines: Some(0),
                        deleted_lines: Some(0),
                        is_truncated: true,
                        truncation_reason: Some(
                            "Diff unavailable for current workspace state.".to_owned(),
                        ),
                        total_hunk_count: 0,
                        hunks: Vec::new(),
                    });
                Ok(self.apply_limits(parsed))
            })
            .collect::<Result<Vec<_>>>()?;

        self.cache.lock().unwrap().insert(
            cache_key,
            CachedDiffEntry {
                expires_at: (self.now)() + self.cache_ttl_ms,
                files: files.clone(),
            },
        );

        Ok(files)
    }

    fn apply_limits(&self, file: ParsedDiffFile) -> ParsedDiffFile {
        let mut is_truncated = file.is_truncated;
        let mut truncation_reason = file.truncation_reason.clone();

        let hunks = file
            .hunks
            .iter()
            .take(MAX_HUNKS_PER_FILE)
            .cloned()
            .map(|mut hunk| {
                if hunk.lines.len() > MAX_LINES_PER_HUNK {
                    is_truncated = true;
                    if truncation_reason.is_none() {
                        truncation_reason =
                            Some("Diff truncated to keep the mobile viewer responsive.".to_owned());
                    }
                    hunk.lines.truncate(MAX_LINES_PER_HUNK);
                }
                hunk
            })
            .collect::<Vec<_>>();

        if file.hunks.len() > MAX_HUNKS_PER_FILE {
            is_truncated = true;
            if truncation_reason.is_none() {
                truncation_reason =
                    Some("Diff truncated to keep the mobile viewer responsive.".to_owned());
            }
        }

        ParsedDiffFile {
            path: file.path,
            kind: file.kind,
            added_lines: file.added_lines,
            deleted_lines: file.deleted_lines,
            is_truncated,
            truncation_reason,
            total_hunk_count: file.hunks.len() as u64,
            hunks,
        }
    }
}
