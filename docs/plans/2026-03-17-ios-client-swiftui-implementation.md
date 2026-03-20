# CodePilot iOS SwiftUI Client Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native SwiftUI iOS client that can pair with CodePilot over LAN or Relay, stream agent events, preserve sessions, cancel turns, inspect files, and surface diagnostics for self-use / TestFlight testing.

**Architecture:** Create a local Swift package for protocol, crypto, transport, and state management, then wire a thin SwiftUI app target on top of it. Keep the highest-risk areas, protocol compatibility, E2E encryption, reconnect logic, and session routing, covered by Swift package tests before polishing the app shell.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Concurrency, CryptoKit, URLSessionWebSocketTask, AVFoundation, XCTest, local Swift Package Manager modules

---

**Execution note:** this workspace is not currently inside a Git repository, so `@superpowers:using-git-worktrees` and the commit steps below should be executed from the real git-backed repo root before implementation starts.

### Task 1: Create the shared Swift package and protocol model surface

**Files:**
- Create: `packages/ios/CodePilotKit/Package.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/AgentEvent.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/SessionInfo.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/TransportFrames.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`

**Step 1: Write the failing test**

- Add decoding and encoding tests for:
  - `command`, `cancel`, `file_req`, `list_sessions`, `ping`
  - `event`, `session_list`, `file_content`, `pong`, `error`
  - `status`, `thinking`, `code_change`, `command_exec`, `agent_message`, `turn_completed`
  - transport-only frames: `auth`, `auth_ok`, `auth_failed`, `relay_peer_connected`, `relay_peer_disconnected`
- Add a fixture that proves unknown frame types are rejected without crashing.

**Step 2: Run test to verify it fails**

Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`

Expected: FAIL because the package and protocol models do not exist yet.

**Step 3: Write minimal implementation**

- Create the Swift package with three library targets:
  - `CodePilotProtocol`
  - `CodePilotCore`
  - `CodePilotFeatures`
- Implement `Codable` model enums and structs that mirror the current TypeScript protocol.
- Keep transport-only frames separate from app-layer protocol frames so connection logic can handle them before routing.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`

Expected: PASS for all protocol model tests.

**Step 5: Commit**

```bash
git add packages/ios/CodePilotKit
git commit -m "feat: add iOS protocol package"
```

### Task 2: Implement E2E crypto compatibility and encrypted wire handling

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/E2ECryptoSession.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/EncryptedWireCodec.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/CryptoCompatibilityTests.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/Fixtures/crypto-fixtures.json`

**Step 1: Write the failing test**

- Add tests that verify:
  - X25519 public key export matches the bridge's raw 32-byte base64 format
  - HKDF derives the same 32-byte session key as the bridge for a fixed fixture
  - AES-GCM decrypts a fixture produced by the bridge implementation
  - the Swift encoder produces an `EncryptedWireMessage` that can be decoded back losslessly

**Step 2: Run test to verify it fails**

Run: `swift test --package-path packages/ios/CodePilotKit --filter CryptoCompatibilityTests`

Expected: FAIL because crypto session and wire codec types do not exist yet.

**Step 3: Write minimal implementation**

- Build `E2ECryptoSession` with:
  - ephemeral X25519 key generation
  - HKDF-SHA256 using `otp` and `codepilot-e2e-v1`
  - AES-GCM encrypt / decrypt
- Build `EncryptedWireCodec` to convert between Swift types and the bridge envelope `{ v, nonce, ciphertext, tag }`.
- Load fixture data from JSON so the compatibility tests are stable.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path packages/ios/CodePilotKit --filter CryptoCompatibilityTests`

Expected: PASS and prove Swift crypto is wire-compatible with the bridge.

**Step 5: Commit**

```bash
git add packages/ios/CodePilotKit
git commit -m "feat: add iOS E2E crypto compatibility"
```

### Task 3: Build transport abstractions and the connection state machine

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/ConnectionConfig.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/ConnectionState.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/BridgeTransport.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/URLSessionBridgeTransport.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/BridgeConnectionController.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/DiagnosticsStore.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/BridgeConnectionControllerTests.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/TestDoubles/MockBridgeTransport.swift`

**Step 1: Write the failing test**

- Add controller tests for:
  - LAN E2E handshake success
  - LAN token fallback success
  - relay handshake success
  - relay control frame handling
  - handshake failure transitions to `failed`
  - encrypted sessions reject plaintext follow-up frames
  - reconnect moves through `reconnecting` back to `connected`

**Step 2: Run test to verify it fails**

Run: `swift test --package-path packages/ios/CodePilotKit --filter BridgeConnectionControllerTests`

Expected: FAIL because connection controller and transport abstractions do not exist yet.

**Step 3: Write minimal implementation**

- Create `ConnectionConfig` for:
  - LAN host / port / token / bridge pubkey / otp
  - Relay URL / channel / bridge pubkey / otp
- Implement `BridgeConnectionController` as the single state machine for socket opening, handshaking, encrypted routing, reconnect, and diagnostics logging.
- Keep relay control messages transport-scoped and do not leak them into session timelines.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path packages/ios/CodePilotKit --filter BridgeConnectionControllerTests`

Expected: PASS for all state-machine scenarios.

**Step 5: Commit**

```bash
git add packages/ios/CodePilotKit
git commit -m "feat: add iOS connection controller"
```

### Task 4: Add session, timeline, cancel, and file state management

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionStore.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/TimelineStore.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/FileStore.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionsViewModel.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionDetailViewModel.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionRoutingTests.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionDetailViewModelTests.swift`

**Step 1: Write the failing test**

- Add tests for:
  - `session_list` updates and active session selection
  - session ID remap migration
  - timeline item creation for every `AgentEvent` type
  - cancel action while a session is busy
  - `file_req` requests and file content routing
  - top-level bridge errors staying separate from session errors

**Step 2: Run test to verify it fails**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionRoutingTests`
Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionDetailViewModelTests`

Expected: FAIL because the session stores and view models do not exist yet.

**Step 3: Write minimal implementation**

- Route inbound bridge frames into:
  - `SessionStore`
  - `TimelineStore`
  - `FileStore`
  - `DiagnosticsStore`
- Represent the session timeline as structured `TimelineItem` values instead of plain chat messages.
- Implement command send, cancel, and file request flows in the feature view models.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path packages/ios/CodePilotKit`

Expected: PASS for protocol, crypto, connection, and session-routing tests together.

**Step 5: Commit**

```bash
git add packages/ios/CodePilotKit
git commit -m "feat: add iOS session and timeline state"
```

### Task 5: Create the app target and connection, session, and file-viewer UI

**Files:**
- Create: `packages/ios/CodePilotApp/CodePilot.xcodeproj/project.pbxproj`
- Create: `packages/ios/CodePilotApp/CodePilot/App/CodePilotApp.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Connections/ConnectionsView.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Connections/QRScannerView.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionsView.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Files/FileViewerView.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Resources/Info.plist`
- Create: `packages/ios/CodePilotApp/CodePilot/Resources/PrivacyInfo.xcprivacy`

**Step 1: Write the failing test**

- Add at least one package-level view-model test for QR payload parsing and saved connection selection before wiring the UI.
- Add an app build target that will fail until the SwiftUI app and local package integration exist.

**Step 2: Run test to verify it fails**

Run: `swift test --package-path packages/ios/CodePilotKit --filter Connection`
Run: `xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CodePilot -destination 'generic/platform=iOS Simulator' build`

Expected: the Swift package parsing test fails or the Xcode build fails because the app target does not exist yet.

**Step 3: Write minimal implementation**

- Create the SwiftUI app shell and integrate the local Swift package.
- Build the five primary screens:
  - connections
  - sessions
  - session detail
  - file viewer
  - diagnostics entry point
- Add QR scanning, manual entry, and saved connection flows.
- Configure `Info.plist` and privacy metadata for camera and local network usage.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path packages/ios/CodePilotKit`
Run: `xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CodePilot -destination 'generic/platform=iOS Simulator' build`

Expected: package tests pass and the iOS app builds successfully for the simulator.

**Step 5: Commit**

```bash
git add packages/ios/CodePilotApp packages/ios/CodePilotKit
git commit -m "feat: add iOS app shell and primary views"
```

### Task 6: Add diagnostics, persistence, and TestFlight hardening

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/SavedConnectionStore.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/KeychainSecretStore.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Diagnostics/DiagnosticsViewModel.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Diagnostics/DiagnosticsView.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/Resources/Info.plist`
- Create: `docs/ios-testing.md`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SavedConnectionStoreTests.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/DiagnosticsViewModelTests.swift`

**Step 1: Write the failing test**

- Add tests for:
  - Keychain-backed secret persistence
  - reconnect logging and redacted diagnostics output
  - saved connection restore on cold launch
  - diagnostics latency updates after `ping` / `pong`

**Step 2: Run test to verify it fails**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SavedConnectionStoreTests`
Run: `swift test --package-path packages/ios/CodePilotKit --filter DiagnosticsViewModelTests`

Expected: FAIL because persistence and diagnostics models do not exist yet.

**Step 3: Write minimal implementation**

- Persist non-sensitive metadata separately from secrets.
- Redact tokens, OTP values, and raw ciphertext from diagnostics logs.
- Add a small manual verification guide for LAN, relay, reconnect, cancel, and file viewer checks.
- Finish ATS and permission entries needed for local-network and QR-based use.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path packages/ios/CodePilotKit`
Run: `xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CodePilot -destination 'generic/platform=iOS Simulator' build`

Expected: all package tests pass, the app builds, and the repo contains a repeatable iOS manual test checklist.

**Step 5: Commit**

```bash
git add packages/ios/CodePilotApp packages/ios/CodePilotKit docs/ios-testing.md
git commit -m "feat: harden iOS client for TestFlight"
```
