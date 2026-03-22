use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_core::security::{is_sensitive_relative_path, validate_file_request_path};

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("{prefix}-{suffix}"))
}

#[test]
fn sensitive_paths_are_rejected() {
    for path in [
        ".env",
        ".env.local",
        ".git/config",
        ".ssh/id_rsa",
        "credentials.json",
        "server.pem",
        "private.key",
    ] {
        assert!(is_sensitive_relative_path(path), "{path} should be blocked");
    }
}

#[test]
fn safe_project_paths_are_allowed() {
    for path in ["src/index.ts", "package.json", "docs/setup.md"] {
        assert!(
            !is_sensitive_relative_path(path),
            "{path} should not be blocked"
        );
    }
}

#[test]
fn validate_file_request_path_rejects_traversal_and_escape() {
    let root = unique_temp_dir("codepilot-security");
    let work_dir = root.join("work");
    fs::create_dir_all(work_dir.join("src")).unwrap();
    fs::write(work_dir.join("src/index.ts"), "console.log('ok');").unwrap();

    assert!(validate_file_request_path(&work_dir, "src/index.ts").is_ok());
    assert!(validate_file_request_path(&work_dir, "../../etc/passwd").is_err());
    assert!(validate_file_request_path(&work_dir, "/etc/passwd").is_err());
    assert!(validate_file_request_path(&work_dir, ".env").is_err());
}
