use std::{
    fs, io,
    path::{Component, Path, PathBuf},
};

fn file_name(path: &str) -> Option<&str> {
    Path::new(path).file_name().and_then(|name| name.to_str())
}

pub fn is_sensitive_relative_path(path: &str) -> bool {
    if path == ".env" || path.starts_with(".env.") {
        return true;
    }

    if path == ".git/config" || path == ".git/credentials" {
        return true;
    }

    if path.starts_with(".ssh/") {
        return true;
    }

    if path == ".npmrc" {
        return true;
    }

    if file_name(path) == Some("credentials.json") {
        return true;
    }

    if let Some(name) = file_name(path) {
        if name.ends_with(".pem") || name.ends_with(".key") {
            return true;
        }

        if let Some((stem, ext)) = name.rsplit_once('.') {
            let ext_matches = matches!(ext, "json" | "yaml" | "yml" | "toml");
            if ext_matches && (stem == "secret" || stem == "secrets") {
                return true;
            }
        }
    }

    false
}

fn contains_traversal(path: &Path) -> bool {
    path.components()
        .any(|component| matches!(component, Component::ParentDir))
}

pub fn validate_file_request_path(
    work_dir: impl AsRef<Path>,
    file_path: impl AsRef<Path>,
) -> io::Result<PathBuf> {
    let work_dir = fs::canonicalize(work_dir.as_ref())?;
    let relative = file_path.as_ref();

    if relative.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "absolute paths are not allowed",
        ));
    }

    if contains_traversal(relative) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "path traversal is not allowed",
        ));
    }

    let relative_text = relative.to_string_lossy();
    if is_sensitive_relative_path(&relative_text) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "access denied to sensitive path",
        ));
    }

    let candidate = work_dir.join(relative);
    let resolved = match fs::canonicalize(&candidate) {
        Ok(path) => path,
        Err(err) if err.kind() == io::ErrorKind::NotFound => candidate,
        Err(err) => return Err(err),
    };

    if resolved == work_dir || resolved.starts_with(&work_dir) {
        return Ok(resolved);
    }

    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        "path resolves outside the working directory",
    ))
}
