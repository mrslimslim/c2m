#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_RELEASE_DIR="/Users/mrslimslim/.openclaw"
RELEASE_DIR="${CTUNNEL_DIR:-${CODEPILOT_RELEASE_DIR:-$DEFAULT_RELEASE_DIR}}"
WITH_RELAY=0
SKIP_IOS_BUILD=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--with-relay] [--skip-ios-build] [--dir <path>]

Automates the release preflight checks described in docs/release-preflight-checklist.md.

Options:
  --with-relay      Also verify Cloudflare login and relay build/test commands
  --skip-ios-build  Skip the xcodebuild simulator build step
  --dir <path>      Override the bridge working directory for smoke guidance
  -h, --help        Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    continue
  fi
  case "$1" in
    --with-relay)
      WITH_RELAY=1
      shift
      ;;
    --skip-ios-build)
      SKIP_IOS_BUILD=1
      shift
      ;;
    --dir)
      RELEASE_DIR="${2:?missing value for --dir}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"

FAILURES=()
BLOCKERS=()

section() {
  printf '\n== %s ==\n' "$1"
}

print_cmd() {
  printf '\n$ %s\n' "$*"
}

run_check() {
  local description="$1"
  shift
  print_cmd "$@"
  if "$@"; then
    return 0
  fi
  FAILURES+=("$description")
  return 1
}

record_blocker() {
  echo "$1" >&2
  BLOCKERS+=("$1")
}

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    record_blocker "Missing required command: $1"
    return 1
  fi
  return 0
}

section "Environment checks"
run_check "pwd" pwd || true

check_cmd cargo
check_cmd swift
check_cmd xcodebuild
check_cmd codex
check_cmd cloudflared
check_cmd rustup

if command -v cargo >/dev/null 2>&1; then
  run_check "cargo --version" cargo --version || true
fi
if command -v swift >/dev/null 2>&1; then
  run_check "swift --version" swift --version || true
fi
if command -v xcodebuild >/dev/null 2>&1; then
  run_check "xcodebuild -version" xcodebuild -version || true
fi
if command -v codex >/dev/null 2>&1; then
  run_check "codex --version" codex --version || true
  run_check "codex login status" codex login status || true
fi
if command -v cloudflared >/dev/null 2>&1; then
  run_check "cloudflared --version" cloudflared --version || true
fi

if [[ "$WITH_RELAY" -eq 1 ]] && command -v rustup >/dev/null 2>&1; then
  print_cmd rustup target list --installed
  if rustup target list --installed | grep -q 'wasm32-unknown-unknown'; then
    echo "wasm32-unknown-unknown is installed"
  else
    record_blocker "Missing Rust target: wasm32-unknown-unknown"
  fi
fi

if [[ "$WITH_RELAY" -eq 1 && -z "$(command -v wrangler || true)" ]]; then
  record_blocker "Missing required command: wrangler"
fi

if [[ "$WITH_RELAY" -eq 1 && -n "$(command -v wrangler || true)" ]]; then
  section "Cloudflare login"
  run_check "wrangler whoami" wrangler whoami || true
fi

if command -v cargo >/dev/null 2>&1 && command -v swift >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then
  section "Static checks"
  run_check "cargo build --workspace" cargo build --workspace || true
  run_check "cargo test -p codepilot-core" cargo test -p codepilot-core || true
  run_check "cargo test -p codepilot-agents" cargo test -p codepilot-agents || true
  run_check "cargo test -p codepilot-bridge" cargo test -p codepilot-bridge || true
  run_check "swift test --package-path packages/ios/CodePilotKit" swift test --package-path packages/ios/CodePilotKit || true

  if [[ "$SKIP_IOS_BUILD" -eq 0 ]]; then
    run_check "xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CTunnel -destination generic/platform=iOS Simulator build" xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CTunnel -destination 'generic/platform=iOS Simulator' build || true
  else
    echo "Skipping iOS simulator build"
  fi
else
  record_blocker "Skipping static checks because one or more required build tools are missing"
fi

if [[ "$WITH_RELAY" -eq 1 ]]; then
  if command -v cargo >/dev/null 2>&1; then
    run_check "cargo test -p codepilot-relay-worker" cargo test -p codepilot-relay-worker || true
    run_check "cargo build -p codepilot-relay-worker --target wasm32-unknown-unknown" cargo build -p codepilot-relay-worker --target wasm32-unknown-unknown || true
  fi
fi

section "Summary"
if [[ "${#BLOCKERS[@]}" -gt 0 ]]; then
  echo "Blocking environment issues:"
  for item in "${BLOCKERS[@]}"; do
    echo "  - $item"
  done
fi

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  echo "Failed automated checks:"
  for item in "${FAILURES[@]}"; do
    echo "  - $item"
  done
fi

if [[ "${#BLOCKERS[@]}" -eq 0 && "${#FAILURES[@]}" -eq 0 ]]; then
  cat <<EOF
Automated checks passed.

Start the bridge for manual smoke testing with:
  ctunnel

Equivalent raw command:
  cargo run -p codepilot-bridge -- --agent codex --tunnel --dir $RELEASE_DIR

Checklist reference:
  docs/release-preflight-checklist.md
EOF
  exit 0
fi

cat <<EOF
Next manual smoke command once blockers are resolved:
  ctunnel

Equivalent raw command:
  cargo run -p codepilot-bridge -- --agent codex --tunnel --dir $RELEASE_DIR

Checklist reference:
  docs/release-preflight-checklist.md
EOF
exit 1
