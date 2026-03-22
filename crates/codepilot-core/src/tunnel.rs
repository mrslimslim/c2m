use crate::logger::LOG;
use regex::Regex;
use std::{
    fmt::{Display, Formatter},
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

#[derive(Debug)]
pub struct TunnelError(String);

impl TunnelError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl Display for TunnelError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for TunnelError {}

pub type Result<T> = std::result::Result<T, TunnelError>;

#[derive(Debug, Clone)]
pub struct StartTunnelOptions {
    pub path_override: Option<String>,
    pub timeout_ms: u64,
}

impl Default for StartTunnelOptions {
    fn default() -> Self {
        Self {
            path_override: None,
            timeout_ms: 30_000,
        }
    }
}

#[derive(Debug)]
pub struct TunnelHandle {
    pub url: String,
    pub ws_url: String,
    child: Arc<Mutex<Child>>,
}

impl TunnelHandle {
    pub fn stop(&self) -> Result<()> {
        self.child
            .lock()
            .map_err(|_| TunnelError::new("failed to acquire tunnel child lock"))?
            .kill()
            .map_err(|error| TunnelError::new(error.to_string()))
    }
}

pub fn start_tunnel(local_port: u16, options: StartTunnelOptions) -> Result<TunnelHandle> {
    let mut command = Command::new("cloudflared");
    command.args([
        "tunnel",
        "--url",
        &format!("http://localhost:{local_port}"),
        "--protocol",
        "http2",
    ]);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(path_override) = options.path_override.clone() {
        command.env("PATH", path_override);
    }

    let mut child = command.spawn().map_err(|error| {
        TunnelError::new(format!(
            "Failed to spawn cloudflared: {}. Is it installed? Run: brew install cloudflared",
            error
        ))
    })?;

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let child = Arc::new(Mutex::new(child));
    let (sender, receiver) = mpsc::channel::<String>();

    if let Some(stdout) = stdout {
        pipe_lines(stdout, sender.clone());
    }
    if let Some(stderr) = stderr {
        pipe_lines(stderr, sender.clone());
    }
    drop(sender);

    let deadline = Instant::now() + Duration::from_millis(options.timeout_ms);
    let url_regex =
        Regex::new(r#"(https://[a-zA-Z0-9-]+\.trycloudflare\.com/?)(?:[\s|"']|$)"#).unwrap();
    let mut buffer = String::new();

    loop {
        if Instant::now() >= deadline {
            let _ = child.lock().map(|mut process| process.kill());
            return Err(TunnelError::new(
                "Timed out waiting for cloudflared tunnel URL",
            ));
        }

        match receiver.recv_timeout(Duration::from_millis(100)) {
            Ok(line) => {
                if !line.trim().is_empty() {
                    LOG.info(&format!("[cloudflared] {}", line.trim()));
                }
                buffer.push_str(&line);
                buffer.push('\n');

                if let Some(captures) = url_regex.captures(&buffer) {
                    let https_url = captures
                        .get(1)
                        .map(|matched| matched.as_str().trim_end_matches('/').to_owned())
                        .unwrap_or_default();
                    let ws_url = https_url.replacen("https://", "wss://", 1);
                    return Ok(TunnelHandle {
                        url: https_url,
                        ws_url,
                        child,
                    });
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Ok(mut process) = child.lock() {
                    if let Some(status) = process
                        .try_wait()
                        .map_err(|error| TunnelError::new(error.to_string()))?
                    {
                        return Err(TunnelError::new(format!(
                            "cloudflared exited with code {} before establishing tunnel",
                            status.code().unwrap_or(-1)
                        )));
                    }
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let code = child
                    .lock()
                    .ok()
                    .and_then(|mut process| process.try_wait().ok().flatten())
                    .and_then(|status| status.code())
                    .unwrap_or(-1);
                return Err(TunnelError::new(format!(
                    "cloudflared exited with code {code} before establishing tunnel"
                )));
            }
        }
    }
}

fn pipe_lines<R>(reader: R, sender: mpsc::Sender<String>)
where
    R: std::io::Read + Send + 'static,
{
    thread::spawn(move || {
        for line in BufReader::new(reader)
            .lines()
            .map_while(|result| result.ok())
        {
            let _ = sender.send(line);
        }
    });
}
