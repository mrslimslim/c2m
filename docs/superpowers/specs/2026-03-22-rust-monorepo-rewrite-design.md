# Rust Monorepo Rewrite Design

**Topic:** Rewrite the full CodePilot TypeScript monorepo in Rust while preserving the current mobile protocol and Cloudflare relay deployment model

**Date:** 2026-03-22

## Goal

Replace the current Node.js and TypeScript implementation of CodePilot with a Rust-based implementation across all runtime components:

- bridge
- shared protocol model
- Cloudflare relay worker

The rewrite should preserve current external behavior as closely as possible so the existing mobile client can continue working without a protocol redesign.

## Scope

This design covers:

- a new Rust Cargo workspace for all runtime components
- Rust equivalents for the current protocol message and event model
- Rust implementations of pairing state persistence and E2E encryption
- a Rust bridge CLI and local WebSocket transport
- Rust agent adapters for Codex and Claude
- a Rust Cloudflare Worker relay using Durable Objects
- a staged migration plan that allows the TypeScript implementation to remain as a verification baseline during the rewrite

## Non-Goals

- redesigning the mobile protocol
- changing the pairing UX or QR payload shape
- rethinking the product architecture around a different transport model
- replacing Cloudflare Workers with a generic server deployment for relay
- introducing new user-facing features as part of the rewrite
- replacing every build artifact with pure native binaries when the platform requires generated glue code

## Problem

The current repository is a TypeScript monorepo with three distinct runtime targets:

- `packages/protocol` defines the shared wire model
- `packages/bridge` runs as a local Node.js process and coordinates transport, pairing, sessions, diff loading, replay, and agent adapters
- `packages/relay` runs on Cloudflare Workers with Durable Objects for cross-network message forwarding

This structure works, but it means the core system behavior is split across different JavaScript runtimes:

- Node.js for the bridge
- Cloudflare Worker JavaScript for relay
- TypeScript type sharing for protocol

The rewrite request is not a single-package port. It is a full runtime migration across native and edge targets while retaining current product behavior:

- CLI flags should stay familiar
- the mobile client should not need a coordinated protocol rewrite
- current pairing material should remain usable
- relay should continue to run on Cloudflare Durable Objects

That means the correct problem is:

> How do we move the implementation language to Rust without breaking compatibility at the protocol, deployment, and operational boundaries that already exist?

## Recommended Approach

Use a shared-protocol-first, staged rewrite.

The rewrite should not begin with a full replacement of the bridge runtime. Instead, it should establish a Rust workspace with stable shared contracts first, then migrate the runtime pieces in an order that minimizes compatibility risk.

Recommended order:

1. create the Rust workspace and crate boundaries
2. port the protocol model to Rust with strict JSON compatibility
3. port pairing and crypto primitives and verify they interoperate with the existing TypeScript implementation
4. port the Cloudflare relay to Rust using `workers-rs`
5. port bridge core services that do not depend on agent process integration
6. port the Codex and Claude adapters
7. switch the bridge CLI and runtime to Rust
8. retire the TypeScript implementation only after compatibility and behavior checks pass

This order is preferable because:

- protocol mismatches are the highest-risk failure mode and should be fixed first
- crypto compatibility can be verified independently from transport and UI
- relay has a narrow and well-bounded responsibility, making it a good early runtime target
- agent adapters are the least stable boundary and should be moved later, after the supporting bridge infrastructure exists

## Compatibility Contract

The rewrite must preserve the following contracts unless a later explicit product decision changes them:

### Mobile Protocol

All current `PhoneMessage`, `BridgeMessage`, `AgentEvent`, `SessionInfo`, diff payload, replay message, slash catalog, and handshake message shapes remain unchanged on the wire.

Rules:

- keep existing JSON field names
- keep current enum string values
- preserve optional field behavior
- preserve event ordering guarantees
- preserve `eventId` replay semantics

### CLI Contract

The bridge CLI should preserve the current operational interface:

- `--agent <codex|claude|auto>`
- `--dir <path>`
- `--tunnel`

The Rust implementation may add internal flags later, but the current interface should continue to work.

### Pairing State Compatibility

The pairing material file location and file format should stay compatible with the current implementation:

- location pattern: `~/.codepilot/pairing/<workDirHash>.json`
- fields:
  - `version`
  - `privateKeyBase64`
  - `otp`
  - `token`

This allows existing pairings to continue working after migration.

### Relay Deployment Contract

Relay continues to deploy on Cloudflare Workers with Durable Objects. The implementation moves to Rust, but the deployment model does not.

Important constraint:

- the source of truth for relay business logic becomes Rust
- the built Worker artifact may still include generated JavaScript glue produced by the official Rust Worker toolchain

This is acceptable because the user requirement is a Rust rewrite of the codebase, not a rejection of platform-required build glue.

## Target Workspace Structure

Create a Cargo workspace at the repository root.

Suggested structure:

```text
Cargo.toml
crates/
  codepilot-protocol/
  codepilot-core/
  codepilot-agents/
  codepilot-bridge/
  codepilot-relay-worker/
```

### `codepilot-protocol`

Responsibility:

- wire types shared by bridge, relay, and tests
- `serde` encode and decode compatibility
- protocol constants and capability flags

Suggested contents:

- session types
- event types
- bridge and phone message enums
- slash catalog structures
- diff structures
- encrypted wire message structure

This crate should have no runtime networking logic.

### `codepilot-core`

Responsibility:

- E2E crypto
- pairing state loading and persistence
- path validation and sensitive file filtering
- session event log persistence
- diff generation and truncation rules
- slash catalog generation
- adapter version detection helpers

This crate is the shared operational core for bridge runtime behavior.

### `codepilot-agents`

Responsibility:

- adapter trait definitions
- Codex adapter
- Claude adapter

This crate should expose a single internal abstraction similar to the current `AgentAdapter` contract:

- start session
- execute
- resume session
- cancel
- delete session

### `codepilot-bridge`

Responsibility:

- bridge orchestrator
- local WebSocket transport
- CLI entrypoint
- tunnel startup integration
- routing between transport and adapters
- replay state coordination

This crate is the native runtime entrypoint and should produce the main executable.

### `codepilot-relay-worker`

Responsibility:

- Cloudflare Worker fetch entrypoint
- Durable Object implementation for channel relay
- WebSocket forwarding and offline message cache

This crate should be compiled for the Cloudflare Worker Rust toolchain and preserve current route behavior:

- `GET /health`
- `GET /ws?device=bridge|phone&channel=...`
- `OPTIONS` preflight behavior

## Key Technical Decisions

### Protocol Representation

Use `serde` with explicit tagging and rename control to preserve current JSON shapes exactly.

Guidelines:

- use string enums for all current discriminants
- use adjacently or internally tagged enums only where they match the current payload shape
- write encode and decode tests from captured TypeScript-compatible JSON examples

This crate is the compatibility anchor for the entire rewrite.

### Crypto And Pairing

Keep the current cryptographic scheme unchanged:

- X25519 key exchange
- HKDF-SHA256 with the OTP as salt
- AES-256-GCM for message encryption

Rust code should reproduce current semantics exactly:

- raw 32-byte public key base64 handling
- SPKI and PKCS8 compatibility for persisted keys
- 12-byte nonce handling
- 16-byte GCM tag serialization

Cross-language verification is required before the old bridge is retired:

- Rust encrypt -> TypeScript decrypt
- TypeScript encrypt -> Rust decrypt
- Rust-derived session keys match TypeScript-derived keys for the same handshake inputs

### Bridge Runtime

Use an async Rust runtime for the bridge.

Recommended stack:

- `tokio` for async runtime and process control
- `axum` or `tokio-tungstenite` for local WebSocket transport
- `clap` for CLI parsing
- `serde_json` for payload serialization

The transport must preserve the current handshake behavior:

- unauthenticated socket accepts only handshake or legacy auth bootstrap
- after handshake, all phone and bridge messages are encrypted
- invalid encrypted payloads return protocol-compatible error responses

### Agent Integration

The Rust rewrite should not depend on the Node.js `@openai/codex-sdk`.

Instead:

- Codex integration should talk directly to the installed `codex` CLI and parse its streaming output
- Claude integration should continue to spawn the `claude` CLI and parse `stream-json`

Why:

- this removes a Node.js runtime dependency from the Rust bridge
- it aligns both adapters under one process-spawn and stream-parse model
- it keeps the bridge in full control of session lifecycle and event mapping

Trade-off:

- Codex CLI stream parsing is a more implementation-sensitive boundary than the current SDK wrapper
- adapter compatibility tests therefore become a first-class migration requirement

### Relay On Cloudflare

Use `workers-rs` for the Rust relay implementation and keep Durable Objects.

The Rust relay should preserve the current channel behavior:

- one `bridge` socket and one `phone` socket per channel role
- replacement of existing role connection when a new one arrives
- direct forwarding of ciphertext without decrypting
- offline caching of up to 100 messages
- expiry window of 24 hours
- peer connect and disconnect notifications

The relay should remain intentionally dumb:

- no protocol awareness beyond route and role validation
- no E2E decryption
- no session semantics

### Session Replay And Event Persistence

The Rust bridge should preserve the current append-only event log behavior and canonical session remap handling.

Rules:

- persist before delivery
- assign monotonic per-session `eventId`
- preserve alias-to-canonical session resolution
- avoid out-of-order replay/live interleaving for a given client-session pair

The existing event store location and file model should be retained unless implementation details force a narrow change:

- `~/.codepilot/sessions/<workDirHash>/index.json`
- `~/.codepilot/sessions/<workDirHash>/events/<sessionId>.jsonl`

## Migration Plan

### Phase 1: Workspace And Contracts

Create the Cargo workspace, set repository-wide toolchain expectations, and port the shared protocol types.

Deliverables:

- root `Cargo.toml`
- `rust-toolchain.toml`
- `codepilot-protocol` crate
- JSON compatibility tests for protocol payloads

Exit criteria:

- Rust can encode and decode all known protocol payload classes used by bridge and relay

### Phase 2: Core Compatibility Modules

Port the non-networking core modules.

Deliverables:

- pairing state loader and saver
- crypto compatibility module
- path sandbox validation
- session event log store
- diff parsing and truncation model

Exit criteria:

- Rust modules pass unit tests and cross-language compatibility fixtures where applicable

### Phase 3: Relay Worker

Port the Cloudflare relay to Rust.

Deliverables:

- Rust Worker fetch entrypoint
- Durable Object channel implementation
- Worker build and deploy configuration

Exit criteria:

- `/health` and `/ws` behavior match the current implementation
- basic WebSocket forwarding works with bridge and phone clients

### Phase 4: Bridge Core Runtime

Build the Rust bridge orchestration and local transport.

Deliverables:

- bridge orchestrator
- local WebSocket server
- handshake and encrypted transport path
- replay-aware client delivery coordination
- CLI entrypoint

Exit criteria:

- a mock adapter can drive a full mobile-compatible bridge session

### Phase 5: Agent Adapters

Port Codex and Claude integrations.

Deliverables:

- Rust adapter trait and session model
- Codex CLI adapter
- Claude CLI adapter
- adapter event mapping tests

Exit criteria:

- bridge can execute live sessions against both supported agents

### Phase 6: Cutover And Cleanup

Switch primary scripts, docs, and deployment instructions to the Rust implementation and retire the TypeScript runtime sources.

Deliverables:

- updated build and run commands
- updated relay deployment instructions
- removal plan for TypeScript runtime packages after confidence is high

Exit criteria:

- Rust becomes the default supported implementation

## Testing Strategy

### Protocol Tests

- fixture-based JSON encode and decode tests
- compatibility snapshots for every message family

### Crypto Tests

- deterministic derivation fixtures
- Rust-to-TypeScript compatibility vectors
- malformed payload rejection tests

### Bridge Tests

- session remap behavior
- replay queue ordering
- encrypted message validation
- file request sandbox protection
- diff request and hunk pagination
- slash action routing

### Relay Tests

- role validation
- replacement connection behavior
- offline cache delivery
- message expiry
- peer notification behavior

### End-To-End Verification

Before retiring TypeScript, run parity checks against:

- local pairing flow
- mobile command execution
- session replay after reconnect
- diff loading
- slash catalog delivery
- Cloudflare relay forwarding

## Risks

### Codex Adapter Drift

Moving from `@openai/codex-sdk` to direct CLI integration may expose differences in stream behavior or session identity handling.

Mitigation:

- isolate Codex parsing logic behind a narrow adapter layer
- build parser tests from captured event streams
- keep TypeScript implementation available as a behavioral reference until parity is established

### Cloudflare Rust Tooling Constraints

Cloudflare Rust Worker support introduces Wasm packaging and generated glue code that differs from the current TypeScript deployment flow.

Mitigation:

- keep the relay crate narrowly scoped
- preserve route and Durable Object semantics
- treat generated glue as a build artifact, not application logic

### Cross-Language Crypto Mismatch

Any byte-level mismatch in key encoding, HKDF inputs, nonce handling, or tag serialization would break mobile communication.

Mitigation:

- port crypto before the rest of the transport stack
- add cross-language test vectors early
- do not change message envelope shapes

### Rewrite Scope Creep

A full-language migration can easily expand into a product redesign.

Mitigation:

- preserve external contracts by default
- defer new features
- sequence the rewrite around existing behavior parity

## Open Implementation Guidance

These points are intentionally left as plan-level decisions rather than design-level blockers:

- whether the bridge transport uses `axum` or raw `tokio-tungstenite`
- exact crate dependency boundaries between `codepilot-core` and `codepilot-agents`
- whether tunnel startup remains shell-based or moves to a Rust-native integration path
- whether relay storage tests use local mocks, Worker test harnesses, or both

They should be resolved in the implementation plan, not by reopening the architecture.

## Success Criteria

The rewrite is successful when:

- the bridge runs as a Rust executable
- the relay runs on Cloudflare Workers from Rust source
- the mobile client can connect without protocol changes
- pairing state remains compatible
- both Codex and Claude sessions function end to end
- session replay and diff loading remain intact
- the TypeScript runtime implementation can be retired without loss of current capability
