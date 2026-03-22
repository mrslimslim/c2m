use std::path::PathBuf;

use codepilot_bridge::transport::local::{LocalTransport, LocalTransportOutcome};
use codepilot_core::pairing::{
    crypto::{decrypt, derive_session_key_from_raw, encrypt},
    state::PairingMaterial,
};
use codepilot_protocol::messages::{
    EncryptedWireMessage, HandshakeOkMessage, PhoneMessage, SESSION_REPLAY_CAPABILITY,
    SLASH_CATALOG_CAPABILITY,
};
use serde_json::json;

const BRIDGE_PRIVATE_KEY: &str = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=";
const BRIDGE_PUBLIC_KEY: &str = "E75P6uryBMf9M1j8nAByGIHRdCeBKCJ+xnTzf3/pe20=";
const PHONE_PUBLIC_KEY: &str = "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE=";
const OTP: &str = "a1b2c3";

fn fixture_pairing_material() -> PairingMaterial {
    PairingMaterial {
        private_key_base64: BRIDGE_PRIVATE_KEY.to_owned(),
        public_key_base64: BRIDGE_PUBLIC_KEY.to_owned(),
        otp: OTP.to_owned(),
        token: "token-123".to_owned(),
        state_path: PathBuf::from("/tmp/codepilot-pairing.json"),
    }
}

fn outgoing_payloads(outcomes: &[LocalTransportOutcome]) -> Vec<String> {
    outcomes
        .iter()
        .filter_map(|outcome| match outcome {
            LocalTransportOutcome::OutgoingText { payload, .. } => Some(payload.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn handshake_success_enables_encrypted_messages_only() {
    let mut transport = LocalTransport::new(fixture_pairing_material());
    transport.register_client("client-1");

    let handshake_outcomes = transport
        .receive_text(
            "client-1",
            &json!({
                "type": "handshake",
                "phone_pubkey": PHONE_PUBLIC_KEY,
                "otp": OTP,
            })
            .to_string(),
        )
        .unwrap();

    let handshake: HandshakeOkMessage =
        serde_json::from_str(&outgoing_payloads(&handshake_outcomes)[0]).unwrap();
    assert!(handshake.encrypted);
    assert_eq!(handshake.client_id.as_deref(), Some("client-1"));
    assert_eq!(
        handshake.capabilities.as_deref(),
        Some(
            &[
                SESSION_REPLAY_CAPABILITY.to_owned(),
                SLASH_CATALOG_CAPABILITY.to_owned(),
            ][..]
        )
    );

    let session_key =
        derive_session_key_from_raw(BRIDGE_PRIVATE_KEY, PHONE_PUBLIC_KEY, OTP).unwrap();

    let plaintext_outcomes = transport
        .receive_text("client-1", &json!({ "type": "ping", "ts": 1 }).to_string())
        .unwrap();
    let encrypted_error: EncryptedWireMessage =
        serde_json::from_str(&outgoing_payloads(&plaintext_outcomes)[0]).unwrap();
    let decrypted_error = decrypt(&session_key, &encrypted_error).unwrap();
    assert_eq!(
        decrypted_error,
        json!({
            "type": "error",
            "message": "Encrypted session requires encrypted messages",
        })
        .to_string()
    );

    let encrypted_ping = encrypt(
        &session_key,
        &json!({ "type": "ping", "ts": 2 }).to_string(),
    )
    .unwrap();
    let encrypted_outcomes = transport
        .receive_text("client-1", &serde_json::to_string(&encrypted_ping).unwrap())
        .unwrap();
    assert!(encrypted_outcomes.iter().any(|outcome| matches!(
        outcome,
        LocalTransportOutcome::IncomingPhoneMessage {
            client_id,
            message: PhoneMessage::Ping { ts: 2 },
        } if client_id == "client-1"
    )));
}

#[test]
fn handshake_rejects_invalid_otp() {
    let mut transport = LocalTransport::new(fixture_pairing_material());
    transport.register_client("client-otp");

    let outcomes = transport
        .receive_text(
            "client-otp",
            &json!({
                "type": "handshake",
                "phone_pubkey": PHONE_PUBLIC_KEY,
                "otp": "ffffff",
            })
            .to_string(),
        )
        .unwrap();

    assert_eq!(
        outgoing_payloads(&outcomes),
        vec![
            json!({
                "type": "auth_failed",
                "reason": "invalid_otp",
            })
            .to_string()
        ]
    );
    assert!(outcomes.iter().any(|outcome| matches!(
        outcome,
        LocalTransportOutcome::Disconnected { client_id, reason }
            if client_id == "client-otp" && reason == "OTP verification failed"
    )));
}
