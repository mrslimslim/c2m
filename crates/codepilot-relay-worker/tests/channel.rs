use codepilot_relay_worker::{
    CachedMessage, Delivery, DeviceRole, RelayChannelConfig, RelayChannelCore,
};

#[test]
fn second_connection_for_a_role_replaces_the_previous_socket_and_notifies_the_peer() {
    let mut channel = RelayChannelCore::new(RelayChannelConfig::default());

    let first_bridge = channel.connect(DeviceRole::Bridge, "bridge-1", 10);
    assert_eq!(first_bridge.replaced_socket_id, None);

    let phone = channel.connect(DeviceRole::Phone, "phone-1", 20);
    assert_eq!(
        phone.deliveries,
        vec![Delivery {
            recipient: DeviceRole::Bridge,
            data: r#"{"type":"relay_peer_connected","device":"phone"}"#.to_owned(),
        }]
    );

    let replacement = channel.connect(DeviceRole::Bridge, "bridge-2", 30);
    assert_eq!(replacement.replaced_socket_id.as_deref(), Some("bridge-1"));
    assert_eq!(
        replacement.deliveries,
        vec![Delivery {
            recipient: DeviceRole::Phone,
            data: r#"{"type":"relay_peer_connected","device":"bridge"}"#.to_owned(),
        }]
    );
}

#[test]
fn cached_offline_messages_replay_to_the_reconnecting_peer_and_clear_after_delivery() {
    let mut channel = RelayChannelCore::new(RelayChannelConfig::default());

    channel.connect(DeviceRole::Bridge, "bridge-1", 10);
    let send_result = channel.receive(DeviceRole::Bridge, "ciphertext-1", 15);
    assert!(send_result.deliveries.is_empty());
    assert_eq!(
        channel.cached_messages_for(DeviceRole::Phone),
        vec![CachedMessage {
            data: "ciphertext-1".to_owned(),
            timestamp: 15,
        }]
    );

    let reconnect = channel.connect(DeviceRole::Phone, "phone-1", 20);
    assert_eq!(
        reconnect.deliveries,
        vec![
            Delivery {
                recipient: DeviceRole::Phone,
                data: "ciphertext-1".to_owned(),
            },
            Delivery {
                recipient: DeviceRole::Bridge,
                data: r#"{"type":"relay_peer_connected","device":"phone"}"#.to_owned(),
            },
        ]
    );
    assert!(channel.cached_messages_for(DeviceRole::Phone).is_empty());
}

#[test]
fn expired_cached_messages_are_dropped_instead_of_being_replayed() {
    let mut channel = RelayChannelCore::with_cached_messages(
        RelayChannelConfig {
            message_expiry_ms: 1_000,
            ..RelayChannelConfig::default()
        },
        [(
            DeviceRole::Phone,
            vec![
                CachedMessage {
                    data: "old".to_owned(),
                    timestamp: 100,
                },
                CachedMessage {
                    data: "fresh".to_owned(),
                    timestamp: 1_500,
                },
            ],
        )]
        .into_iter()
        .collect(),
    );

    let connect = channel.connect(DeviceRole::Phone, "phone-1", 2_000);
    assert_eq!(
        connect.deliveries,
        vec![Delivery {
            recipient: DeviceRole::Phone,
            data: "fresh".to_owned(),
        }]
    );
    assert!(channel.cached_messages_for(DeviceRole::Phone).is_empty());
}

#[test]
fn cached_messages_are_trimmed_to_the_last_hundred_entries() {
    let mut channel = RelayChannelCore::new(RelayChannelConfig::default());

    for index in 0..105 {
        channel.receive(DeviceRole::Bridge, format!("msg-{index}"), index);
    }

    let cached = channel.cached_messages_for(DeviceRole::Phone);
    assert_eq!(cached.len(), 100);
    assert_eq!(cached.first().unwrap().data, "msg-5");
    assert_eq!(cached.last().unwrap().data, "msg-104");
}
