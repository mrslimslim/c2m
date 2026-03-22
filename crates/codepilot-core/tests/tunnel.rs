use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_core::tunnel::{StartTunnelOptions, start_tunnel};

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("{prefix}-{suffix}"))
}

#[test]
fn start_tunnel_rejects_when_cloudflared_only_logs_the_quick_tunnel_api_endpoint() {
    let root = unique_temp_dir("codepilot-cloudflared");
    fs::create_dir_all(&root).unwrap();
    let fake_cloudflared = root.join("cloudflared");
    fs::write(
        &fake_cloudflared,
        r#"#!/bin/sh
echo '[cloudflared] 2026-03-21T07:16:28Z INF Requesting new quick Tunnel on trycloudflare.com...' >&2
echo '[cloudflared] failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": EOF' >&2
exit 1
"#,
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&fake_cloudflared).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&fake_cloudflared, perms).unwrap();
    }

    let original_path = std::env::var("PATH").unwrap_or_default();
    let path = format!("{}:{}", root.display(), original_path);
    let err = start_tunnel(
        19260,
        StartTunnelOptions {
            path_override: Some(path),
            timeout_ms: 2_000,
        },
    )
    .unwrap_err();

    assert!(
        err.to_string()
            .contains("cloudflared exited with code 1 before establishing tunnel")
    );
}
