use codepilot_protocol::state::{
    DiffFile, DiffHunk, DiffLine, DiffLineKind, FileChange, FileChangeKind,
};
use regex::Regex;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedDiffFile {
    pub path: String,
    pub kind: FileChangeKind,
    pub added_lines: Option<u64>,
    pub deleted_lines: Option<u64>,
    pub is_truncated: bool,
    pub truncation_reason: Option<String>,
    pub total_hunk_count: u64,
    pub hunks: Vec<DiffHunk>,
}

impl ParsedDiffFile {
    pub fn to_initial_diff_file(&self, hunk_page_size: usize) -> DiffFile {
        let loaded_hunks = self
            .hunks
            .iter()
            .take(hunk_page_size)
            .cloned()
            .collect::<Vec<_>>();
        let next_hunk_index = if loaded_hunks.len() < self.hunks.len() {
            Some(loaded_hunks.len() as u64)
        } else {
            None
        };

        DiffFile {
            path: self.path.clone(),
            kind: self.kind,
            added_lines: self.added_lines,
            deleted_lines: self.deleted_lines,
            is_truncated: self.is_truncated,
            truncation_reason: self.truncation_reason.clone(),
            total_hunk_count: self.total_hunk_count,
            loaded_hunks,
            next_hunk_index,
        }
    }
}

pub fn parse_unified_diff(diff_text: &str, change_hints: &[FileChange]) -> Vec<ParsedDiffFile> {
    if diff_text.trim().is_empty() {
        return Vec::new();
    }

    let hunk_header = Regex::new(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@").unwrap();
    let lines = diff_text.lines().collect::<Vec<_>>();
    let mut files = Vec::new();
    let mut index = 0;

    while index < lines.len() {
        let line = lines[index];
        if !line.starts_with("diff --git ") {
            index += 1;
            continue;
        }

        let hint = change_hints.get(files.len());
        let diff_git_match = Regex::new(r"^diff --git a/(.+?) b/(.+)$").unwrap();
        let captures = diff_git_match.captures(line);
        let mut path = hint
            .map(|entry| entry.path.clone())
            .or_else(|| {
                captures
                    .as_ref()
                    .and_then(|caps| caps.get(2).map(|m| m.as_str().to_owned()))
            })
            .or_else(|| {
                captures
                    .as_ref()
                    .and_then(|caps| caps.get(1).map(|m| m.as_str().to_owned()))
            })
            .unwrap_or_default();
        let mut kind = hint
            .map(|entry| entry.kind)
            .unwrap_or(FileChangeKind::Update);
        let mut hunks = Vec::new();
        let mut added_lines = 0_u64;
        let mut deleted_lines = 0_u64;

        index += 1;
        while index < lines.len() {
            let current = lines[index];
            if current.starts_with("diff --git ") {
                break;
            }
            if current.starts_with("new file mode ") {
                kind = FileChangeKind::Add;
                index += 1;
                continue;
            }
            if current.starts_with("deleted file mode ") {
                kind = FileChangeKind::Delete;
                index += 1;
                continue;
            }
            if let Some(raw) = current.strip_prefix("+++ ") {
                if hint.is_none() {
                    let normalized = normalize_diff_path(raw);
                    if !normalized.is_empty() {
                        path = normalized;
                    }
                }
                index += 1;
                continue;
            }
            if current.starts_with("--- ") {
                index += 1;
                continue;
            }

            let Some(captures) = hunk_header.captures(current) else {
                index += 1;
                continue;
            };

            let old_start = captures
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("0")
                .parse()
                .unwrap_or(0);
            let old_line_count = captures
                .get(2)
                .map(|m| m.as_str())
                .unwrap_or("1")
                .parse()
                .unwrap_or(1);
            let new_start = captures
                .get(3)
                .map(|m| m.as_str())
                .unwrap_or("0")
                .parse()
                .unwrap_or(0);
            let new_line_count = captures
                .get(4)
                .map(|m| m.as_str())
                .unwrap_or("1")
                .parse()
                .unwrap_or(1);
            let mut hunk_lines = Vec::new();

            index += 1;
            while index < lines.len() {
                let hunk_line = lines[index];
                if hunk_line.starts_with("diff --git ") || hunk_line.starts_with("@@ ") {
                    break;
                }
                if hunk_line == "\\ No newline at end of file" {
                    index += 1;
                    continue;
                }

                let prefix = hunk_line.chars().next().unwrap_or(' ');
                let text = if hunk_line.is_empty() {
                    " ".to_owned()
                } else {
                    hunk_line.to_owned()
                };
                match prefix {
                    '+' => {
                        hunk_lines.push(DiffLine {
                            kind: DiffLineKind::Add,
                            text,
                        });
                        added_lines += 1;
                    }
                    '-' => {
                        hunk_lines.push(DiffLine {
                            kind: DiffLineKind::Delete,
                            text,
                        });
                        deleted_lines += 1;
                    }
                    _ => hunk_lines.push(DiffLine {
                        kind: DiffLineKind::Context,
                        text,
                    }),
                }
                index += 1;
            }

            hunks.push(DiffHunk {
                old_start,
                old_line_count,
                new_start,
                new_line_count,
                lines: hunk_lines,
            });
        }

        files.push(ParsedDiffFile {
            path,
            kind,
            added_lines: Some(added_lines),
            deleted_lines: Some(deleted_lines),
            is_truncated: false,
            truncation_reason: None,
            total_hunk_count: hunks.len() as u64,
            hunks,
        });
    }

    files
}

fn normalize_diff_path(raw_path: &str) -> String {
    if raw_path == "/dev/null" {
        return String::new();
    }
    if raw_path.starts_with("a/") || raw_path.starts_with("b/") {
        return raw_path[2..].to_owned();
    }
    raw_path.to_owned()
}
