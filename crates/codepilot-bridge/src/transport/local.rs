use std::collections::HashMap;

use codepilot_core::pairing::{
    crypto::{decrypt, derive_session_key_from_raw, encrypt},
    state::PairingMaterial,
};
use codepilot_protocol::messages::{
    EncryptedWireMessage, HandshakeMessage, HandshakeOkMessage, HandshakeOkMessageType,
    PhoneMessage, SESSION_REPLAY_CAPABILITY, SLASH_CATALOG_CAPABILITY,
};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub enum LocalTransportOutcome {
    OutgoingText {
        client_id: String,
        payload: String,
    },
    IncomingPhoneMessage {
        client_id: String,
        message: PhoneMessage,
    },
    Connected {
        client_id: String,
    },
    Disconnected {
        client_id: String,
        reason: String,
    },
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
