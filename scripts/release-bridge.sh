#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_RELEASE_DIR="/Users/mrslimslim/.openclaw"
RELEASE_DIR="${CTUNNEL_DIR:-${CODEPILOT_RELEASE_DIR:-$DEFAULT_RELEASE_DIR}}"

if [[ "${1:-}" == "--" ]]; then
  shift
fi

cd "$ROOT_DIR"

exec cargo run -p codepilot-bridge -- --agent codex --tunnel --dir "$RELEASE_DIR" "$@"
