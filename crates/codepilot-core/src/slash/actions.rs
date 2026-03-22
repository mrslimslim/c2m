#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlashActionDispatchResult {
    pub ok: bool,
    pub message: Option<String>,
}

pub fn dispatch_slash_action(_command_id: &str) -> SlashActionDispatchResult {
    SlashActionDispatchResult {
        ok: false,
        message: Some("Slash actions are not implemented in the Rust bridge yet.".to_owned()),
    }
}
