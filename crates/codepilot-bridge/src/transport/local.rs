use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

use codepilot_core::pairing::{
    crypto::{decrypt, derive_session_key_from_raw, encrypt},
    state::PairingMaterial,
};
use codepilot_protocol::messages::{
    BridgeMessage, EncryptedWireMessage, HandshakeMessage, HandshakeOkMessage,
    HandshakeOkMessageType, PhoneMessage, SESSION_REPLAY_CAPABILITY, SLASH_CATALOG_CAPABILITY,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::{
    net::TcpListener,
    sync::mpsc,
    task::JoinHandle,
};
use tokio_tungstenite::{accept_async, tungstenite::protocol::Message};

use crate::transport::types::{TransportClient, TransportServer};

#[derive(Debug, Clone, PartialEq)]
pub enum LocalTransportOutcome {
    OutgoingText { client_id: String, payload: String },
    IncomingPhoneMessage { client_id: String, message: PhoneMessage },
    Connected { client_id: String },
    Disconnected { client_id: String, reason: String },
}

#[derive(Debug, Clone, Default)]
struct ClientState {
    encrypted_session_key: Option<[u8; 32]>,
}

pub fn validate_phone_message(value: Value) -> Option<PhoneMessage> {
    let message: PhoneMessage = serde_json::from_value(value).ok()?;

    match &message {
        PhoneMessage::Command { text, .. } if text.is_empty() => None,
        PhoneMessage::SlashAction { command_id, .. } if command_id.is_empty() => None,
        _ => Some(message),
    }
}

pub struct LocalTransport {
    pairing_material: PairingMaterial,
    clients: HashMap<String, ClientState>,
}

impl LocalTransport {
    pub fn new(pairing_material: PairingMaterial) -> Self {
        Self {
            pairing_material,
            clients: HashMap::new(),
        }
    }

    pub fn register_client(&mut self, client_id: &str) {
        self.clients.entry(client_id.to_owned()).or_default();
    }

    pub fn receive_text(
        &mut self,
        client_id: &str,
        raw: &str,
    ) -> Result<Vec<LocalTransportOutcome>, String> {
        let Some(client) = self.clients.get_mut(client_id) else {
            return Err(format!("unknown client: {client_id}"));
        };

        if let Some(session_key) = client.encrypted_session_key {
            let encrypted = serde_json::from_str::<EncryptedWireMessage>(raw).ok();
            let Some(encrypted) = encrypted else {
                return Ok(vec![self.outgoing_encrypted_error(
                    client_id,
                    &session_key,
                    "Encrypted session requires encrypted messages",
                )?]);
            };

            let decrypted = decrypt(&session_key, &encrypted).map_err(|error| error.to_string())?;
            let value: Value =
                serde_json::from_str(&decrypted).map_err(|error| error.to_string())?;
            let Some(message) = validate_phone_message(value) else {
                return Ok(vec![self.outgoing_encrypted_error(
                    client_id,
                    &session_key,
                    "Invalid message format",
                )?]);
            };

            return Ok(vec![LocalTransportOutcome::IncomingPhoneMessage {
                client_id: client_id.to_owned(),
                message,
            }]);
        }

        let value: Value = serde_json::from_str(raw).map_err(|error| error.to_string())?;
        let handshake: HandshakeMessage = match serde_json::from_value(value.clone()) {
            Ok(message) => message,
            Err(_) => {
                return Ok(vec![LocalTransportOutcome::OutgoingText {
                    client_id: client_id.to_owned(),
                    payload: serde_json::json!({ "type": "auth_failed" }).to_string(),
                }]);
            }
        };

        if handshake.otp != self.pairing_material.otp {
            self.clients.remove(client_id);
            return Ok(vec![
                LocalTransportOutcome::OutgoingText {
                    client_id: client_id.to_owned(),
                    payload: serde_json::json!({
                        "type": "auth_failed",
                        "reason": "invalid_otp",
                    })
                    .to_string(),
                },
                LocalTransportOutcome::Disconnected {
                    client_id: client_id.to_owned(),
                    reason: "OTP verification failed".to_owned(),
                },
            ]);
        }

        let session_key = derive_session_key_from_raw(
            &self.pairing_material.private_key_base64,
            &handshake.phone_pubkey,
            &handshake.otp,
        )
        .map_err(|error| error.to_string())?;
        client.encrypted_session_key = Some(session_key);

        let handshake_ok = HandshakeOkMessage {
            message_type: HandshakeOkMessageType::HandshakeOk,
            encrypted: true,
            client_id: Some(client_id.to_owned()),
            capabilities: Some(vec![
                SESSION_REPLAY_CAPABILITY.to_owned(),
                SLASH_CATALOG_CAPABILITY.to_owned(),
            ]),
        };

        Ok(vec![
            LocalTransportOutcome::OutgoingText {
                client_id: client_id.to_owned(),
                payload: serde_json::to_string(&handshake_ok).map_err(|error| error.to_string())?,
            },
            LocalTransportOutcome::Connected {
                client_id: client_id.to_owned(),
            },
        ])
    }

    fn outgoing_encrypted_error(
        &self,
        client_id: &str,
        session_key: &[u8; 32],
        message: &str,
    ) -> Result<LocalTransportOutcome, String> {
        let payload = serde_json::json!({
            "type": "error",
            "message": message,
        })
        .to_string();
        let encrypted = encrypt(session_key, &payload).map_err(|error| error.to_string())?;
        Ok(LocalTransportOutcome::OutgoingText {
            client_id: client_id.to_owned(),
            payload: serde_json::to_string(&encrypted).map_err(|error| error.to_string())?,
        })
    }
}

pub type ConnectHandler = Arc<dyn Fn(Arc<dyn TransportClient>) + Send + Sync>;
pub type MessageHandler = Arc<dyn Fn(Arc<dyn TransportClient>, PhoneMessage) + Send + Sync>;
pub type DisconnectHandler = Arc<dyn Fn(String) + Send + Sync>;

#[derive(Debug, Clone)]
struct RuntimeCryptoState {
    authenticated: bool,
    encrypted_session_key: Option<[u8; 32]>,
}

#[derive(Clone)]
struct RuntimeTransportClient {
    id: String,
    sender: mpsc::UnboundedSender<String>,
    crypto_state: Arc<Mutex<RuntimeCryptoState>>,
}

impl RuntimeTransportClient {
    fn send_text(&self, payload: String) {
        let _ = self.sender.send(payload);
    }

    fn send_plain_json(&self, value: Value) {
        self.send_text(value.to_string());
    }

    fn send_error_message(&self, message: &str) {
        self.send(BridgeMessage::Error {
            message: message.to_owned(),
        });
    }
}

impl TransportClient for RuntimeTransportClient {
    fn id(&self) -> &str {
        &self.id
    }

    fn send(&self, message: BridgeMessage) {
        let Ok(payload) = serde_json::to_string(&message) else {
            return;
        };

        let session_key = self
            .crypto_state
            .lock()
            .ok()
            .and_then(|state| state.encrypted_session_key);

        if let Some(session_key) = session_key {
            if let Ok(encrypted) = encrypt(&session_key, &payload) {
                if let Ok(raw) = serde_json::to_string(&encrypted) {
                    self.send_text(raw);
                    return;
                }
            }
        }

        self.send_text(payload);
    }
}

struct ServerState {
    connect_handler: ConnectHandler,
    disconnect_handler: DisconnectHandler,
    message_handler: MessageHandler,
    next_client_id: AtomicU64,
    pairing_material: PairingMaterial,
}

pub struct LocalTransportStartResult {
    pub listen_port: u16,
    pub listen_url: String,
    pub pairing_payload: Value,
}

pub struct LocalTransportServerHandle {
    accept_task: JoinHandle<()>,
}

impl TransportServer for LocalTransportServerHandle {
    fn stop(&self) {
        self.accept_task.abort();
    }
}

pub struct LocalTransportServer;

impl LocalTransportServer {
    pub async fn start(
        host: String,
        port: u16,
        pairing_material: PairingMaterial,
        connect_handler: ConnectHandler,
        message_handler: MessageHandler,
        disconnect_handler: DisconnectHandler,
    ) -> Result<(LocalTransportServerHandle, LocalTransportStartResult), String> {
        let bind_host = normalize_host(&host);
        let listener = TcpListener::bind((bind_host.as_str(), port))
            .await
            .map_err(|error| error.to_string())?;
        let local_addr = listener.local_addr().map_err(|error| error.to_string())?;
        let listen_port = local_addr.port();
        let listen_host = if bind_host == "0.0.0.0" {
            "127.0.0.1".to_owned()
        } else {
            bind_host.clone()
        };
        let host_for_url = if listen_host.contains(':') {
            format!("[{listen_host}]")
        } else {
            listen_host.clone()
        };
        let listen_url = format!("ws://{host_for_url}:{listen_port}");

        let state = Arc::new(ServerState {
            connect_handler,
            disconnect_handler,
            message_handler,
            next_client_id: AtomicU64::new(1),
            pairing_material: pairing_material.clone(),
        });

        let accept_state = state.clone();
        let accept_task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let connection_state = accept_state.clone();
                tokio::spawn(async move {
                    let _ = handle_connection(stream, connection_state).await;
                });
            }
        });

        let pairing_payload = json!({
            "host": listen_host,
            "port": listen_port,
            "token": pairing_material.token,
            "bridge_pubkey": pairing_material.public_key_base64,
            "otp": pairing_material.otp,
            "protocol": "codepilot-v1-e2e",
        });

        Ok((
            LocalTransportServerHandle { accept_task },
            LocalTransportStartResult {
                listen_port,
                listen_url,
                pairing_payload,
            },
        ))
    }
}

async fn handle_connection(
    stream: tokio::net::TcpStream,
    state: Arc<ServerState>,
) -> Result<(), String> {
    let websocket = accept_async(stream).await.map_err(|error| error.to_string())?;
    let (mut write, mut read) = websocket.split();
    let (sender, mut receiver) = mpsc::unbounded_channel::<String>();

    let client_id = format!(
        "client-{}",
        state.next_client_id.fetch_add(1, Ordering::Relaxed)
    );
    let crypto_state = Arc::new(Mutex::new(RuntimeCryptoState {
        authenticated: false,
        encrypted_session_key: None,
    }));
    let client = Arc::new(RuntimeTransportClient {
        id: client_id.clone(),
        sender,
        crypto_state,
    });

    let writer = tokio::spawn(async move {
        while let Some(payload) = receiver.recv().await {
            if write.send(Message::Text(payload.into())).await.is_err() {
                break;
            }
        }
    });

    let mut notified_connected = false;
    while let Some(message) = read.next().await {
        let message = message.map_err(|error| error.to_string())?;
        let raw = match message {
            Message::Text(text) => text.to_string(),
            Message::Binary(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            Message::Close(_) => break,
            _ => continue,
        };

        let is_authenticated = client
            .crypto_state
            .lock()
            .map(|state| state.authenticated)
            .unwrap_or(false);

        if is_authenticated {
            handle_authenticated_message(&client, &state, &raw)?;
            continue;
        }

        if handle_initial_message(&client, &state, &raw)? {
            notified_connected = true;
        }
    }

    writer.abort();
    if notified_connected {
        (state.disconnect_handler)(client_id);
    }
    Ok(())
}

fn handle_initial_message(
    client: &Arc<RuntimeTransportClient>,
    state: &Arc<ServerState>,
    raw: &str,
) -> Result<bool, String> {
    let value: Value = serde_json::from_str(raw).map_err(|error| error.to_string())?;

    if let Ok(handshake) = serde_json::from_value::<HandshakeMessage>(value.clone()) {
        if handshake.otp != state.pairing_material.otp {
            client.send_plain_json(json!({
                "type": "auth_failed",
                "reason": "invalid_otp",
            }));
            return Ok(false);
        }

        let session_key = derive_session_key_from_raw(
            &state.pairing_material.private_key_base64,
            &handshake.phone_pubkey,
            &handshake.otp,
        )
        .map_err(|error| error.to_string())?;

        if let Ok(mut crypto_state) = client.crypto_state.lock() {
            crypto_state.authenticated = true;
            crypto_state.encrypted_session_key = Some(session_key);
        }

        let handshake_ok = HandshakeOkMessage {
            message_type: HandshakeOkMessageType::HandshakeOk,
            encrypted: true,
            client_id: Some(client.id.clone()),
            capabilities: Some(vec![
                SESSION_REPLAY_CAPABILITY.to_owned(),
                SLASH_CATALOG_CAPABILITY.to_owned(),
            ]),
        };
        client.send_text(
            serde_json::to_string(&handshake_ok).map_err(|error| error.to_string())?,
        );
        (state.connect_handler)(client.clone());
        return Ok(true);
    }

    let is_legacy_auth = value.get("type").and_then(Value::as_str) == Some("auth")
        && value.get("token").and_then(Value::as_str) == Some(state.pairing_material.token.as_str());
    if is_legacy_auth {
        if let Ok(mut crypto_state) = client.crypto_state.lock() {
            crypto_state.authenticated = true;
            crypto_state.encrypted_session_key = None;
        }
        client.send_plain_json(json!({
            "type": "auth_ok",
            "clientId": client.id,
        }));
        (state.connect_handler)(client.clone());
        return Ok(true);
    }

    client.send_plain_json(json!({ "type": "auth_failed" }));
    Ok(false)
}

fn handle_authenticated_message(
    client: &Arc<RuntimeTransportClient>,
    state: &Arc<ServerState>,
    raw: &str,
) -> Result<(), String> {
    let session_key = client
        .crypto_state
        .lock()
        .ok()
        .and_then(|state| state.encrypted_session_key);

    let value = if let Some(session_key) = session_key {
        let encrypted =
            serde_json::from_str::<EncryptedWireMessage>(raw).map_err(|error| error.to_string())?;
        let decrypted = decrypt(&session_key, &encrypted).map_err(|error| error.to_string())?;
        serde_json::from_str::<Value>(&decrypted).map_err(|error| error.to_string())?
    } else {
        serde_json::from_str::<Value>(raw).map_err(|error| error.to_string())?
    };

    let Some(message) = validate_phone_message(value) else {
        client.send_error_message("Invalid message format");
        return Ok(());
    };

    (state.message_handler)(client.clone(), message);
    Ok(())
}

fn normalize_host(host: &str) -> String {
    let trimmed = host.trim();
    if trimmed.is_empty() {
        return "127.0.0.1".to_owned();
    }

    trimmed.trim_start_matches('[').trim_end_matches(']').to_owned()
}
