use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_core::session_store::{
    event_log::{SessionEventLogStore, SessionEventLogStoreOptions},
    path::{default_session_event_log_path, default_session_index_path},
};
use codepilot_protocol::events::AgentEvent;

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("{prefix}-{suffix}"))
}

fn thinking_event(message: &str) -> AgentEvent {
    AgentEvent::Status {
        state: codepilot_protocol::state::AgentState::Thinking,
        message: message.to_owned(),
    }
}

#[test]
fn session_store_paths_are_stable_for_the_same_work_dir() {
    let home_dir = unique_temp_dir("codepilot-home");
    let work_dir = unique_temp_dir("codepilot-work");
    fs::create_dir_all(&home_dir).unwrap();
    fs::create_dir_all(&work_dir).unwrap();

    let index_a = default_session_index_path(&work_dir, Some(&home_dir)).unwrap();
    let index_b = default_session_index_path(work_dir.join("."), Some(&home_dir)).unwrap();
    let event_log_path =
        default_session_event_log_path(&work_dir, "session-1", Some(&home_dir)).unwrap();

    assert_eq!(index_a, index_b);
    let index_text = index_a.to_string_lossy();
    assert!(index_text.contains(".codepilot/sessions/"));
    assert!(index_text.ends_with("/index.json"));
    assert!(event_log_path.ends_with("events/session-1.jsonl"));
}

#[test]
fn append_event_persists_jsonl_and_replay_filters_by_cursor() {
    let home_dir = unique_temp_dir("codepilot-home");
    let work_dir = unique_temp_dir("codepilot-work");
    fs::create_dir_all(&home_dir).unwrap();
    fs::create_dir_all(&work_dir).unwrap();

    let store = SessionEventLogStore::new(SessionEventLogStoreOptions {
        work_dir: work_dir.clone(),
        home_dir: Some(home_dir.clone()),
    });

    let first = store
        .append_event("session-1", 1000, thinking_event("first"))
        .unwrap();
    let second = store
        .append_event("session-1", 1001, thinking_event("second"))
        .unwrap();
    let replay = store.read_events_after("session-1", 1).unwrap();

    assert_eq!(first.event_id, 1);
    assert_eq!(second.event_id, 2);
    assert_eq!(replay.len(), 1);
    assert_eq!(replay[0].event_id, 2);
}

#[test]
fn alias_remap_persists_and_resolves_to_the_canonical_session_id() {
    let home_dir = unique_temp_dir("codepilot-home");
    let work_dir = unique_temp_dir("codepilot-work");
    fs::create_dir_all(&home_dir).unwrap();
    fs::create_dir_all(&work_dir).unwrap();

    let store = SessionEventLogStore::new(SessionEventLogStoreOptions {
        work_dir: work_dir.clone(),
        home_dir: Some(home_dir.clone()),
    });
    store
        .remap_session_alias("temp-session", "real-session")
        .unwrap();
    store
        .append_event("temp-session", 1000, thinking_event("mapped write"))
        .unwrap();

    assert_eq!(
        store.resolve_session_id("temp-session").unwrap(),
        "real-session"
    );

    let replay = store.read_events_after("temp-session", 0).unwrap();
    assert_eq!(replay.len(), 1);
    assert_eq!(replay[0].session_id, "real-session");
}

#[test]
fn prepare_live_session_detaches_a_reused_alias_from_previous_history() {
    let home_dir = unique_temp_dir("codepilot-home");
    let work_dir = unique_temp_dir("codepilot-work");
    fs::create_dir_all(&home_dir).unwrap();
    fs::create_dir_all(&work_dir).unwrap();

    let store = SessionEventLogStore::new(SessionEventLogStoreOptions {
        work_dir: work_dir.clone(),
        home_dir: Some(home_dir.clone()),
    });
    store
        .append_event("real-session", 1000, thinking_event("old"))
        .unwrap();
    store
        .remap_session_alias("temp-session", "real-session")
        .unwrap();

    store.prepare_live_session("temp-session").unwrap();
    store
        .append_event("temp-session", 1001, thinking_event("new"))
        .unwrap();

    assert_eq!(store.resolve_session_id("temp-session").unwrap(), "temp-session");

    let temp_replay = store.read_events_after("temp-session", 0).unwrap();
    assert_eq!(temp_replay.len(), 1);
    assert_eq!(temp_replay[0].session_id, "temp-session");
    assert_eq!(temp_replay[0].event, thinking_event("new"));

    let canonical_replay = store.read_events_after("real-session", 0).unwrap();
    assert_eq!(canonical_replay.len(), 1);
    assert_eq!(canonical_replay[0].session_id, "real-session");
    assert_eq!(canonical_replay[0].event, thinking_event("old"));
}
