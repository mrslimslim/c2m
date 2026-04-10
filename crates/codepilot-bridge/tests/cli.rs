use std::path::PathBuf;

use clap::Parser;
use codepilot_bridge::CliArgs;

#[test]
fn cli_parses_agent_dir_and_tunnel_flag() {
    let args = CliArgs::try_parse_from([
        "ctunnel",
        "--agent",
        "claude",
        "--dir",
        "/tmp/project",
        "--tunnel",
    ])
    .unwrap();

    assert_eq!(args.agent, "claude");
    assert_eq!(args.dir, PathBuf::from("/tmp/project"));
    assert!(args.tunnel);
}

#[test]
fn cli_defaults_to_auto_agent_and_current_directory() {
    let args = CliArgs::try_parse_from(["ctunnel"]).unwrap();

    assert_eq!(args.agent, "auto");
    assert_eq!(args.dir, PathBuf::from("."));
    assert!(!args.tunnel);
}
