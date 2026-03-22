use crate::slash::catalog::SlashCatalog;
use codepilot_protocol::{
    messages::{
        ApprovalPolicy, ModelReasoningEffort, SLASH_CATALOG_CAPABILITY, SandboxMode, SessionConfig,
        SlashAvailability, SlashCommandKind, SlashCommandMeta, SlashEffect, SlashMenuNode,
        SlashMenuOption, SlashMenuPresentation, SlashSessionConfigField,
    },
    state::AgentType,
};

fn default_config() -> SessionConfig {
    SessionConfig {
        model: Some("gpt-5.4".to_owned()),
        model_reasoning_effort: Some(ModelReasoningEffort::Medium),
        approval_policy: Some(ApprovalPolicy::OnRequest),
        sandbox_mode: Some(SandboxMode::WorkspaceWrite),
    }
}

pub fn build_codex_slash_catalog(adapter_version: Option<String>) -> SlashCatalog {
    SlashCatalog {
        message_type: "slash_catalog".to_owned(),
        capability: SLASH_CATALOG_CAPABILITY.to_owned(),
        adapter: AgentType::Codex,
        adapter_version: adapter_version.clone(),
        catalog_version: format!("codex-{}", adapter_version.as_deref().unwrap_or("fallback")),
        defaults: default_config(),
        commands: vec![
            build_model_command(),
            disabled_bridge_action(
                "fast",
                "/fast",
                "Toggle Fast mode to enable fastest inference at 2X plan usage",
                "Fast mode is not exposed through the current bridge and Codex SDK integration yet.",
            ),
            build_permissions_command(),
            disabled_bridge_action(
                "experimental",
                "/experimental",
                "Toggle experimental features",
                "Experimental feature toggles are not implemented in the bridge yet.",
            ),
            disabled_bridge_action(
                "skills",
                "/skills",
                "Use skills to improve how Codex performs specific tasks",
                "Skill inspection and application are not implemented in the bridge yet.",
            ),
            disabled_bridge_action(
                "review",
                "/review",
                "Review my current changes and find issues",
                "Slash-triggered bridge reviews are not implemented yet.",
            ),
            disabled_bridge_action(
                "rename",
                "/rename",
                "Rename the current thread",
                "Bridge-side thread renaming is not implemented yet.",
            ),
            SlashCommandMeta {
                id: "new".to_owned(),
                label: "/new".to_owned(),
                description: "Start a new chat during a conversation".to_owned(),
                kind: SlashCommandKind::ClientAction,
                availability: SlashAvailability::Enabled,
                disabled_reason: None,
                search_terms: Some(vec![
                    "session".to_owned(),
                    "thread".to_owned(),
                    "chat".to_owned(),
                ]),
                menu: None,
                action: None,
            },
        ],
    }
}

fn build_model_command() -> SlashCommandMeta {
    let models = [
        ("gpt-5.3-codex", "Latest frontier agentic coding model."),
        ("gpt-5.4", "Latest frontier agentic coding model."),
        ("gpt-5.2-codex", "Frontier agentic coding model."),
        (
            "gpt-5.1-codex-max",
            "Codex-optimized flagship for deep and fast reasoning.",
        ),
        (
            "gpt-5.2",
            "Latest frontier model with improvements across knowledge and reasoning.",
        ),
        (
            "gpt-5.1-codex-mini",
            "Faster Codex-optimized model for lighter tasks.",
        ),
    ];

    SlashCommandMeta {
        id: "model".to_owned(),
        label: "/model".to_owned(),
        description: "Choose what model and reasoning effort to use".to_owned(),
        kind: SlashCommandKind::Workflow,
        availability: SlashAvailability::Enabled,
        disabled_reason: None,
        search_terms: Some(vec![
            "models".to_owned(),
            "reasoning".to_owned(),
            "effort".to_owned(),
        ]),
        menu: Some(SlashMenuNode {
            title: "Select Model and Effort".to_owned(),
            helper_text: Some(
                "Access legacy models by running codex -m <model_name> or in your config.toml"
                    .to_owned(),
            ),
            presentation: SlashMenuPresentation::List,
            options: models
                .into_iter()
                .map(|(id, description)| SlashMenuOption {
                    id: id.to_owned(),
                    label: id.to_owned(),
                    description: Some(description.to_owned()),
                    badges: None,
                    effects: None,
                    next: Some(Box::new(build_reasoning_menu(id))),
                })
                .collect(),
        }),
        action: None,
    }
}

fn build_reasoning_menu(model_id: &str) -> SlashMenuNode {
    let reasoning_levels = [
        (
            ModelReasoningEffort::Low,
            "Low",
            "Fast responses with lighter reasoning",
        ),
        (
            ModelReasoningEffort::Medium,
            "Medium",
            "Balances speed and reasoning depth for everyday tasks",
        ),
        (
            ModelReasoningEffort::High,
            "High",
            "Greater reasoning depth for complex problems",
        ),
        (
            ModelReasoningEffort::Xhigh,
            "Extra high",
            "Extra high reasoning depth for complex problems",
        ),
    ];

    SlashMenuNode {
        title: format!("Select Reasoning Level for {model_id}"),
        helper_text: None,
        presentation: SlashMenuPresentation::List,
        options: reasoning_levels
            .into_iter()
            .map(|(id, label, description)| SlashMenuOption {
                id: format!("{id:?}").to_lowercase(),
                label: label.to_owned(),
                description: Some(description.to_owned()),
                badges: None,
                effects: Some(vec![
                    set_session_config(SlashSessionConfigField::Model, model_id.to_owned()),
                    set_session_config(
                        SlashSessionConfigField::ModelReasoningEffort,
                        format!("{id:?}").to_lowercase(),
                    ),
                ]),
                next: None,
            })
            .collect(),
    }
}

fn build_permissions_command() -> SlashCommandMeta {
    SlashCommandMeta {
        id: "permissions".to_owned(),
        label: "/permissions".to_owned(),
        description: "Choose what Codex is allowed to do".to_owned(),
        kind: SlashCommandKind::Workflow,
        availability: SlashAvailability::Enabled,
        disabled_reason: None,
        search_terms: Some(vec![
            "approval".to_owned(),
            "sandbox".to_owned(),
            "permissions".to_owned(),
            "full access".to_owned(),
        ]),
        menu: Some(SlashMenuNode {
            title: "Update Model Permissions".to_owned(),
            helper_text: None,
            presentation: SlashMenuPresentation::List,
            options: vec![
                SlashMenuOption {
                    id: "default".to_owned(),
                    label: "Default".to_owned(),
                    description: Some("Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files.".to_owned()),
                    badges: None,
                    effects: Some(vec![
                        set_session_config(
                            SlashSessionConfigField::ApprovalPolicy,
                            "on-request".to_owned(),
                        ),
                        set_session_config(
                            SlashSessionConfigField::SandboxMode,
                            "workspace-write".to_owned(),
                        ),
                    ]),
                    next: None,
                },
                SlashMenuOption {
                    id: "full-access".to_owned(),
                    label: "Full Access".to_owned(),
                    description: Some("Codex can edit files outside this workspace and access the internet without asking for approval. Exercise caution when using.".to_owned()),
                    badges: None,
                    effects: Some(vec![
                        set_session_config(
                            SlashSessionConfigField::ApprovalPolicy,
                            "never".to_owned(),
                        ),
                        set_session_config(
                            SlashSessionConfigField::SandboxMode,
                            "danger-full-access".to_owned(),
                        ),
                    ]),
                    next: None,
                },
            ],
        }),
        action: None,
    }
}

fn disabled_bridge_action(
    id: &str,
    label: &str,
    description: &str,
    disabled_reason: &str,
) -> SlashCommandMeta {
    SlashCommandMeta {
        id: id.to_owned(),
        label: label.to_owned(),
        description: description.to_owned(),
        kind: SlashCommandKind::BridgeAction,
        availability: SlashAvailability::Disabled,
        disabled_reason: Some(disabled_reason.to_owned()),
        search_terms: Some(vec![id.to_owned()]),
        menu: None,
        action: None,
    }
}

fn set_session_config(field: SlashSessionConfigField, value: String) -> SlashEffect {
    SlashEffect::SetSessionConfig { field, value }
}
