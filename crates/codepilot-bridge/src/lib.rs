pub mod bridge;
pub mod transport;

use clap::Parser;
use std::path::PathBuf;

#[derive(Debug, Clone, Parser, PartialEq, Eq)]
#[command(
    name = "codepilot",
    version = "0.1.0",
    about = "Mobile command center for AI coding agents via Cloudflare Tunnel"
)]
pub struct CliArgs {
    #[arg(long, default_value = "auto")]
    pub agent: String,
    #[arg(long, default_value = ".")]
    pub dir: PathBuf,
    #[arg(long)]
    pub tunnel: bool,
}
