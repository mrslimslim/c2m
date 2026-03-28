use codepilot_bridge::transport::local::validate_phone_message;
use codepilot_protocol::messages::PhoneMessage;
use serde_json::json;

#[test]
fn validate_phone_message_accepts_supported_phone_messages() {
    assert_eq!(
        validate_phone_message(json!({
            "type": "command",
            "text": "ship it",
            "sessionId": "session-1",
        })),
        Some(PhoneMessage::Command {
            text: "ship it".to_owned(),
            session_id: Some("session-1".to_owned()),
            config: None,
        })
    );

    assert_eq!(
        validate_phone_message(json!({
            "type": "diff_hunks_req",
            "sessionId": "session-1",
            "eventId": 42,
            "path": "Sources/App.swift",
            "afterHunkIndex": 1,
        })),
        Some(PhoneMessage::DiffHunksReq {
            session_id: "session-1".to_owned(),
            event_id: 42,
            path: "Sources/App.swift".to_owned(),
            after_hunk_index: 1,
        })
    );

    assert_eq!(
        validate_phone_message(json!({
            "type": "slash_action",
            "sessionId": "session-1",
            "commandId": "review",
            "arguments": {
                "depth": "full",
                "apply": false,
            }
        }))
        .map(|message| matches!(message, PhoneMessage::SlashAction { .. })),
        Some(true)
    );
}

#[test]
fn validate_phone_message_accepts_file_search_requests() {
    assert_eq!(
        validate_phone_message(json!({
            "type": "file_search_req",
            "sessionId": "session-1",
            "query": "turnview",
            "limit": 12,
        }))
        .map(|message| matches!(message, PhoneMessage::FileSearchReq { .. })),
        Some(true)
    );
}

#[test]
fn validate_phone_message_rejects_unknown_or_malformed_messages() {
    assert_eq!(
        validate_phone_message(json!({
            "type": "command",
            "text": "",
        })),
        None
    );
    assert_eq!(
        validate_phone_message(json!({
            "type": "sync_session",
            "sessionId": "session-1",
            "afterEventId": "oops",
        })),
        None
    );
    assert_eq!(
        validate_phone_message(json!({
            "type": "slash_action",
            "commandId": "review",
            "arguments": ["bad"],
        })),
        None
    );
    assert_eq!(
        validate_phone_message(json!({
            "type": "unknown_action",
            "text": "hi",
        })),
        None
    );
}
