use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_core::{
    diff::service::{DiffService, DiffServiceOptions},
    session_store::event_log::{SessionEventLogStore, SessionEventLogStoreOptions},
};
use codepilot_protocol::{
    events::AgentEvent,
    state::{FileChange, FileChangeKind},
};

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("{prefix}-{suffix}"))
}

#[test]
fn diff_service_returns_first_hunk_initially_and_paginates_subsequent_hunks() {
    let home_dir = unique_temp_dir("codepilot-home");
    let work_dir = unique_temp_dir("codepilot-work");
    std::fs::create_dir_all(&home_dir).unwrap();
    std::fs::create_dir_all(&work_dir).unwrap();

    let store = SessionEventLogStore::new(SessionEventLogStoreOptions {
        work_dir: work_dir.clone(),
        home_dir: Some(home_dir),
    });

    store
        .append_event(
            "session-1",
            1000,
            AgentEvent::CodeChange {
                changes: vec![FileChange {
                    path: "Sources/App.swift".to_owned(),
                    kind: FileChangeKind::Update,
                }],
            },
        )
        .unwrap();

    let load_count = Arc::new(AtomicUsize::new(0));
    let load_counter = Arc::clone(&load_count);
    let service = DiffService::new(DiffServiceOptions {
        work_dir: work_dir.clone(),
        event_store: Arc::new(store),
        cache_ttl_ms: 15_000,
        hunk_page_size: 1,
        load_diff_text: Arc::new(move |_| {
            load_counter.fetch_add(1, Ordering::SeqCst);
            Ok([
                "diff --git a/Sources/App.swift b/Sources/App.swift",
                "index 1111111..2222222 100644",
                "--- a/Sources/App.swift",
                "+++ b/Sources/App.swift",
                "@@ -1,2 +1,3 @@",
                " import Foundation",
                "-let value = 1",
                "+let value = 2",
                "+let label = \"ok\"",
                "@@ -10,1 +11,2 @@",
                " func run() {}",
                "+print(value)",
            ]
            .join("\n"))
        }),
        now: Arc::new(|| 1_000),
    });

    let initial = service.load_diff("session-1", 1).unwrap();
    assert_eq!(load_count.load(Ordering::SeqCst), 1);
    assert_eq!(initial.files.len(), 1);
    assert_eq!(initial.files[0].loaded_hunks.len(), 1);
    assert_eq!(initial.files[0].total_hunk_count, 2);
    assert_eq!(initial.files[0].next_hunk_index, Some(1));

    let next = service
        .load_more_hunks("session-1", 1, "Sources/App.swift", 1)
        .unwrap();
    assert_eq!(load_count.load(Ordering::SeqCst), 1);
    assert_eq!(next.hunks.len(), 1);
    assert_eq!(next.next_hunk_index, None);
    assert_eq!(next.hunks[0].lines[1].text, "+print(value)");
}

#[test]
fn diff_service_rejects_non_code_change_events() {
    let home_dir = unique_temp_dir("codepilot-home");
    let work_dir = unique_temp_dir("codepilot-work");
    std::fs::create_dir_all(&home_dir).unwrap();
    std::fs::create_dir_all(&work_dir).unwrap();

    let store = SessionEventLogStore::new(SessionEventLogStoreOptions {
        work_dir: work_dir.clone(),
        home_dir: Some(home_dir),
    });

    store
        .append_event(
            "session-1",
            1000,
            AgentEvent::Status {
                state: codepilot_protocol::state::AgentState::Thinking,
                message: "working".to_owned(),
            },
        )
        .unwrap();

    let service = DiffService::new(DiffServiceOptions {
        work_dir: work_dir.clone(),
        event_store: Arc::new(store),
        cache_ttl_ms: 15_000,
        hunk_page_size: 1,
        load_diff_text: Arc::new(|_| Ok(String::new())),
        now: Arc::new(|| 1_000),
    });

    assert!(
        service
            .load_diff("session-1", 1)
            .unwrap_err()
            .to_string()
            .contains("not a code_change event")
    );
}
