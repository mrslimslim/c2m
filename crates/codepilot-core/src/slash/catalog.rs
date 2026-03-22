use crate::slash::codex::build_codex_slash_catalog;
use codepilot_protocol::{
    messages::{SessionConfig, SlashCommandMeta},
    state::AgentType,
};

#[derive(Debug, Clone, PartialEq)]
pub struct BuildSlashCatalogOptions {
    pub adapter: AgentType,
    pub adapter_version: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SlashCatalog {
    pub message_type: String,
    pub capability: String,
    pub adapter: AgentType,
    pub adapter_version: Option<String>,
    pub catalog_version: String,
    pub defaults: SessionConfig,
    pub commands: Vec<SlashCommandMeta>,
}

pub fn build_slash_catalog(options: BuildSlashCatalogOptions) -> SlashCatalog {
    match options.adapter {
        AgentType::Codex => build_codex_slash_catalog(options.adapter_version),
        AgentType::Claude => SlashCatalog {
            message_type: "slash_catalog".to_owned(),
            capability: codepilot_protocol::messages::SLASH_CATALOG_CAPABILITY.to_owned(),
            adapter: AgentType::Claude,
            adapter_version: options.adapter_version.clone(),
            catalog_version: format!(
                "claude-{}",
                options.adapter_version.as_deref().unwrap_or("fallback")
            ),
            defaults: SessionConfig {
                model: None,
                model_reasoning_effort: None,
                approval_policy: None,
                sandbox_mode: None,
            },
            commands: Vec::new(),
        },
    }
}
