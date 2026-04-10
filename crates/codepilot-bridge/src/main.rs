use std::{
    process::Command,
    sync::{Arc, Mutex},
};

use clap::Parser;
use codepilot_agents::{claude::ClaudeAdapter, codex::CodexAdapter, types::AgentAdapter};
use codepilot_bridge::{
    CliArgs,
    bridge::{Bridge, BridgeOptions, handle_runtime_message},
    transport::{
        local::{ConnectHandler, DisconnectHandler, LocalTransportServer, MessageHandler},
        types::TransportServer,
    },
};
use codepilot_core::{
    logger::LOG,
    pairing::{
        qrcode::render_pairing_qr,
        state::{PairingMaterialOptions, load_or_create_pairing_material},
    },
    slash::version::detect_adapter_version_with_default,
    tunnel::{StartTunnelOptions, start_tunnel},
};
use codepilot_protocol::state::AgentType;
use serde_json::{Value, json};

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let args = CliArgs::parse();
    if let Err(error) = run(args).await {
        LOG.error(&error);
        std::process::exit(1);
    }
}

async fn run(args: CliArgs) -> Result<(), String> {
    let work_dir = std::fs::canonicalize(&args.dir).unwrap_or(args.dir);

    println!();
    println!("  +======================================+");
    println!("  |   CTunnel Bridge v0.1.0               |");
    println!("  |   Mobile AI Coding Command Center     |");
    println!("  +======================================+");
    println!();

    let pairing_material = load_or_create_pairing_material(PairingMaterialOptions {
        file_path: None,
        work_dir: Some(work_dir.clone()),
    })
    .map_err(|error| error.to_string())?;

    let (agent_type, adapter): (AgentType, Arc<dyn AgentAdapter>) =
        resolve_adapter(args.agent.as_str())?;

    LOG.info(&format!("Working directory: {}", work_dir.display()));
    LOG.info(&format!(
        "Pairing state: {}",
        pairing_material.state_path.display()
    ));
    LOG.info(&format!(
        "Agent: {}",
        match agent_type {
            AgentType::Codex => "codex",
            AgentType::Claude => "claude",
        }
    ));

    let mut bridge = Bridge::new(BridgeOptions {
        agent: match agent_type {
            AgentType::Codex => "codex".to_owned(),
            AgentType::Claude => "claude".to_owned(),
        },
        port: 0,
        host: Some("127.0.0.1".to_owned()),
        work_dir: work_dir.clone(),
    });
    bridge.set_adapter(adapter);
    bridge.set_adapter_version(detect_adapter_version_with_default(agent_type));
    let bridge = Arc::new(Mutex::new(bridge));

    let connect_handler: ConnectHandler = {
        let bridge = bridge.clone();
        Arc::new(move |client| {
            if let Ok(mut bridge) = bridge.lock() {
                bridge.handle_client_connected(client);
            }
        })
    };
    let disconnect_handler: DisconnectHandler = {
        let bridge = bridge.clone();
        Arc::new(move |client_id| {
            if let Ok(mut bridge) = bridge.lock() {
                bridge.handle_client_disconnected(&client_id);
            }
        })
    };
    let message_handler: MessageHandler = {
        let bridge = bridge.clone();
        Arc::new(move |client, message| {
            handle_runtime_message(bridge.clone(), client, message);
        })
    };

    let (transport, start_result) = LocalTransportServer::start(
        "127.0.0.1".to_owned(),
        0,
        pairing_material.clone(),
        connect_handler,
        message_handler,
        disconnect_handler,
    )
    .await?;

    LOG.success(&format!(
        "WebSocket server listening on {}",
        start_result.listen_url
    ));

    let mut tunnel_handle = None;
    let pairing_payload = if args.tunnel {
        LOG.info("Starting Cloudflare Tunnel...");
        let tunnel = start_tunnel(start_result.listen_port, StartTunnelOptions::default())
            .map_err(|error| error.to_string())?;
        LOG.success(&format!("Tunnel URL: {}", tunnel.url));
        let host = tunnel.url.trim_start_matches("https://").to_owned();
        let payload = override_pairing_endpoint(&start_result.pairing_payload, &host, 443, true);
        tunnel_handle = Some(tunnel);
        payload
    } else {
        start_result.pairing_payload.clone()
    };

    LOG.info("Scan this QR code with your phone to connect:");
    print_pairing_qr(&pairing_payload);
    LOG.info(&format!("Pairing payload: {}", pairing_payload));

    LOG.info("Waiting for phone connection...");
    tokio::signal::ctrl_c()
        .await
        .map_err(|error| error.to_string())?;
    LOG.info("Shutting down...");
    transport.stop();
    if let Some(tunnel) = tunnel_handle {
        let _ = tunnel.stop();
    }

    Ok(())
}

fn resolve_adapter(agent: &str) -> Result<(AgentType, Arc<dyn AgentAdapter>), String> {
    match agent {
        "codex" => Ok((AgentType::Codex, Arc::new(CodexAdapter::new()))),
        "claude" => Ok((AgentType::Claude, Arc::new(ClaudeAdapter::new()))),
        "auto" => {
            if command_available("codex") {
                Ok((AgentType::Codex, Arc::new(CodexAdapter::new())))
            } else if command_available("claude") {
                Ok((AgentType::Claude, Arc::new(ClaudeAdapter::new())))
            } else {
                Err("Neither codex nor claude is available on PATH".to_owned())
            }
        }
        other => Err(format!("Unsupported agent: {other}")),
    }
}

fn command_available(command: &str) -> bool {
    Command::new(command).arg("--version").output().is_ok()
}

fn override_pairing_endpoint(payload: &Value, host: &str, port: u16, tunnel: bool) -> Value {
    let mut payload = payload.as_object().cloned().unwrap_or_default();
    payload.insert("host".to_owned(), json!(host));
    payload.insert("port".to_owned(), json!(port));
    if tunnel {
        payload.insert("tunnel".to_owned(), json!(true));
    }
    Value::Object(payload)
}

fn print_pairing_qr(payload: &Value) {
    let raw = payload.to_string();
    match render_pairing_qr(&raw) {
        Ok(qr) => {
            println!();
            println!("{qr}");
            println!();
        }
        Err(error) => {
            LOG.warn(&format!("Failed to render pairing QR code: {error}"));
        }
    }
}
