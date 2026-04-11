#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_RELEASE_DIR="$(pwd -P)"
RELEASE_DIR="${CTUNNEL_DIR:-${CODEPILOT_RELEASE_DIR:-$DEFAULT_RELEASE_DIR}}"
HAS_AGENT_OVERRIDE=0
HAS_DIR_OVERRIDE=0

if [[ "${1:-}" == "--" ]]; then
  shift
fi

for arg in "$@"; do
  case "$arg" in
    --agent|--agent=*)
      HAS_AGENT_OVERRIDE=1
      ;;
    --dir|--dir=*)
      HAS_DIR_OVERRIDE=1
      ;;
  esac
done

BRIDGE_ARGS=(--tunnel)
if [[ "$HAS_AGENT_OVERRIDE" -eq 0 ]]; then
  BRIDGE_ARGS+=(--agent codex)
fi
if [[ "$HAS_DIR_OVERRIDE" -eq 0 ]]; then
  BRIDGE_ARGS+=(--dir "$RELEASE_DIR")
fi
BRIDGE_ARGS+=("$@")

exec cargo run --manifest-path "$ROOT_DIR/Cargo.toml" -p codepilot-bridge -- "${BRIDGE_ARGS[@]}"
