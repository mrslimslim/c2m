# Rust Monorepo Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current TypeScript `protocol`, `bridge`, and `relay` runtime packages with Rust implementations that preserve the existing mobile protocol, pairing format, and Cloudflare relay deployment model.

**Architecture:** Build a Cargo workspace alongside the existing monorepo, starting with the shared wire protocol and core compatibility modules, then port the Cloudflare relay, bridge runtime, and agent adapters in dependency order. Keep the TypeScript implementation in place as a behavior baseline until Rust passes parity checks for pairing, encrypted transport, replay, diff loading, slash catalog delivery, and relay forwarding.

**Tech Stack:** Rust stable, Cargo workspace, `serde`, `serde_json`, `tokio`, `clap`, `axum` or `tokio-tungstenite`, `worker`/`workers-rs`, `x25519-dalek`, `aes-gcm`, `hkdf`, `sha2`, `node:test`, pnpm, Cloudflare Wrangler

---

**Execution note:** This rewrite spans multiple runtime targets, but they are not independent subsystems. Do not split execution into separate architecture plans. The protocol, crypto, relay, bridge, and adapter tasks are coupled and should land in the dependency order below from a dedicated worktree or branch.

## File Map

### Root Tooling

- `Cargo.toml`
  - Workspace root and shared dependency versions
- `rust-toolchain.toml`
  - Pin the Rust toolchain for all crates
- `.cargo/config.toml`
  - Shared Cargo aliases and target configuration if needed for Worker builds
- `package.json`
  - Transition top-level scripts from pnpm TypeScript builds to Cargo/Wrangler commands during cutover
- `docs/technical.md`
  - Update architecture and runtime descriptions after Rust becomes the default
- `docs/debugging.md`
  - Update bridge and relay debugging instructions for Rust binaries and Worker builds

### Rust Protocol Crate

- `crates/codepilot-protocol/Cargo.toml`
  - Protocol crate manifest
- `crates/codepilot-protocol/src/lib.rs`
  - Re-export protocol modules
- `crates/codepilot-protocol/src/state.rs`
  - `SessionInfo`, diff models, token usage, state enums
- `crates/codepilot-protocol/src/events.rs`
  - Unified `AgentEvent` enum and event payload structs
- `crates/codepilot-protocol/src/messages.rs`
  - Handshake, phone, bridge, slash, diff, and encrypted wire messages
- `crates/codepilot-protocol/tests/protocol_json_roundtrip.rs`
  - JSON compatibility tests for all message families

### Rust Core Crate

- `crates/codepilot-core/Cargo.toml`
  - Shared operational crate manifest
- `crates/codepilot-core/src/lib.rs`
  - Re-export core modules
- `crates/codepilot-core/src/pairing/crypto.rs`
  - X25519, HKDF, AES-GCM compatibility logic
- `crates/codepilot-core/src/pairing/state.rs`
  - `~/.codepilot/pairing/<hash>.json` load/save compatibility
- `crates/codepilot-core/src/pairing/qrcode.rs`
  - QR rendering helpers for pairing payloads
- `crates/codepilot-core/src/session_store/path.rs`
  - Stable session log root resolution
- `crates/codepilot-core/src/session_store/event_log.rs`
  - Append-only JSONL event persistence and alias resolution
- `crates/codepilot-core/src/diff/parser.rs`
  - Unified diff parser and hunk model
- `crates/codepilot-core/src/diff/service.rs`
  - Diff lookup, truncation, and pagination service
- `crates/codepilot-core/src/slash/catalog.rs`
  - Slash metadata builder
- `crates/codepilot-core/src/slash/actions.rs`
  - Bridge-side slash action dispatch helpers
- `crates/codepilot-core/src/slash/codex.rs`
  - Codex-specific slash defaults and menu data
- `crates/codepilot-core/src/slash/version.rs`
  - Adapter version detection helpers
- `crates/codepilot-core/src/security.rs`
  - Sensitive-path filtering and path sandbox enforcement
- `crates/codepilot-core/src/logger.rs`
  - Bridge-friendly logging helpers
- `crates/codepilot-core/src/tunnel.rs`
  - Cloudflare tunnel process wrapper or shell integration
- `crates/codepilot-core/tests/crypto_compat.rs`
  - Cross-language crypto compatibility vectors
- `crates/codepilot-core/tests/pairing_state.rs`
  - Pairing state persistence tests
- `crates/codepilot-core/tests/session_event_store.rs`
  - Event log and alias replay tests
- `crates/codepilot-core/tests/diff_parser.rs`
  - Unified diff parsing tests
- `crates/codepilot-core/tests/diff_service.rs`
  - Diff paging and truncation tests
- `crates/codepilot-core/tests/security.rs`
  - File sandboxing tests
- `crates/codepilot-core/tests/slash_catalog.rs`
  - Slash catalog generation tests
- `crates/codepilot-core/tests/tunnel.rs`
  - Tunnel command and lifecycle tests

### Rust Agents Crate

- `crates/codepilot-agents/Cargo.toml`
  - Agent crate manifest
- `crates/codepilot-agents/src/lib.rs`
  - Re-export adapter modules
- `crates/codepilot-agents/src/types.rs`
  - Rust `AgentAdapter` trait and session option types
- `crates/codepilot-agents/src/codex.rs`
  - Codex CLI session lifecycle and event mapping
- `crates/codepilot-agents/src/claude.rs`
  - Claude CLI session lifecycle and event mapping
- `crates/codepilot-agents/src/codex_cli_thread.rs`
  - Codex stream process helper
- `crates/codepilot-agents/tests/codex_adapter.rs`
  - Codex stream mapping tests
- `crates/codepilot-agents/tests/claude_adapter.rs`
  - Claude stream mapping tests

### Rust Bridge Crate

- `crates/codepilot-bridge/Cargo.toml`
  - Native bridge manifest
- `crates/codepilot-bridge/src/lib.rs`
  - Public bridge exports
- `crates/codepilot-bridge/src/main.rs`
  - CLI entrypoint
- `crates/codepilot-bridge/src/bridge.rs`
  - Main bridge orchestrator
- `crates/codepilot-bridge/src/transport/mod.rs`
  - Transport module exports
- `crates/codepilot-bridge/src/transport/types.rs`
  - Transport traits and client types
- `crates/codepilot-bridge/src/transport/local.rs`
  - Local WebSocket transport and message validation
- `crates/codepilot-bridge/tests/validation.rs`
  - Transport message validation tests
- `crates/codepilot-bridge/tests/local_transport.rs`
  - Handshake and encrypted message flow tests
- `crates/codepilot-bridge/tests/bridge.rs`
  - Bridge replay, routing, diff, slash, and session tests
- `crates/codepilot-bridge/tests/cli.rs`
  - CLI option parsing and startup tests

### Rust Relay Worker Crate

- `crates/codepilot-relay-worker/Cargo.toml`
  - Worker crate manifest
- `crates/codepilot-relay-worker/src/lib.rs`
  - Worker fetch entrypoint and Durable Object
- `crates/codepilot-relay-worker/wrangler.toml`
  - Worker deployment config
- `crates/codepilot-relay-worker/tests/relay_routes.rs`
  - `/health` and `/ws` route behavior tests
- `crates/codepilot-relay-worker/tests/channel.rs`
  - Durable Object relay behavior tests

### TypeScript Runtime To Retire After Cutover

- `packages/protocol/**`
- `packages/bridge/**`
- `packages/relay/**`

Do not delete these directories until all parity checks pass and the root scripts/docs point at the Rust runtime by default.

## Task 1: Scaffold the Rust workspace and protocol crate shell

**Files:**
- Create: `Cargo.toml`
- Create: `rust-toolchain.toml`
- Create: `.cargo/config.toml`
- Create: `crates/codepilot-protocol/Cargo.toml`
- Create: `crates/codepilot-protocol/src/lib.rs`
- Create: `crates/codepilot-protocol/src/state.rs`
- Create: `crates/codepilot-protocol/src/events.rs`
- Create: `crates/codepilot-protocol/src/messages.rs`
- Test: `crates/codepilot-protocol/tests/protocol_json_roundtrip.rs`

- [ ] **Step 1: Create the failing protocol smoke test first**

Add `crates/codepilot-protocol/tests/protocol_json_roundtrip.rs` with one focused test that imports the future crate API and asserts a simple JSON round-trip for a handshake payload:

```rust
use codepilot_protocol::messages::HandshakeOkMessage;

#[test]
fn handshake_ok_round_trips() {
    let raw = r#"{"type":"handshake_ok","encrypted":true,"clientId":"c1"}"#;
    let msg: HandshakeOkMessage = serde_json::from_str(raw).unwrap();
    assert!(msg.encrypted);
    assert_eq!(msg.client_id.as_deref(), Some("c1"));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p codepilot-protocol handshake_ok_round_trips -- --exact`
Expected: FAIL because the workspace, manifest, and crate modules do not exist yet.

- [ ] **Step 3: Add the minimal workspace and crate shell**

Create the workspace root and the protocol crate with minimal modules and re-exports:

```toml
# Cargo.toml
[workspace]
members = ["crates/codepilot-protocol"]
resolver = "2"
```

```rust
// crates/codepilot-protocol/src/lib.rs
pub mod events;
pub mod messages;
pub mod state;
```

Keep the initial type set as small as possible, just enough for the first round-trip test and future tasks.

- [ ] **Step 4: Re-run the test to verify it passes**

Run: `cargo test -p codepilot-protocol handshake_ok_round_trips -- --exact`
Expected: PASS and prove the workspace can build the first Rust crate.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml rust-toolchain.toml .cargo/config.toml crates/codepilot-protocol/Cargo.toml crates/codepilot-protocol/src/lib.rs crates/codepilot-protocol/src/state.rs crates/codepilot-protocol/src/events.rs crates/codepilot-protocol/src/messages.rs crates/codepilot-protocol/tests/protocol_json_roundtrip.rs
git commit -m "chore: scaffold rust workspace and protocol crate"
```

## Task 2: Port the full wire protocol with JSON compatibility tests

**Files:**
- Modify: `Cargo.toml`
- Modify: `crates/codepilot-protocol/Cargo.toml`
- Modify: `crates/codepilot-protocol/src/lib.rs`
- Modify: `crates/codepilot-protocol/src/state.rs`
- Modify: `crates/codepilot-protocol/src/events.rs`
- Modify: `crates/codepilot-protocol/src/messages.rs`
- Test: `crates/codepilot-protocol/tests/protocol_json_roundtrip.rs`

- [ ] **Step 1: Expand the failing protocol test coverage**

Extend `protocol_json_roundtrip.rs` to cover:

- `PhoneMessage::Command`
- `PhoneMessage::SyncSession`
- `BridgeMessage::Event` with `eventId`
- `BridgeMessage::SessionSyncComplete`
- `BridgeMessage::DiffContent`
- `BridgeMessage::SlashCatalog`
- `EncryptedWireMessage`

Use inline JSON fixtures that match the current TypeScript wire shape exactly.

- [ ] **Step 2: Run the protocol test suite to verify it fails**

Run: `cargo test -p codepilot-protocol protocol_json_roundtrip`
Expected: FAIL because the Rust enums and `serde` tags do not yet match the full TypeScript message surface.

- [ ] **Step 3: Implement the complete protocol model**

Define the Rust protocol using explicit `serde` control:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PhoneMessage {
    Command { text: String, #[serde(default)] session_id: Option<String>, #[serde(default)] config: Option<SessionConfig> },
    Cancel { session_id: String },
    FileReq { path: String, session_id: String },
    DeleteSession { session_id: String },
    ListSessions {},
    Ping { ts: i64 },
    SyncSession { session_id: String, after_event_id: u64 },
    DiffReq { session_id: String, event_id: u64 },
    DiffHunksReq { session_id: String, event_id: u64, path: String, after_hunk_index: usize },
    SlashAction { #[serde(default)] session_id: Option<String>, command_id: String, #[serde(default)] arguments: Option<std::collections::BTreeMap<String, SlashActionArgumentValue>> },
}
```

Mirror all current message families from:

- `packages/protocol/src/state.ts`
- `packages/protocol/src/events.ts`
- `packages/protocol/src/messages.ts`

Preserve:

- current string literals
- optional fields
- field ordering only where tests rely on serialized JSON snapshots
- capability constants and slash enums

- [ ] **Step 4: Re-run the protocol test suite**

Run: `cargo test -p codepilot-protocol protocol_json_roundtrip`
Expected: PASS with Rust encode/decode behavior matching the TypeScript protocol contract.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/codepilot-protocol/Cargo.toml crates/codepilot-protocol/src/lib.rs crates/codepilot-protocol/src/state.rs crates/codepilot-protocol/src/events.rs crates/codepilot-protocol/src/messages.rs crates/codepilot-protocol/tests/protocol_json_roundtrip.rs
git commit -m "feat: port codepilot wire protocol to rust"
```

## Task 3: Port E2E crypto and pairing-state compatibility

**Files:**
- Modify: `Cargo.toml`
- Create: `crates/codepilot-core/Cargo.toml`
- Create: `crates/codepilot-core/src/lib.rs`
- Create: `crates/codepilot-core/src/pairing/crypto.rs`
- Create: `crates/codepilot-core/src/pairing/state.rs`
- Create: `crates/codepilot-core/src/pairing/qrcode.rs`
- Test: `crates/codepilot-core/tests/crypto_compat.rs`
- Test: `crates/codepilot-core/tests/pairing_state.rs`

- [ ] **Step 1: Write failing crypto and pairing tests**

Add tests that prove:

- Rust derives the same session key from the same X25519 inputs and OTP
- Rust can decrypt a payload shaped like the current TypeScript `EncryptedMessage`
- pairing material round-trips through the current JSON file format
- the default pairing path resolves to `~/.codepilot/pairing/<workDirHash>.json`

Start with fixtures copied from the existing TypeScript behavior in:

- `packages/bridge/src/pairing/crypto.ts`
- `packages/bridge/src/pairing/state.ts`

- [ ] **Step 2: Run the focused core tests to verify they fail**

Run: `cargo test -p codepilot-core --test crypto_compat`
Expected: FAIL because the core crate and pairing modules do not exist yet.

Run: `cargo test -p codepilot-core --test pairing_state`
Expected: FAIL because the core crate and pairing modules do not exist yet.

- [ ] **Step 3: Implement the minimal compatible crypto and state modules**

Build:

```rust
pub struct EncryptedMessage {
    pub v: u8,
    pub nonce: String,
    pub ciphertext: String,
    pub tag: String,
}

pub fn derive_session_key(my_private_key_base64: &str, their_public_key_base64: &str, otp: &str) -> Result<[u8; 32]> { /* ... */ }
pub fn encrypt(session_key: &[u8; 32], plaintext: &str) -> Result<EncryptedMessage> { /* ... */ }
pub fn decrypt(session_key: &[u8; 32], msg: &EncryptedMessage) -> Result<String> { /* ... */ }
```

Persist pairing state in the same JSON shape:

```json
{
  "version": 1,
  "privateKeyBase64": "...",
  "otp": "...",
  "token": "..."
}
```

Do not change:

- OTP format
- base64 wire format
- nonce size
- GCM tag size

- [ ] **Step 4: Re-run the focused core tests**

Run: `cargo test -p codepilot-core --test crypto_compat`
Expected: PASS and prove the Rust bridge can share pairing state with the TypeScript implementation.

Run: `cargo test -p codepilot-core --test pairing_state`
Expected: PASS and prove the Rust bridge can share pairing state with the TypeScript implementation.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/codepilot-core/Cargo.toml crates/codepilot-core/src/lib.rs crates/codepilot-core/src/pairing/crypto.rs crates/codepilot-core/src/pairing/state.rs crates/codepilot-core/src/pairing/qrcode.rs crates/codepilot-core/tests/crypto_compat.rs crates/codepilot-core/tests/pairing_state.rs
git commit -m "feat: port pairing and e2e crypto to rust"
```

## Task 4: Port session-event storage and file security helpers

**Files:**
- Modify: `crates/codepilot-core/src/lib.rs`
- Create: `crates/codepilot-core/src/session_store/path.rs`
- Create: `crates/codepilot-core/src/session_store/event_log.rs`
- Create: `crates/codepilot-core/src/security.rs`
- Test: `crates/codepilot-core/tests/session_event_store.rs`
- Test: `crates/codepilot-core/tests/security.rs`

- [ ] **Step 1: Write failing event-store and security tests**

Add tests that prove:

- the session store derives `~/.codepilot/sessions/<workDirHash>/index.json`
- appended events receive monotonic per-session `eventId`
- alias remaps resolve a temporary session ID to the canonical one
- replay after a cursor returns only newer events in order
- sensitive paths such as `.env`, `.ssh/*`, `.git/config`, and `*.pem` are rejected
- safe project-relative files still resolve under the working directory

- [ ] **Step 2: Run the focused core tests to verify they fail**

Run: `cargo test -p codepilot-core --test session_event_store`
Expected: FAIL because the store and sandbox modules do not exist yet.

Run: `cargo test -p codepilot-core --test security`
Expected: FAIL because the store and sandbox modules do not exist yet.

- [ ] **Step 3: Implement the minimal session store and path sandbox**

Port the current bridge behavior from:

- `packages/bridge/src/session-store/path.ts`
- `packages/bridge/src/session-store/event-log.ts`
- `packages/bridge/src/bridge.ts` sensitive path list

Use an append-only JSONL model:

```rust
pub struct PersistedSessionEvent {
    pub event_id: u64,
    pub session_id: String,
    pub timestamp: i64,
    pub event: AgentEvent,
}
```

And expose focused APIs:

- `append_event(...) -> Result<u64>`
- `read_events_after(...) -> Result<Vec<PersistedSessionEvent>>`
- `resolve_canonical_session_id(...) -> Result<String>`
- `validate_file_request_path(...) -> Result<PathBuf>`

- [ ] **Step 4: Re-run the focused core tests**

Run: `cargo test -p codepilot-core --test session_event_store`
Expected: PASS with deterministic replay and path-sandbox behavior.

Run: `cargo test -p codepilot-core --test security`
Expected: PASS with deterministic replay and path-sandbox behavior.

- [ ] **Step 5: Commit**

```bash
git add crates/codepilot-core/src/lib.rs crates/codepilot-core/src/session_store/path.rs crates/codepilot-core/src/session_store/event_log.rs crates/codepilot-core/src/security.rs crates/codepilot-core/tests/session_event_store.rs crates/codepilot-core/tests/security.rs
git commit -m "feat: port session storage and file security to rust"
```

## Task 5: Port diff, slash, logging, and tunnel support into the core crate

**Files:**
- Modify: `crates/codepilot-core/src/lib.rs`
- Create: `crates/codepilot-core/src/diff/parser.rs`
- Create: `crates/codepilot-core/src/diff/service.rs`
- Create: `crates/codepilot-core/src/slash/catalog.rs`
- Create: `crates/codepilot-core/src/slash/actions.rs`
- Create: `crates/codepilot-core/src/slash/codex.rs`
- Create: `crates/codepilot-core/src/slash/version.rs`
- Create: `crates/codepilot-core/src/logger.rs`
- Create: `crates/codepilot-core/src/tunnel.rs`
- Test: `crates/codepilot-core/tests/diff_parser.rs`
- Test: `crates/codepilot-core/tests/diff_service.rs`
- Test: `crates/codepilot-core/tests/slash_catalog.rs`
- Test: `crates/codepilot-core/tests/tunnel.rs`

- [ ] **Step 1: Write failing tests for diff parsing, slash metadata, and tunnel helpers**

Cover:

- unified diff parsing into file/hunk/line models
- diff truncation and hunk pagination
- slash catalog generation for Codex defaults and nested menu nodes
- adapter version detection from CLI output
- tunnel command startup and teardown behavior

- [ ] **Step 2: Run the focused core tests to verify they fail**

Run: `cargo test -p codepilot-core --test diff_parser`
Expected: FAIL because these modules and their public APIs do not exist yet.

Run: `cargo test -p codepilot-core --test diff_service`
Expected: FAIL because these modules and their public APIs do not exist yet.

Run: `cargo test -p codepilot-core --test slash_catalog`
Expected: FAIL because these modules and their public APIs do not exist yet.

Run: `cargo test -p codepilot-core --test tunnel`
Expected: FAIL because these modules and their public APIs do not exist yet.

- [ ] **Step 3: Implement the core support modules minimally**

Port behavior from:

- `packages/bridge/src/diff/parser.ts`
- `packages/bridge/src/diff/service.ts`
- `packages/bridge/src/slash/catalog.ts`
- `packages/bridge/src/slash/actions.ts`
- `packages/bridge/src/slash/codex.ts`
- `packages/bridge/src/slash/version.ts`
- `packages/bridge/src/utils/logger.ts`
- `packages/bridge/src/utils/tunnel.ts`

Keep the public API narrow:

```rust
pub fn build_slash_catalog(adapter: AgentType, adapter_version: Option<&str>) -> SlashCatalogMessage { /* ... */ }
pub async fn load_diff(session_id: &str, event_id: u64) -> Result<DiffContentMessage> { /* ... */ }
pub async fn start_tunnel(local_port: u16) -> Result<TunnelHandle> { /* ... */ }
```

Do not merge these concerns into `bridge.rs`; keep them testable and reusable.

- [ ] **Step 4: Re-run the focused core tests**

Run: `cargo test -p codepilot-core --test diff_parser`
Expected: PASS and prove the bridge can lean on stable Rust support modules.

Run: `cargo test -p codepilot-core --test diff_service`
Expected: PASS and prove the bridge can lean on stable Rust support modules.

Run: `cargo test -p codepilot-core --test slash_catalog`
Expected: PASS and prove the bridge can lean on stable Rust support modules.

Run: `cargo test -p codepilot-core --test tunnel`
Expected: PASS and prove the bridge can lean on stable Rust support modules.

- [ ] **Step 5: Commit**

```bash
git add crates/codepilot-core/src/lib.rs crates/codepilot-core/src/diff/parser.rs crates/codepilot-core/src/diff/service.rs crates/codepilot-core/src/slash/catalog.rs crates/codepilot-core/src/slash/actions.rs crates/codepilot-core/src/slash/codex.rs crates/codepilot-core/src/slash/version.rs crates/codepilot-core/src/logger.rs crates/codepilot-core/src/tunnel.rs crates/codepilot-core/tests/diff_parser.rs crates/codepilot-core/tests/diff_service.rs crates/codepilot-core/tests/slash_catalog.rs crates/codepilot-core/tests/tunnel.rs
git commit -m "feat: port bridge support services to rust core"
```

## Task 6: Port the Cloudflare relay Worker to Rust

**Files:**
- Modify: `Cargo.toml`
- Create: `crates/codepilot-relay-worker/Cargo.toml`
- Create: `crates/codepilot-relay-worker/src/lib.rs`
- Create: `crates/codepilot-relay-worker/wrangler.toml`
- Test: `crates/codepilot-relay-worker/tests/relay_routes.rs`
- Test: `crates/codepilot-relay-worker/tests/channel.rs`

- [ ] **Step 1: Write failing relay route and channel tests**

Cover:

- `GET /health` returns a healthy response
- `/ws` rejects missing `channel` and `device`
- `/ws` rejects invalid `device`
- a second `bridge` or `phone` connection replaces the previous socket for that role
- cached offline messages replay to the reconnecting peer
- cached messages expire after the configured TTL

- [ ] **Step 2: Run the focused relay tests to verify they fail**

Run: `cargo test -p codepilot-relay-worker --test relay_routes`
Expected: FAIL because the Worker crate and Durable Object implementation do not exist yet.

Run: `cargo test -p codepilot-relay-worker --test channel`
Expected: FAIL because the Worker crate and Durable Object implementation do not exist yet.

- [ ] **Step 3: Implement the Rust Worker and Durable Object**

Port behavior from:

- `packages/relay/src/index.ts`
- `packages/relay/src/channel.ts`
- `packages/relay/wrangler.toml`

Use `workers-rs` and preserve the current route contract:

```rust
#[event(fetch)]
pub async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> { /* ... */ }

#[durable_object]
pub struct Channel {
    state: State,
    env: Env,
}
```

Keep:

- role-based socket replacement
- pass-through ciphertext forwarding
- max 100 cached messages
- 24 hour expiry
- peer connect/disconnect notifications

- [ ] **Step 4: Re-run the focused relay tests**

Run: `cargo test -p codepilot-relay-worker --test relay_routes`
Expected: PASS and prove the Rust relay preserves the current Cloudflare behavior.

Run: `cargo test -p codepilot-relay-worker --test channel`
Expected: PASS and prove the Rust relay preserves the current Cloudflare behavior.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/codepilot-relay-worker/Cargo.toml crates/codepilot-relay-worker/src/lib.rs crates/codepilot-relay-worker/wrangler.toml crates/codepilot-relay-worker/tests/relay_routes.rs crates/codepilot-relay-worker/tests/channel.rs
git commit -m "feat: port relay worker to rust"
```

## Task 7: Port the bridge transport, orchestrator, and CLI

**Files:**
- Modify: `Cargo.toml`
- Create: `crates/codepilot-bridge/Cargo.toml`
- Create: `crates/codepilot-bridge/src/lib.rs`
- Create: `crates/codepilot-bridge/src/main.rs`
- Create: `crates/codepilot-bridge/src/bridge.rs`
- Create: `crates/codepilot-bridge/src/transport/mod.rs`
- Create: `crates/codepilot-bridge/src/transport/types.rs`
- Create: `crates/codepilot-bridge/src/transport/local.rs`
- Test: `crates/codepilot-bridge/tests/validation.rs`
- Test: `crates/codepilot-bridge/tests/local_transport.rs`
- Test: `crates/codepilot-bridge/tests/bridge.rs`
- Test: `crates/codepilot-bridge/tests/cli.rs`

- [ ] **Step 1: Write failing bridge tests for validation, handshake, and replay-aware routing**

Cover:

- valid and invalid phone-message validation
- handshake success and OTP failure
- encrypted-message-only enforcement after handshake
- `command`, `cancel`, `file_req`, `sync_session`, `diff_req`, `diff_hunks_req`, and `slash_action` routing
- replay queue ordering for `(clientId, sessionId)`
- CLI parsing for `--agent`, `--dir`, and `--tunnel`

- [ ] **Step 2: Run the focused bridge tests to verify they fail**

Run: `cargo test -p codepilot-bridge --test validation`
Expected: FAIL because the bridge crate, transport traits, and CLI do not exist yet.

Run: `cargo test -p codepilot-bridge --test local_transport`
Expected: FAIL because the bridge crate, transport traits, and CLI do not exist yet.

Run: `cargo test -p codepilot-bridge --test bridge`
Expected: FAIL because the bridge crate, transport traits, and CLI do not exist yet.

Run: `cargo test -p codepilot-bridge --test cli`
Expected: FAIL because the bridge crate, transport traits, and CLI do not exist yet.

- [ ] **Step 3: Implement the minimal Rust bridge runtime**

Port behavior from:

- `packages/bridge/src/transport/local.ts`
- `packages/bridge/src/transport/types.ts`
- `packages/bridge/src/bridge.ts`
- `packages/bridge/src/bin/codepilot.ts`
- `packages/bridge/src/index.ts`

Use the same operational flow:

```rust
#[derive(Parser)]
struct Args {
    #[arg(long, default_value = "auto")]
    agent: String,
    #[arg(long, default_value = ".")]
    dir: PathBuf,
    #[arg(long)]
    tunnel: bool,
}

pub struct Bridge {
    sessions: HashMap<String, SessionInfo>,
    connected_clients: HashMap<String, TransportClient>,
    // ...
}
```

Preserve:

- pairing-material startup
- QR display
- tunnel startup
- persist-before-delivery event ordering
- replay-aware live event fanout
- file-request sandboxing
- slash catalog push on connect

- [ ] **Step 4: Re-run the focused bridge tests**

Run: `cargo test -p codepilot-bridge --test validation`
Expected: PASS with the Rust bridge behaving like the current Node.js bridge for transport and orchestration concerns.

Run: `cargo test -p codepilot-bridge --test local_transport`
Expected: PASS with the Rust bridge behaving like the current Node.js bridge for transport and orchestration concerns.

Run: `cargo test -p codepilot-bridge --test bridge`
Expected: PASS with the Rust bridge behaving like the current Node.js bridge for transport and orchestration concerns.

Run: `cargo test -p codepilot-bridge --test cli`
Expected: PASS with the Rust bridge behaving like the current Node.js bridge for transport and orchestration concerns.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/codepilot-bridge/Cargo.toml crates/codepilot-bridge/src/lib.rs crates/codepilot-bridge/src/main.rs crates/codepilot-bridge/src/bridge.rs crates/codepilot-bridge/src/transport/mod.rs crates/codepilot-bridge/src/transport/types.rs crates/codepilot-bridge/src/transport/local.rs crates/codepilot-bridge/tests/validation.rs crates/codepilot-bridge/tests/local_transport.rs crates/codepilot-bridge/tests/bridge.rs crates/codepilot-bridge/tests/cli.rs
git commit -m "feat: port bridge runtime to rust"
```

## Task 8: Port the Codex and Claude agent adapters

**Files:**
- Modify: `Cargo.toml`
- Create: `crates/codepilot-agents/Cargo.toml`
- Create: `crates/codepilot-agents/src/lib.rs`
- Create: `crates/codepilot-agents/src/types.rs`
- Create: `crates/codepilot-agents/src/codex.rs`
- Create: `crates/codepilot-agents/src/claude.rs`
- Create: `crates/codepilot-agents/src/codex_cli_thread.rs`
- Test: `crates/codepilot-agents/tests/codex_adapter.rs`
- Test: `crates/codepilot-agents/tests/claude_adapter.rs`
- Modify: `crates/codepilot-bridge/Cargo.toml`
- Modify: `crates/codepilot-bridge/src/bridge.rs`

- [ ] **Step 1: Write failing adapter tests from captured CLI stream fixtures**

Cover:

- session start and resume semantics
- Codex thread ID remap from temporary ID to canonical thread ID
- mapping Codex `agent_message`, `reasoning`, `command_execution`, `file_change`, and `turn.completed` events into `AgentEvent`
- mapping Claude `assistant`, `result`, `tool_use`, and `tool_result` payloads into `AgentEvent`
- cancellation and process cleanup

- [ ] **Step 2: Run the focused adapter tests to verify they fail**

Run: `cargo test -p codepilot-agents --test codex_adapter`
Expected: FAIL because the agents crate and adapter trait do not exist yet.

Run: `cargo test -p codepilot-agents --test claude_adapter`
Expected: FAIL because the agents crate and adapter trait do not exist yet.

- [ ] **Step 3: Implement the Rust adapters minimally**

Port behavior from:

- `packages/bridge/src/adapters/types.ts`
- `packages/bridge/src/adapters/codex.ts`
- `packages/bridge/src/adapters/codex-cli-thread.ts`
- `packages/bridge/src/adapters/claude.ts`

Expose a focused trait:

```rust
#[async_trait::async_trait]
pub trait AgentAdapter {
    async fn start_session(&self, opts: SessionOptions) -> Result<SessionInfo>;
    async fn execute(&self, session_id: &str, input: &str, opts: Option<SessionOptions>, on_event: Box<dyn FnMut(AgentEvent) + Send>) -> Result<()>;
    async fn resume_session(&self, session_id: &str) -> Result<SessionInfo>;
    async fn cancel(&self, session_id: &str) -> Result<()>;
    async fn delete_session(&self, session_id: &str) -> Result<()>;
}
```

Integrate the new crate into `codepilot-bridge` only after the adapter tests are green.

- [ ] **Step 4: Re-run the focused adapter tests**

Run: `cargo test -p codepilot-agents --test codex_adapter`
Expected: PASS and prove the Rust bridge can drive both supported agents.

Run: `cargo test -p codepilot-agents --test claude_adapter`
Expected: PASS and prove the Rust bridge can drive both supported agents.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/codepilot-agents/Cargo.toml crates/codepilot-agents/src/lib.rs crates/codepilot-agents/src/types.rs crates/codepilot-agents/src/codex.rs crates/codepilot-agents/src/claude.rs crates/codepilot-agents/src/codex_cli_thread.rs crates/codepilot-agents/tests/codex_adapter.rs crates/codepilot-agents/tests/claude_adapter.rs crates/codepilot-bridge/Cargo.toml crates/codepilot-bridge/src/bridge.rs
git commit -m "feat: port codex and claude adapters to rust"
```

## Task 9: Cut over scripts and docs to the Rust runtime

**Files:**
- Modify: `package.json`
- Modify: `docs/technical.md`
- Modify: `docs/debugging.md`
- Modify: `crates/codepilot-relay-worker/wrangler.toml`

- [ ] **Step 1: Write failing smoke checks for the new default commands**

Add or update smoke checks so the repository default commands prove:

- the bridge binary builds with Cargo
- the relay Worker builds from the Rust crate
- docs reference the Rust paths and commands instead of the old TypeScript package paths

- [ ] **Step 2: Run the smoke checks and confirm the remaining cutover gap**

Run: `cargo build -p codepilot-bridge`
Expected: PASS if previous tasks are complete.

Run: `cargo build -p codepilot-relay-worker --target wasm32-unknown-unknown`
Expected: PASS if previous tasks are complete.

Run: `rg -n "packages/(bridge|protocol|relay)|tsc|node dist/bin/codepilot" docs package.json`
Expected: FAIL because root scripts and docs still reference the old TypeScript runtime as primary.

- [ ] **Step 3: Update scripts and docs to point at Rust**

Update:

- root `package.json` scripts to wrap Cargo and Wrangler commands
- `docs/technical.md` to describe the Rust workspace and crate boundaries
- `docs/debugging.md` to describe Rust bridge logs, tests, and Worker deployment
- relay deployment docs/config to point to `crates/codepilot-relay-worker`

Keep the legacy TypeScript runtime documented as a temporary fallback only until final cleanup.

- [ ] **Step 4: Re-run the smoke checks**

Run: `rg -n "packages/(bridge|protocol|relay)|tsc|node dist/bin/codepilot" docs package.json`
Expected: PASS only for explicitly marked legacy/fallback notes, not for default run instructions.

- [ ] **Step 5: Commit**

```bash
git add package.json docs/technical.md docs/debugging.md crates/codepilot-relay-worker/wrangler.toml
git commit -m "docs: switch project commands to rust runtime"
```

## Task 10: Run full parity verification and retire the TypeScript runtime

**Files:**
- Modify: `package.json`
- Modify: `docs/technical.md`
- Modify: `docs/debugging.md`
- Delete: `packages/protocol`
- Delete: `packages/bridge`
- Delete: `packages/relay`

- [ ] **Step 1: Run focused automated verification before deletion**

Run: `cargo test -p codepilot-protocol`
Expected: PASS

Run: `cargo test -p codepilot-core`
Expected: PASS

Run: `cargo test -p codepilot-relay-worker`
Expected: PASS

Run: `cargo test -p codepilot-bridge`
Expected: PASS

Run: `cargo test -p codepilot-agents`
Expected: PASS

- [ ] **Step 2: Run manual parity checks against the real product flows**

Verify:

- bridge starts and prints pairing QR code
- existing mobile client can pair using the old-compatible pairing state
- encrypted command execution works over local transport
- relay forwarding works through Cloudflare Durable Objects
- session replay and diff loading still work
- slash catalog still appears on connect
- both Codex and Claude execute a turn successfully

- [ ] **Step 3: Delete the TypeScript runtime only after parity passes**

Remove:

- `packages/protocol`
- `packages/bridge`
- `packages/relay`

Do not remove any package until the manual parity checklist is complete and any deployment docs point exclusively to the Rust runtime.

- [ ] **Step 4: Re-run the final repository verification**

Run: `cargo test --workspace`
Expected: PASS

Run: `git diff --stat`
Expected: Changes are limited to the Rust workspace, cutover docs, root scripts, and removal of the retired TypeScript runtime.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml rust-toolchain.toml .cargo/config.toml crates package.json docs/technical.md docs/debugging.md
git rm -r packages/protocol packages/bridge packages/relay
git commit -m "refactor: replace typescript runtime with rust workspace"
```
