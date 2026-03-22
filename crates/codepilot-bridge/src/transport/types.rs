use codepilot_protocol::messages::BridgeMessage;

pub trait TransportClient: Send + Sync {
    fn id(&self) -> &str;
    fn send(&self, message: BridgeMessage);
}

pub trait TransportServer: Send + Sync {
    fn stop(&self);
}
