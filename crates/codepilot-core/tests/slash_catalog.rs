use codepilot_core::slash::{
    catalog::{BuildSlashCatalogOptions, build_slash_catalog},
    version::{detect_adapter_version, parse_codex_cli_version},
};
use codepilot_protocol::messages::SLASH_CATALOG_CAPABILITY;
use codepilot_protocol::state::AgentType;

#[test]
fn build_slash_catalog_returns_the_codex_command_set_for_codex_cli_0_116_0() {
    let catalog = build_slash_catalog(BuildSlashCatalogOptions {
        adapter: AgentType::Codex,
        adapter_version: Some("0.116.0".to_owned()),
    });

    assert_eq!(catalog.capability, SLASH_CATALOG_CAPABILITY);
    assert_eq!(catalog.adapter, AgentType::Codex);
    assert_eq!(catalog.adapter_version.as_deref(), Some("0.116.0"));
    assert_eq!(catalog.catalog_version, "codex-0.116.0");
    assert_eq!(
        catalog
            .commands
            .iter()
            .map(|command| command.id.as_str())
            .collect::<Vec<_>>(),
        vec![
            "model",
            "fast",
            "permissions",
            "experimental",
            "skills",
            "review",
            "rename",
            "new",
        ]
    );
}

#[test]
fn build_slash_catalog_exposes_a_nested_model_workflow_with_reasoning_leaves() {
    let catalog = build_slash_catalog(BuildSlashCatalogOptions {
        adapter: AgentType::Codex,
        adapter_version: Some("0.116.0".to_owned()),
    });

    let model = catalog
        .commands
        .iter()
        .find(|command| command.id == "model")
        .unwrap();
    assert_eq!(
        model.menu.as_ref().unwrap().title,
        "Select Model and Effort"
    );

    let gpt54 = model
        .menu
        .as_ref()
        .unwrap()
        .options
        .iter()
        .find(|o| o.id == "gpt-5.4")
        .unwrap();
    let xhigh = gpt54
        .next
        .as_ref()
        .unwrap()
        .options
        .iter()
        .find(|o| o.id == "xhigh")
        .unwrap();

    let effects = xhigh.effects.as_ref().unwrap();
    assert_eq!(effects.len(), 2);
}

#[test]
fn build_slash_catalog_exposes_permissions_presets_for_codex_cli_0_116_0() {
    let catalog = build_slash_catalog(BuildSlashCatalogOptions {
        adapter: AgentType::Codex,
        adapter_version: Some("0.116.0".to_owned()),
    });

    let permissions = catalog
        .commands
        .iter()
        .find(|command| command.id == "permissions")
        .unwrap();
    let options = &permissions.menu.as_ref().unwrap().options;
    assert_eq!(
        options
            .iter()
            .map(|option| option.id.as_str())
            .collect::<Vec<_>>(),
        vec!["default", "full-access"]
    );
}

#[test]
fn build_slash_catalog_marks_unsupported_bridge_actions_as_disabled_with_reasons() {
    let catalog = build_slash_catalog(BuildSlashCatalogOptions {
        adapter: AgentType::Codex,
        adapter_version: Some("0.116.0".to_owned()),
    });

    let fast = catalog
        .commands
        .iter()
        .find(|command| command.id == "fast")
        .unwrap();
    assert_eq!(format!("{:?}", fast.availability), "Disabled");
    assert!(
        fast.disabled_reason
            .as_deref()
            .unwrap()
            .contains("not exposed")
    );
}

#[test]
fn parse_codex_cli_version_extracts_a_semantic_version() {
    assert_eq!(
        parse_codex_cli_version("codex-cli 0.116.0"),
        Some("0.116.0".to_owned())
    );
    assert_eq!(
        parse_codex_cli_version("Codex CLI version: 1.2.3"),
        Some("1.2.3".to_owned())
    );
    assert_eq!(parse_codex_cli_version("something unexpected"), None);
}

#[test]
fn detect_adapter_version_returns_none_when_the_version_probe_fails() {
    let version =
        detect_adapter_version(AgentType::Codex, Box::new(|_, _| Err("unavailable".into())));
    assert_eq!(version, None);
}

#[test]
fn detect_adapter_version_probes_codex_with_version_and_normalizes_the_result() {
    let version = detect_adapter_version(
        AgentType::Codex,
        Box::new(|command, args| {
            assert_eq!(command, "codex");
            assert_eq!(args, vec!["--version"]);
            Ok("codex-cli 0.116.0".to_owned())
        }),
    );
    assert_eq!(version, Some("0.116.0".to_owned()));
}
