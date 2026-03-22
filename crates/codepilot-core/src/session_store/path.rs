use sha2::{Digest, Sha256};
use std::{
    env, fs, io,
    path::{Path, PathBuf},
};

fn home_dir(home_dir: Option<&Path>) -> io::Result<PathBuf> {
    match home_dir {
        Some(path) => Ok(path.to_path_buf()),
        None => env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not set")),
    }
}

fn normalize_work_dir(work_dir: impl AsRef<Path>) -> PathBuf {
    fs::canonicalize(work_dir.as_ref()).unwrap_or_else(|_| work_dir.as_ref().to_path_buf())
}

pub fn default_session_store_root(
    work_dir: impl AsRef<Path>,
    home_dir_override: Option<&Path>,
) -> io::Result<PathBuf> {
    let normalized = normalize_work_dir(work_dir);
    let hash = hex::encode(Sha256::digest(normalized.to_string_lossy().as_bytes()));

    Ok(home_dir(home_dir_override)?
        .join(".codepilot")
        .join("sessions")
        .join(&hash[..16]))
}

pub fn default_session_index_path(
    work_dir: impl AsRef<Path>,
    home_dir_override: Option<&Path>,
) -> io::Result<PathBuf> {
    Ok(default_session_store_root(work_dir, home_dir_override)?.join("index.json"))
}

pub fn default_session_event_log_path(
    work_dir: impl AsRef<Path>,
    session_id: &str,
    home_dir_override: Option<&Path>,
) -> io::Result<PathBuf> {
    if session_id.contains('/') || session_id.contains('\\') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid session id for event log path: {session_id}"),
        ));
    }

    Ok(default_session_store_root(work_dir, home_dir_override)?
        .join("events")
        .join(format!("{session_id}.jsonl")))
}
