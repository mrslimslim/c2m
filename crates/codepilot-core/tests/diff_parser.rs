use codepilot_core::diff::parser::parse_unified_diff;
use codepilot_protocol::state::{DiffLineKind, FileChange, FileChangeKind};

#[test]
fn parse_unified_diff_normalizes_a_multi_hunk_single_file_diff() {
    let diff_text = [
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
    .join("\n");

    let files = parse_unified_diff(
        &diff_text,
        &[FileChange {
            path: "Sources/App.swift".to_owned(),
            kind: FileChangeKind::Update,
        }],
    );

    assert_eq!(files.len(), 1);
    let file = &files[0];
    assert_eq!(file.path, "Sources/App.swift");
    assert_eq!(file.kind, FileChangeKind::Update);
    assert_eq!(file.added_lines, Some(3));
    assert_eq!(file.deleted_lines, Some(1));
    assert_eq!(file.hunks.len(), 2);
    assert_eq!(
        file.hunks[0]
            .lines
            .iter()
            .map(|line| line.kind)
            .collect::<Vec<_>>(),
        vec![
            DiffLineKind::Context,
            DiffLineKind::Delete,
            DiffLineKind::Add,
            DiffLineKind::Add,
        ]
    );
}

#[test]
fn parse_unified_diff_preserves_dev_null_additions_as_add_file_changes() {
    let diff_text = [
        "diff --git a/NewFile.swift b/NewFile.swift",
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/NewFile.swift",
        "@@ -0,0 +1,2 @@",
        "+struct NewFile {}",
        "+",
    ]
    .join("\n");

    let files = parse_unified_diff(
        &diff_text,
        &[FileChange {
            path: "NewFile.swift".to_owned(),
            kind: FileChangeKind::Add,
        }],
    );

    assert_eq!(files.len(), 1);
    let file = &files[0];
    assert_eq!(file.path, "NewFile.swift");
    assert_eq!(file.kind, FileChangeKind::Add);
    assert_eq!(file.added_lines, Some(2));
    assert_eq!(file.deleted_lines, Some(0));
}
