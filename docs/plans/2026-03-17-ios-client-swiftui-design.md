# CodePilot iOS SwiftUI Client Design

**Topic:** Native SwiftUI iOS client for CodePilot Bridge and Relay

**Goal:** Build a self-use / TestFlight iOS client that can pair with CodePilot over LAN or Relay, prefer E2E encryption, send agent commands, continue sessions, cancel turns, inspect changed files, and expose enough diagnostics to debug real-world connectivity issues.

## Scope

- Create a pure native iOS app with SwiftUI.
- Support three pairing flows: QR scan, deep link / pasted pairing payload, and manual entry.
- Support both connection modes already present in the bridge code:
  - LAN: `host + port + bridge_pubkey + otp`, with legacy `token` as an advanced fallback
  - Relay: `relay + channel + bridge_pubkey + otp`
- Implement the current message surface from `@codepilot/protocol` plus the transport-only frames the runtime already emits:
  - `auth`, `auth_ok`, `auth_failed`
  - `relay_peer_connected`, `relay_peer_disconnected`
- Provide a developer-focused UI with:
  - saved connections
  - session list
  - session detail timeline
  - command composer
  - cancel action
  - file viewer
  - diagnostics
- Persist enough local state to make reconnection and session continuity practical during TestFlight use.

## Non-Goals

- App Store-specific compliance hardening in this phase
- Editing project files from iOS or writing changes back to disk
- Perfect replay recovery across relay reconnects
- Full cross-platform SDK extraction before the iOS client proves itself
- Full collaboration / multi-user coordination semantics

## Recommended Approach

1. Build a native SwiftUI app and keep the iOS-specific UI in an app target.
2. Put protocol, crypto, transport, and state management into a local Swift package so they are testable outside the app shell.
3. Treat E2E as the default connection path and keep token auth as a LAN-only advanced fallback.
4. Prioritize protocol compatibility tests and connection state-machine tests before polishing UI flows.

## Architecture

Use a four-layer structure:

- `CodePilotProtocol`
  - Swift `Codable` models for `PhoneMessage`, `BridgeMessage`, `AgentEvent`, `SessionInfo`, `EncryptedWireMessage`
  - transport-only frames for local auth and relay control messages
- `CodePilotCore`
  - `ConnectionConfig`
  - `BridgeTransport`
  - `E2ECryptoSession`
  - `BridgeConnectionController`
  - `SessionStore`
  - `TimelineStore`
  - `FileStore`
  - `DiagnosticsStore`
- `CodePilotFeatures`
  - pairing flow
  - connections list
  - sessions list
  - session detail
  - file viewer
  - diagnostics screen
- `CodePilotApp`
  - app entry point
  - dependency wiring
  - navigation shell
  - platform permissions and app resources

This split keeps SwiftUI thin while putting the risky parts, protocol compatibility, crypto, connection state, and session routing, under direct unit test coverage.

## Connection And Security Design

- Pairing entry points:
  - QR scan is the main path
  - deep link / pasted payload is the fast developer path
  - manual entry is the fallback
- Connection modes:
  - LAN uses `ws://` and should prefer E2E handshake; token-only auth stays behind an advanced option
  - Relay uses `wss://.../ws?device=phone&channel=...` and always requires E2E
- Crypto implementation:
  - `CryptoKit.Curve25519.KeyAgreement`
  - HKDF-SHA256 with `salt = otp`, `info = "codepilot-e2e-v1"`
  - AES-GCM using the existing wire envelope `{ v, nonce, ciphertext, tag }`
- Connection state machine:
  - `idle`
  - `openingSocket`
  - `handshaking`
  - `encryptedReady`
  - `syncingSessions`
  - `connected`
  - `reconnecting`
  - `failed`
- Every connection attempt should generate a fresh local X25519 key pair and a new in-memory crypto session.
- Relay control frames must stay in the transport layer and should not appear as normal timeline items.

## Session And Timeline Design

- Maintain a `SessionStore` keyed by `SessionInfo.id`.
- Track `activeSessionId` separately from the stored session list.
- Handle Codex session remap explicitly:
  - if a temporary session ID is replaced by a real session ID, migrate local timeline, draft state, and active selection to the latest ID
- Model the session timeline as `TimelineItem`, not as plain chat messages:
  - `system`
  - `userCommand`
  - `status`
  - `thinking`
  - `agentMessage`
  - `codeChange`
  - `commandExec`
  - `turnCompleted`
  - `sessionError`
  - `transportError`
- Treat top-level bridge `error` and session-scoped `event.error` differently.

## Product UX

The iOS client should behave like a compact mobile command center for development work, not a generic chat client.

Primary screens:

1. `Connections`
   - saved bridges
   - connect / disconnect
   - QR scan
   - paste or manual pairing
2. `Sessions`
   - all known sessions
   - agent type
   - current state
   - last active time
3. `Session Detail`
   - event timeline
   - composer
   - cancel button while busy
   - code change taps into file viewer
4. `File Viewer`
   - read-only source display
   - path and language metadata
   - loading and access-denied states
5. `Diagnostics`
   - connection mode
   - E2E status
   - recent latency
   - reconnect attempts
   - recent transport / system logs

## Error Handling

- Separate error classes:
  - transport
  - protocol
  - session execution
  - file access
- Prefer conservative recovery:
  - if connection state becomes uncertain, refresh `session_list`
  - if decryption fails, force a fresh pairing / reconnect flow
  - if relay replays stale frames, ignore anything that cannot be decoded under the current crypto session
- Expose actionable messages to the user and keep raw payload details in diagnostics instead of the main timeline.

## Platform Requirements

- Target iOS 17+ to keep SwiftUI, Observation, and concurrency usage modern.
- Configure:
  - camera permission for QR scanning
  - local network usage description
  - ATS exceptions for local `ws://` / `http://` development traffic
- Persist secrets in Keychain and keep only non-sensitive view state in `UserDefaults`.

## Verification

- `swift test --package-path apps/ios/CodePilotKit`
- `xcodebuild -project apps/ios/CodePilotApp/CodePilot.xcodeproj -scheme CodePilot -destination 'generic/platform=iOS Simulator' build`
- manual LAN pairing with a running bridge
- manual Relay pairing with a running relay channel
- real-device checks for:
  - QR scanning
  - local network permission prompts
  - disconnect / reconnect handling
  - file viewer and cancel flows
