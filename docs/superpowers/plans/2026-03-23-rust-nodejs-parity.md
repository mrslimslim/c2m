# Rust Node.js Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore feature parity between the restored Node/TypeScript baseline and the in-progress Rust runtime without regressing the iOS client wire contract.

**Architecture:** Treat the restored `packages/protocol`, `packages/bridge`, and `packages/relay` trees as the behavior baseline. Align the Rust workspace in dependency order: protocol compatibility first, bridge runtime behavior second, relay semantics last. For each area, add failing compatibility tests before changing Rust implementation, then verify Rust and iOS tests against the same wire shapes.

**Tech Stack:** Rust stable, Cargo workspace, `serde`, `serde_json`, `tokio`, Swift Package Manager tests, TypeScript baseline sources, Cloudflare Worker runtime

---

## File Map

- `packages/protocol/src/*`
  - Node/TS wire-format baseline for shared models and message unions
- `packages/bridge/src/*`
  - Node/TS bridge behavior baseline for session lifecycle, replay, slash, pairing, adapters, and transport
- `packages/relay/src/*`
  - Node/TS relay route and channel semantics baseline
- `packages/ios/CodePilotKit/Sources/CodePilotProtocol/*`
  - Mobile decode/encode contract that Rust output must preserve
- `packages/ios/CodePilotKit/Tests/*`
  - Mobile regression tests that surface protocol and session-routing mismatches
- `crates/codepilot-protocol/src/*`
  - Rust shared protocol models and serde behavior
- `crates/codepilot-protocol/tests/protocol_json_roundtrip.rs`
  - Rust compatibility round-trip coverage for JSON messages/events
- `crates/codepilot-bridge/src/*`
  - Rust bridge runtime and CLI entrypoint
- `crates/codepilot-bridge/tests/*`
  - Rust bridge behavior/regression tests
- `crates/codepilot-core/src/*`
  - Shared session store, diff, slash, security, pairing, and logging support
- `crates/codepilot-agents/src/*`
  - Rust Codex/Claude adapter implementations
- `crates/codepilot-relay-worker/src/lib.rs`
  - Rust relay worker implementation

## Task 1: Close protocol wire-format gaps first

**Files:**
- Modify: `crates/codepilot-protocol/tests/protocol_json_roundtrip.rs`
- Modify: `crates/codepilot-protocol/src/events.rs`
- Modify: `crates/codepilot-protocol/src/messages.rs`
- Modify: `crates/codepilot-protocol/src/state.rs`
- Reference: `packages/protocol/src/events.ts`
- Reference: `packages/protocol/src/messages.ts`
- Reference: `packages/protocol/src/state.ts`
- Reference: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/*`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`

- [ ] **Step 1: Add focused failing Rust protocol tests for concrete parity gaps**

Add compatibility tests for any wire-shape mismatches discovered between TS, Rust, and Swift. Start with `turn_completed` event encoding so Rust preserves the `usage` key as `null` when the value is absent, matching the Swift contract.

- [ ] **Step 2: Run the targeted protocol tests and verify they fail for the expected reason**

Run: `cargo test -p codepilot-protocol turn_completed -- --nocapture`
Expected: FAIL because Rust currently omits one or more keys or rejects valid legacy payloads.

- [ ] **Step 3: Implement the minimal Rust serde changes to match the shared contract**

Update Rust protocol models to serialize and deserialize the same JSON shapes as Node/TS and iOS, without widening unrelated behavior.

- [ ] **Step 4: Re-run Rust protocol tests and iOS protocol tests**

Run: `cargo test -p codepilot-protocol`
Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
Expected: PASS in both suites for the protocol scenarios covered.

## Task 2: Align bridge runtime behavior with the restored Node baseline

**Files:**
- Modify: `crates/codepilot-bridge/src/bridge.rs`
- Modify: `crates/codepilot-bridge/src/main.rs`
- Modify: `crates/codepilot-bridge/tests/bridge.rs`
- Modify: `crates/codepilot-core/src/session_store/*`
- Modify: `crates/codepilot-core/src/diff/*`
- Modify: `crates/codepilot-core/src/slash/*`
- Modify: `crates/codepilot-agents/src/codex.rs`
- Modify: `crates/codepilot-agents/src/codex_cli_thread.rs`
- Reference: `packages/bridge/src/*`
- Reference: `packages/ios/CodePilotKit/Sources/CodePilotCore/*`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/*`

- [ ] **Step 1: Produce a bridge parity checklist from the restored TS runtime**

Cover session creation, alias remap, event replay, diff pagination, slash catalog/action flow, adapter event mapping, and CLI startup logging.

- [ ] **Step 2: Add the next failing Rust regression tests for the highest-value bridge gap**

Prefer the smallest test that reproduces user-visible breakage first, not broad snapshot coverage.

- [ ] **Step 3: Implement the minimal bridge/core/agent fix**

Change only the Rust modules needed for that bridge behavior and preserve already-fixed session alias handling.

- [ ] **Step 4: Re-run targeted Rust bridge tests and matching iOS session-routing tests**

Run: `cargo test -p codepilot-bridge`
Run: `cargo test -p codepilot-agents`
Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionRoutingTests`
Run: `swift test --package-path packages/ios/CodePilotKit --filter PendingSessionCoordinatorTests`
Expected: PASS for the covered regressions before moving to the next bridge gap.

## Task 3: Align relay route and channel semantics last

**Files:**
- Modify: `crates/codepilot-relay-worker/src/lib.rs`
- Reference: `packages/relay/src/*`
- Test: relay worker route/channel tests when present

- [ ] **Step 1: Compare Node relay routes and channel behaviors against Rust worker implementation**

Document differences in handshake/auth flow, peer connection state, message forwarding, and lifecycle cleanup.

- [ ] **Step 2: Add focused failing tests for the first missing relay behavior**

Keep the test scope on one route or one channel lifecycle rule at a time.

- [ ] **Step 3: Implement the minimal worker fix**

Match the Node baseline semantics without changing protocol contracts already stabilized in Tasks 1 and 2.

- [ ] **Step 4: Re-run relay tests and smoke-check bridge pairing through the relay path**

Run the available Rust worker tests plus any bridge-side smoke tests that exercise tunneled/relay connections.
