use codepilot_protocol::messages::{
    BridgeMessage, EncryptedWireMessage, HandshakeOkMessage, PhoneMessage,
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;

fn assert_json_roundtrip<T>(raw: &str)
where
    T: DeserializeOwned + Serialize + PartialEq + std::fmt::Debug,
{
    let expected: Value = serde_json::from_str(raw).unwrap();
    let parsed: T = serde_json::from_str(raw).unwrap();
    let actual = serde_json::to_value(&parsed).unwrap();
    assert_eq!(actual, expected);
}

#[test]
fn handshake_ok_round_trips() {
    let raw = r#"{"type":"handshake_ok","encrypted":true,"clientId":"c1","capabilities":["session_replay_v1"]}"#;
    assert_json_roundtrip::<HandshakeOkMessage>(raw);
}

#[test]
fn phone_command_round_trips() {
    let raw = r#"{"type":"command","text":"ship it","sessionId":"s1","config":{"model":"gpt-5.4","modelReasoningEffort":"high","approvalPolicy":"on-request","sandboxMode":"workspace-write"}}"#;
    assert_json_roundtrip::<PhoneMessage>(raw);
}

#[test]
fn phone_sync_session_round_trips() {
    let raw = r#"{"type":"sync_session","sessionId":"s1","afterEventId":7}"#;
    assert_json_roundtrip::<PhoneMessage>(raw);
}

#[test]
fn bridge_event_round_trips() {
    let raw = r#"{"type":"event","sessionId":"s1","event":{"type":"command_exec","command":"cargo test","output":"ok","exitCode":0,"status":"done"},"eventId":8,"timestamp":1774060800000}"#;
    assert_json_roundtrip::<BridgeMessage>(raw);
}

#[test]
fn bridge_session_sync_complete_round_trips() {
    let raw = r#"{"type":"session_sync_complete","sessionId":"temp-session","latestEventId":14,"resolvedSessionId":"real-session"}"#;
    assert_json_roundtrip::<BridgeMessage>(raw);
}

#[test]
fn bridge_diff_content_round_trips() {
    let raw = r#"{"type":"diff_content","sessionId":"s1","eventId":9,"files":[{"path":"src/lib.rs","kind":"update","addedLines":3,"deletedLines":1,"isTruncated":false,"totalHunkCount":1,"loadedHunks":[{"oldStart":10,"oldLineCount":2,"newStart":10,"newLineCount":4,"lines":[{"kind":"context","text":" fn main() {"},{"kind":"delete","text":"-    old();"},{"kind":"add","text":"+    new();"},{"kind":"context","text":" }"}]}]}]}"#;
    assert_json_roundtrip::<BridgeMessage>(raw);
}

#[test]
fn bridge_slash_catalog_round_trips() {
    let raw = r#"{"type":"slash_catalog","capability":"slash_catalog_v1","adapter":"codex","adapterVersion":"codex-cli 0.116.0","catalogVersion":"2026-03-22","defaults":{"model":"gpt-5.4","modelReasoningEffort":"medium","approvalPolicy":"on-request","sandboxMode":"workspace-write"},"commands":[{"id":"model","label":"/model","description":"Set model","kind":"workflow","availability":"enabled","searchTerms":["model","reasoning"],"menu":{"title":"Select model","helperText":"Choose a model","presentation":"list","options":[{"id":"gpt-5.4","label":"GPT-5.4","description":"Default model","badges":["default","recommended"],"effects":[{"type":"set_session_config","field":"model","value":"gpt-5.4"}],"next":{"title":"Reasoning effort","presentation":"list","options":[{"id":"high","label":"High","effects":[{"type":"set_session_config","field":"modelReasoningEffort","value":"high"}]}]}}]}}]}"#;
    assert_json_roundtrip::<BridgeMessage>(raw);
}

#[test]
fn encrypted_wire_message_round_trips() {
    let raw = r#"{"v":1,"nonce":"bm9uY2U=","ciphertext":"Y2lwaGVydGV4dA==","tag":"dGFn"}"#;
    assert_json_roundtrip::<EncryptedWireMessage>(raw);
}
