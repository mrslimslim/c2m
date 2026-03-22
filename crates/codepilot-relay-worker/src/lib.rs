use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;

pub const SERVICE_NAME: &str = "codepilot-relay";
pub const MAX_CACHED_MESSAGES: usize = 100;
pub const MESSAGE_EXPIRY_MS: i64 = 24 * 60 * 60 * 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceRole {
    Bridge,
    Phone,
}

impl DeviceRole {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "bridge" => Some(Self::Bridge),
            "phone" => Some(Self::Phone),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Bridge => "bridge",
            Self::Phone => "phone",
        }
    }

    pub fn peer(self) -> Self {
        match self {
            Self::Bridge => Self::Phone,
            Self::Phone => Self::Bridge,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum RouteAction {
    Json {
        status: u16,
        body: Value,
    },
    ForwardToChannel {
        channel: String,
        device: DeviceRole,
    },
    Empty {
        status: u16,
        headers: Vec<(String, String)>,
    },
    Text {
        status: u16,
        body: String,
    },
}

pub fn route_request(method: &str, path: &str, query: &[(&str, &str)]) -> RouteAction {
    if path == "/health" {
        return RouteAction::Json {
            status: 200,
            body: json!({
                "status": "ok",
                "service": SERVICE_NAME,
            }),
        };
    }

    if path == "/ws" {
        let channel = query_param(query, "channel");
        let device = query_param(query, "device");

        let Some(channel) = channel else {
            return missing_ws_params();
        };
        let Some(device) = device.and_then(DeviceRole::parse) else {
            return if device.is_none() {
                missing_ws_params()
            } else {
                RouteAction::Json {
                    status: 400,
                    body: json!({
                        "error": "device must be 'bridge' or 'phone'",
                    }),
                }
            };
        };

        return RouteAction::ForwardToChannel {
            channel: channel.to_owned(),
            device,
        };
    }

    if method.eq_ignore_ascii_case("OPTIONS") {
        return RouteAction::Empty {
            status: 204,
            headers: vec![
                ("Access-Control-Allow-Origin".to_owned(), "*".to_owned()),
                (
                    "Access-Control-Allow-Methods".to_owned(),
                    "GET, OPTIONS".to_owned(),
                ),
                (
                    "Access-Control-Allow-Headers".to_owned(),
                    "Content-Type".to_owned(),
                ),
            ],
        };
    }

    RouteAction::Text {
        status: 404,
        body: "Not found".to_owned(),
    }
}

fn missing_ws_params() -> RouteAction {
    RouteAction::Json {
        status: 400,
        body: json!({
            "error": "Missing 'channel' and/or 'device' query parameters",
        }),
    }
}

fn query_param<'a>(query: &'a [(&str, &str)], name: &str) -> Option<&'a str> {
    query
        .iter()
        .find_map(|(key, value)| (*key == name).then_some(*value))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CachedMessage {
    pub data: String,
    pub timestamp: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delivery {
    pub recipient: DeviceRole,
    pub data: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectResult {
    pub replaced_socket_id: Option<String>,
    pub deliveries: Vec<Delivery>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceiveResult {
    pub deliveries: Vec<Delivery>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisconnectResult {
    pub deliveries: Vec<Delivery>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayChannelConfig {
    pub max_cached_messages: usize,
    pub message_expiry_ms: i64,
}

impl Default for RelayChannelConfig {
    fn default() -> Self {
        Self {
            max_cached_messages: MAX_CACHED_MESSAGES,
            message_expiry_ms: MESSAGE_EXPIRY_MS,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayChannelCore {
    config: RelayChannelConfig,
    connected_sockets: HashMap<DeviceRole, String>,
    cached_messages: HashMap<DeviceRole, Vec<CachedMessage>>,
}

impl RelayChannelCore {
    pub fn new(config: RelayChannelConfig) -> Self {
        Self {
            config,
            connected_sockets: HashMap::new(),
            cached_messages: HashMap::new(),
        }
    }

    pub fn with_cached_messages(
        config: RelayChannelConfig,
        cached_messages: HashMap<DeviceRole, Vec<CachedMessage>>,
    ) -> Self {
        Self {
            config,
            connected_sockets: HashMap::new(),
            cached_messages,
        }
    }

    pub fn connect(
        &mut self,
        device: DeviceRole,
        socket_id: impl Into<String>,
        now_ms: i64,
    ) -> ConnectResult {
        let replaced_socket_id = self.connected_sockets.insert(device, socket_id.into());
        let mut deliveries = self
            .take_valid_cached_messages(device, now_ms)
            .into_iter()
            .map(|message| Delivery {
                recipient: device,
                data: message.data,
            })
            .collect::<Vec<_>>();

        if self.connected_sockets.contains_key(&device.peer()) {
            deliveries.push(Delivery {
                recipient: device.peer(),
                data: peer_event_json("relay_peer_connected", device),
            });
        }

        ConnectResult {
            replaced_socket_id,
            deliveries,
        }
    }

    pub fn receive(
        &mut self,
        sender: DeviceRole,
        message: impl Into<String>,
        now_ms: i64,
    ) -> ReceiveResult {
        let recipient = sender.peer();
        let data = message.into();

        if self.connected_sockets.contains_key(&recipient) {
            return ReceiveResult {
                deliveries: vec![Delivery { recipient, data }],
            };
        }

        let cached = self.cached_messages.entry(recipient).or_default();
        cached.push(CachedMessage {
            data,
            timestamp: now_ms,
        });

        let overflow = cached.len().saturating_sub(self.config.max_cached_messages);
        if overflow > 0 {
            cached.drain(0..overflow);
        }

        ReceiveResult {
            deliveries: Vec::new(),
        }
    }

    pub fn disconnect(&mut self, device: DeviceRole) -> DisconnectResult {
        let mut deliveries = Vec::new();

        if self.connected_sockets.remove(&device).is_some()
            && self.connected_sockets.contains_key(&device.peer())
        {
            deliveries.push(Delivery {
                recipient: device.peer(),
                data: peer_event_json("relay_peer_disconnected", device),
            });
        }

        DisconnectResult { deliveries }
    }

    pub fn drop_socket(&mut self, device: DeviceRole) {
        self.connected_sockets.remove(&device);
    }

    pub fn cached_messages_for(&self, device: DeviceRole) -> Vec<CachedMessage> {
        self.cached_messages
            .get(&device)
            .cloned()
            .unwrap_or_default()
    }

    pub fn cached_snapshot(&self) -> HashMap<DeviceRole, Vec<CachedMessage>> {
        self.cached_messages.clone()
    }

    fn take_valid_cached_messages(
        &mut self,
        device: DeviceRole,
        now_ms: i64,
    ) -> Vec<CachedMessage> {
        let cached = self.cached_messages.remove(&device).unwrap_or_default();
        cached
            .into_iter()
            .filter(|message| now_ms - message.timestamp < self.config.message_expiry_ms)
            .collect()
    }
}

fn peer_event_json(event_type: &str, device: DeviceRole) -> String {
    format!(
        r#"{{"type":"{event_type}","device":"{}"}}"#,
        device.as_str()
    )
}

#[cfg(target_arch = "wasm32")]
use worker::{
    Context, Date, DurableObject, Env, Error, Request, Response, Result, State, Stub, WebSocket,
    WebSocketIncomingMessage, WebSocketPair, durable_object, event,
};

#[cfg(target_arch = "wasm32")]
const CACHE_KEY: &str = "cache";

#[cfg(target_arch = "wasm32")]
fn now_ms() -> i64 {
    Date::now().as_millis() as i64
}

#[cfg(target_arch = "wasm32")]
fn apply_headers(mut response: Response, headers: &[(String, String)]) -> Response {
    let response_headers = response.headers_mut();
    for (name, value) in headers {
        let _ = response_headers.set(name, value);
    }
    response
}

#[cfg(target_arch = "wasm32")]
fn response_from_route(route: RouteAction) -> Result<Response> {
    match route {
        RouteAction::Json { status, body } => Ok(Response::from_json(&body)?.with_status(status)),
        RouteAction::ForwardToChannel { .. } => Response::error("route must be forwarded", 500),
        RouteAction::Empty { status, headers } => {
            let response = Response::empty()?.with_status(status);
            Ok(apply_headers(response, &headers))
        }
        RouteAction::Text { status, body } => Ok(Response::ok(body)?.with_status(status)),
    }
}

#[cfg(target_arch = "wasm32")]
fn ws_stub(env: &Env, channel: &str) -> Result<Stub> {
    let namespace = env.durable_object("CHANNEL")?;
    let object_id = namespace.id_from_name(channel)?;
    object_id.get_stub()
}

#[cfg(target_arch = "wasm32")]
fn load_query_pairs(req: &Request) -> Result<Vec<(String, String)>> {
    let url = req.url()?;
    Ok(url
        .query_pairs()
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect())
}

#[cfg(target_arch = "wasm32")]
#[event(fetch)]
pub async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    console_error_panic_hook::set_once();

    let url = req.url()?;
    let query_pairs = load_query_pairs(&req)?;
    let query_refs = query_pairs
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect::<Vec<_>>();

    match route_request(req.method().to_string().as_str(), url.path(), &query_refs) {
        RouteAction::ForwardToChannel { channel, .. } => {
            ws_stub(&env, &channel)?.fetch_with_request(req).await
        }
        other => response_from_route(other),
    }
}

#[cfg(target_arch = "wasm32")]
#[durable_object]
pub struct Channel {
    state: State,
    _env: Env,
}

#[cfg(target_arch = "wasm32")]
impl Channel {
    async fn load_cache(&self) -> Result<HashMap<DeviceRole, Vec<CachedMessage>>> {
        Ok(self
            .state
            .storage()
            .get::<HashMap<DeviceRole, Vec<CachedMessage>>>(CACHE_KEY)
            .await?
            .unwrap_or_default())
    }

    async fn store_cache(&self, cache: &HashMap<DeviceRole, Vec<CachedMessage>>) -> Result<()> {
        self.state.storage().put(CACHE_KEY, cache).await
    }

    fn connected_role_map(&self) -> HashMap<DeviceRole, String> {
        let mut connected = HashMap::new();
        if !self
            .state
            .get_websockets_with_tag(DeviceRole::Bridge.as_str())
            .is_empty()
        {
            connected.insert(DeviceRole::Bridge, "bridge".to_owned());
        }
        if !self
            .state
            .get_websockets_with_tag(DeviceRole::Phone.as_str())
            .is_empty()
        {
            connected.insert(DeviceRole::Phone, "phone".to_owned());
        }
        connected
    }

    fn current_socket_for(&self, role: DeviceRole) -> Option<WebSocket> {
        self.state
            .get_websockets_with_tag(role.as_str())
            .into_iter()
            .next()
    }

    fn send_delivery(&self, delivery: &Delivery) {
        if let Some(socket) = self.current_socket_for(delivery.recipient) {
            let _ = socket.send_with_str(&delivery.data);
        }
    }
}

#[cfg(target_arch = "wasm32")]
impl DurableObject for Channel {
    fn new(state: State, env: Env) -> Self {
        Self { state, _env: env }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        let url = req.url()?;

        if url.path() == "/health" {
            return Response::ok("ok");
        }

        let upgrade = req
            .headers()
            .get("Upgrade")?
            .unwrap_or_default()
            .to_ascii_lowercase();
        if upgrade != "websocket" {
            return Response::error("Expected WebSocket upgrade", 426);
        }

        let query_pairs = load_query_pairs(&req)?;
        let query_refs = query_pairs
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_str()))
            .collect::<Vec<_>>();
        let device = match route_request("GET", url.path(), &query_refs) {
            RouteAction::ForwardToChannel { device, .. } => device,
            RouteAction::Json { status, body } => {
                return Ok(Response::from_json(&body)?.with_status(status));
            }
            _ => return Response::error("Unexpected route action", 500),
        };

        if let Some(existing) = self.current_socket_for(device) {
            let _ = existing.close(Some(1000), Some("Replaced by new connection"));
        }

        let pair = WebSocketPair::new()?;
        let client = pair.client;
        let server = pair.server;
        self.state
            .accept_websocket_with_tags(&server, &[device.as_str()]);

        let mut core = RelayChannelCore {
            config: RelayChannelConfig::default(),
            connected_sockets: self.connected_role_map(),
            cached_messages: self.load_cache().await?,
        };

        let connect = core.connect(device, device.as_str(), now_ms());
        self.store_cache(&core.cached_snapshot()).await?;
        for delivery in &connect.deliveries {
            if delivery.recipient == device {
                let _ = server.send_with_str(&delivery.data);
            } else {
                self.send_delivery(delivery);
            }
        }

        Response::from_websocket(client)
    }

    async fn websocket_message(
        &self,
        ws: WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let tags = self.state.get_tags(&ws);
        let Some(sender) = tags.first().and_then(|tag| DeviceRole::parse(tag)) else {
            return Ok(());
        };

        let data = match message {
            WebSocketIncomingMessage::String(text) => text,
            WebSocketIncomingMessage::Binary(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        };

        let recipient = sender.peer();
        if let Some(target_socket) = self.current_socket_for(recipient) {
            if target_socket.send_with_str(&data).is_ok() {
                return Ok(());
            }
        }

        let mut core = RelayChannelCore {
            config: RelayChannelConfig::default(),
            connected_sockets: HashMap::new(),
            cached_messages: self.load_cache().await?,
        };
        let _ = core.receive(sender, data, now_ms());
        self.store_cache(&core.cached_snapshot()).await
    }

    async fn websocket_close(
        &self,
        ws: WebSocket,
        _code: usize,
        _reason: String,
        _was_clean: bool,
    ) -> Result<()> {
        let tags = self.state.get_tags(&ws);
        let Some(device) = tags.first().and_then(|tag| DeviceRole::parse(tag)) else {
            return Ok(());
        };

        if let Some(peer_socket) = self.current_socket_for(device.peer()) {
            let _ = peer_socket.send_with_str(peer_event_json("relay_peer_disconnected", device));
        }

        Ok(())
    }

    async fn websocket_error(&self, ws: WebSocket, _error: Error) -> Result<()> {
        let tags = self.state.get_tags(&ws);
        let Some(device) = tags.first().and_then(|tag| DeviceRole::parse(tag)) else {
            return Ok(());
        };

        if let Some(existing) = self.current_socket_for(device) {
            let _ = existing.close(Some(1011), Some("WebSocket error"));
        }

        Ok(())
    }
}
