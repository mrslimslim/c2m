use codepilot_relay_worker::{DeviceRole, RouteAction, route_request};
use serde_json::json;

#[test]
fn health_route_returns_the_current_json_payload() {
    let response = route_request("GET", "/health", &[]);

    assert_eq!(
        response,
        RouteAction::Json {
            status: 200,
            body: json!({
                "status": "ok",
                "service": "codepilot-relay",
            }),
        }
    );
}

#[test]
fn ws_route_rejects_missing_channel_or_device() {
    let response = route_request("GET", "/ws", &[]);

    assert_eq!(
        response,
        RouteAction::Json {
            status: 400,
            body: json!({
                "error": "Missing 'channel' and/or 'device' query parameters",
            }),
        }
    );
}

#[test]
fn ws_route_rejects_invalid_device_names() {
    let response = route_request(
        "GET",
        "/ws",
        &[("channel", "pair-123"), ("device", "tablet")],
    );

    assert_eq!(
        response,
        RouteAction::Json {
            status: 400,
            body: json!({
                "error": "device must be 'bridge' or 'phone'",
            }),
        }
    );
}

#[test]
fn ws_route_forwards_valid_connections_to_the_named_channel() {
    let response = route_request(
        "GET",
        "/ws",
        &[("channel", "pair-123"), ("device", "bridge")],
    );

    assert_eq!(
        response,
        RouteAction::ForwardToChannel {
            channel: "pair-123".to_owned(),
            device: DeviceRole::Bridge,
        }
    );
}
