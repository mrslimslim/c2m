use codepilot_protocol::messages::HandshakeOkMessage;

#[test]
fn handshake_ok_round_trips() {
    let raw = r#"{"type":"handshake_ok","encrypted":true,"clientId":"c1"}"#;
    let msg: HandshakeOkMessage = serde_json::from_str(raw).unwrap();
    assert!(msg.encrypted);
    assert_eq!(msg.client_id.as_deref(), Some("c1"));
}
