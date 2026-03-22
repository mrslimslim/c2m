use codepilot_protocol::state::AgentType;
use regex::Regex;
use std::process::Command;

pub type RunVersionCommand =
    Box<dyn Fn(&str, Vec<&str>) -> std::result::Result<String, String> + Send + Sync>;

pub fn detect_adapter_version(
    adapter: AgentType,
    run_version_command: RunVersionCommand,
) -> Option<String> {
    let command = match adapter {
        AgentType::Codex => "codex",
        AgentType::Claude => "claude",
    };

    let output = run_version_command(command, vec!["--version"]).ok()?;
    parse_adapter_version(adapter, &output)
}

pub fn detect_adapter_version_with_default(adapter: AgentType) -> Option<String> {
    detect_adapter_version(
        adapter,
        Box::new(|command, args| {
            let output = Command::new(command)
                .args(args)
                .output()
                .map_err(|error| error.to_string())?;
            Ok(format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            )
            .trim()
            .to_owned())
        }),
    )
}

pub fn parse_codex_cli_version(output: &str) -> Option<String> {
    parse_semantic_version(output)
}

fn parse_adapter_version(adapter: AgentType, output: &str) -> Option<String> {
    match adapter {
        AgentType::Codex => parse_codex_cli_version(output),
        AgentType::Claude => parse_semantic_version(output),
    }
}

fn parse_semantic_version(output: &str) -> Option<String> {
    let regex = Regex::new(r"\b(\d+\.\d+\.\d+)\b").unwrap();
    regex
        .captures(output)
        .and_then(|captures| captures.get(1).map(|match_| match_.as_str().to_owned()))
}
