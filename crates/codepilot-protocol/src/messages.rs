use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct HandshakeOkMessage {
    pub encrypted: bool,
    #[serde(default, rename = "clientId")]
    pub client_id: Option<String>,
}

