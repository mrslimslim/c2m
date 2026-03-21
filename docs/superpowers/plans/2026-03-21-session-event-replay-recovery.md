# Session Event Replay Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bridge-side session event persistence and replay so the iOS client can reconnect after network interruptions or app relaunches and automatically fill any missing conversation events without duplicating timeline entries.

**Architecture:** Extend the shared wire protocol with replay-aware message types and per-event `eventId`, then make the bridge persist append-only per-session event logs and fan out events through a replay-aware delivery hub instead of binding output to one transient client. On iOS, keep local conversation snapshots but add per-session replay cursors and a small sync coordinator so reconnect flows request missing events and apply them idempotently.

**Tech Stack:** TypeScript, Node.js, JSONL persistence, pnpm workspaces, Swift 6, Swift Package Manager, SwiftUI app state, XCTest, node:test

---

**Execution note:** The current checkout already has unrelated modified files. Implement this plan from a dedicated git worktree or branch, and do not revert unrelated local changes while landing the replay work.

## File Map

### Shared Protocol

- `packages/protocol/src/messages.ts`
  - Extend `PhoneMessage` with `sync_session`
  - Extend `BridgeMessage.event` with `eventId`
  - Add `session_sync_complete`
- `packages/protocol/src/index.ts`
  - Re-export any new protocol types if needed by downstream packages

### Bridge

- `packages/bridge/src/transport/local.ts`
  - Validate `sync_session` payloads
- `packages/bridge/src/bridge.ts`
  - Replace single-client event forwarding with replay-aware per-client delivery
  - Handle `sync_session`
  - Use the event store before sending live events
- `packages/bridge/src/index.ts`
  - Re-export the new event-store helper if it becomes part of the bridge package surface
- `packages/bridge/src/session-store/event-log.ts`
  - Persist per-session JSONL event logs and session index metadata
- `packages/bridge/src/session-store/path.ts`
  - Resolve stable `~/.codepilot/sessions/<workDirHash>/...` storage paths
- `packages/bridge/src/__tests__/validation.test.ts`
  - Cover `sync_session` validation
- `packages/bridge/src/__tests__/bridge.test.ts`
  - Cover replay ordering, client reconnect sync, and temp-id remap continuity
- `packages/bridge/src/__tests__/session-event-store.test.ts`
  - Cover append, replay, and alias metadata persistence

### iOS Protocol And Core State

- `packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift`
  - Add `sync_session`
- `packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift`
  - Add `eventId` to `event`
  - Add `session_sync_complete`
- `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionStore.swift`
  - Persist and query `lastAppliedEventId` per session
  - Migrate replay cursors across session-id remaps
- `packages/ios/CodePilotKit/Sources/CodePilotCore/ConversationSnapshotStore.swift`
  - Persist the updated session snapshot schema
- `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift`
  - Apply event dedupe and gap detection based on `eventId`
- `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionReplayCoordinator.swift`
  - Track which sessions need sync after reconnect or gap detection
- `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`
  - Cover the new wire protocol variants
- `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/StoreSnapshotTests.swift`
  - Cover cursor persistence through snapshot restore
- `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionRoutingTests.swift`
  - Cover duplicate suppression, gap detection, and sync-complete remaps
- `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionReplayCoordinatorTests.swift`
  - Cover reconnect sync request generation

### iOS App Wiring

- `packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
  - Trigger replay sync after reconnect
  - Forward gap-recovery requests from the router/coordinator

## Task 1: Extend the wire protocol with replay message types

**Files:**
- Modify: `packages/protocol/src/messages.ts`
- Modify: `packages/protocol/src/index.ts`
- Modify: `packages/bridge/src/transport/local.ts`
- Test: `packages/bridge/src/__tests__/validation.test.ts`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`

- [ ] **Step 1: Write the failing protocol tests**

- Add bridge-side validation coverage for:
  - valid `sync_session` with `sessionId` and numeric `afterEventId`
  - invalid `sync_session` missing `sessionId`
  - invalid `sync_session` with non-numeric `afterEventId`
- Add iOS protocol model coverage for:
  - `PhoneMessage.syncSession(sessionId:afterEventId:)`
  - `BridgeMessage.event(..., eventId: ...)`
  - `BridgeMessage.sessionSyncComplete(...)`

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --filter @codepilot/protocol build && pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge exec node --test dist/__tests__/validation.test.js`
Expected: FAIL because `sync_session` is not part of the TypeScript protocol or local transport validation yet.

Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
Expected: FAIL because the Swift protocol enums do not decode or encode the replay fields yet.

- [ ] **Step 3: Implement the minimal protocol changes**

- Add `SyncSessionMessage` to `PhoneMessage` in TypeScript with:
  - `type: "sync_session"`
  - `sessionId: string`
  - `afterEventId: number`
- Extend `EventMessage` in TypeScript with `eventId: number`.
- Add `SessionSyncCompleteMessage` in TypeScript with:
  - `type: "session_sync_complete"`
  - `sessionId: string`
  - `latestEventId: number`
  - optional `resolvedSessionId: string`
- Update `validatePhoneMessage()` in `local.ts` to accept only well-formed `sync_session` messages.
- Mirror the same message surface in Swift `PhoneMessage` and `BridgeMessage`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm --filter @codepilot/protocol build && pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge exec node --test dist/__tests__/validation.test.js`
Expected: PASS.

Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
Expected: PASS with replay variants round-tripping correctly.

- [ ] **Step 5: Commit**

```bash
git add packages/protocol/src/messages.ts packages/protocol/src/index.ts packages/bridge/src/transport/local.ts packages/bridge/src/__tests__/validation.test.ts packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift
git commit -m "feat: add replay protocol messages"
```

## Task 2: Build the bridge session event store

**Files:**
- Create: `packages/bridge/src/session-store/path.ts`
- Create: `packages/bridge/src/session-store/event-log.ts`
- Test: `packages/bridge/src/__tests__/session-event-store.test.ts`

- [ ] **Step 1: Write the failing bridge store tests**

- Add tests that prove:
  - the bridge derives a stable session storage root from `workDir`
  - appending events creates the expected JSONL log
  - replay after a cursor returns only newer events
  - alias remaps persist and resolve to the canonical session id
  - `latestEventId` survives a fresh store instance

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge exec node --test dist/__tests__/session-event-store.test.js`
Expected: FAIL because the session event store files do not exist yet.

- [ ] **Step 3: Implement the minimal event store**

- Create `path.ts` to derive:
  - `~/.codepilot/sessions/<workDirHash>/index.json`
  - `~/.codepilot/sessions/<workDirHash>/events/<sessionId>.jsonl`
- Create `event-log.ts` with focused responsibilities:
  - append a persisted event and return the assigned `eventId`
  - read replay events after a cursor
  - store and load session index metadata
  - resolve alias ids to canonical ids
- Keep the on-disk format append-only and JSON-based so it is easy to inspect during debugging.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge exec node --test dist/__tests__/session-event-store.test.js`
Expected: PASS and prove the store can append and replay deterministically.

- [ ] **Step 5: Commit**

```bash
git add packages/bridge/src/session-store/path.ts packages/bridge/src/session-store/event-log.ts packages/bridge/src/__tests__/session-event-store.test.ts
git commit -m "feat: persist bridge session event logs"
```

## Task 3: Integrate replay-aware bridge delivery and reconnect sync

**Files:**
- Modify: `packages/bridge/src/bridge.ts`
- Modify: `packages/bridge/src/index.ts`
- Test: `packages/bridge/src/__tests__/bridge.test.ts`

- [ ] **Step 1: Write the failing bridge integration tests**

- Add tests for:
  - a client reconnecting with `afterEventId = 3` receives replay events `4...n`
  - live events that arrive during replay are queued and flushed in `eventId` order
  - Codex temp session ids that remap to a real thread id still replay as a single session history
  - ongoing session output reaches a newly connected client after replay instead of staying bound to the stale original client

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge exec node --test dist/__tests__/bridge.test.js`
Expected: FAIL because `Bridge` still forwards events only to the original command client and has no replay path.

- [ ] **Step 3: Implement the minimal bridge replay flow**

- Instantiate the session event store in `Bridge`.
- Persist every `AgentEvent` before updating in-memory session state or sending it out.
- Track connected clients inside `Bridge` so delivery is not tied to the original `handleCommand()` caller.
- Add `sync_session` handling that:
  - resolves aliases
  - replays only missing events
  - queues live events for that `(clientId, sessionId)` while replay is running
  - emits `session_sync_complete`
- Preserve current `session_list`, cancel, delete, and file request behavior.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge exec node --test dist/__tests__/bridge.test.js dist/__tests__/session-event-store.test.js dist/__tests__/validation.test.js`
Expected: PASS for validation, persistence, replay, and bridge reconnect cases.

- [ ] **Step 5: Commit**

```bash
git add packages/bridge/src/bridge.ts packages/bridge/src/index.ts packages/bridge/src/__tests__/bridge.test.ts
git commit -m "feat: replay missing bridge session events"
```

## Task 4: Persist replay cursors in the iOS state model

**Files:**
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionStore.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotCore/ConversationSnapshotStore.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/StoreSnapshotTests.swift`

- [ ] **Step 1: Write the failing iOS state tests**

- Add tests that prove:
  - `SessionStoreSnapshot` preserves `lastAppliedEventIdBySessionID`
  - session-id remaps migrate replay cursors from temporary ids to canonical ids
  - `ConversationSnapshotStore` round-trips the updated session snapshot without data loss

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path packages/ios/CodePilotKit --filter StoreSnapshotTests`
Expected: FAIL because replay cursor state is not part of the session snapshot model yet.

- [ ] **Step 3: Implement the minimal cursor persistence**

- Extend `SessionStoreSnapshot` with `lastAppliedEventIdBySessionID`.
- Add `SessionStore` APIs for:
  - reading the last applied `eventId`
  - recording a newly applied `eventId`
  - migrating cursor state during alias remaps
- Keep `ConversationSnapshotStore` schema changes backward-compatible if possible:
  - missing cursor dictionaries should decode as empty state

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path packages/ios/CodePilotKit --filter StoreSnapshotTests`
Expected: PASS and prove replay cursors persist across cold launch snapshot restore.

- [ ] **Step 5: Commit**

```bash
git add packages/ios/CodePilotKit/Sources/CodePilotCore/SessionStore.swift packages/ios/CodePilotKit/Sources/CodePilotCore/ConversationSnapshotStore.swift packages/ios/CodePilotKit/Tests/CodePilotCoreTests/StoreSnapshotTests.swift
git commit -m "feat: persist iOS replay cursors"
```

## Task 5: Add replay-aware iOS routing and sync orchestration

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionReplayCoordinator.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionRoutingTests.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionReplayCoordinatorTests.swift`

- [ ] **Step 1: Write the failing routing and coordinator tests**

- Add router tests that prove:
  - duplicate `eventId` values are ignored
  - an `eventId` gap marks the session as needing replay instead of appending out-of-order items
  - `session_sync_complete` with `resolvedSessionId` migrates replay state correctly
- Add coordinator tests that prove:
  - reconnecting a known connection emits one `sync_session` request per known session with the stored cursor
  - a gap-triggered sync request is not enqueued repeatedly for the same missing range

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionRoutingTests`
Expected: FAIL because `SessionMessageRouter` is timestamp-only and appends duplicate events today.

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionReplayCoordinatorTests`
Expected: FAIL because the replay coordinator does not exist yet.

- [ ] **Step 3: Implement the minimal replay-aware iOS flow**

- Create `SessionReplayCoordinator` to own:
  - pending sync requests after reconnect
  - pending sync requests after gap detection
  - dedupe of identical sync work
- Update `SessionMessageRouter` to:
  - inspect `eventId`
  - suppress duplicates
  - advance the cursor on successful append
  - surface replay-needed callbacks when a gap appears
  - handle `session_sync_complete`
- Update `RootView` to:
  - issue `sync_session` requests after reconnect and after the initial `session_list`
  - forward gap-driven sync requests through the active connection controller
  - preserve current conversation snapshot persistence behavior

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionRoutingTests`
Expected: PASS.

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionReplayCoordinatorTests`
Expected: PASS.

Run: `swift test --package-path packages/ios/CodePilotKit`
Expected: PASS for the full Swift package after the replay changes.

- [ ] **Step 5: Commit**

```bash
git add packages/ios/CodePilotKit/Sources/CodePilotCore/SessionReplayCoordinator.swift packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift packages/ios/CodePilotApp/CodePilot/App/RootView.swift packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionRoutingTests.swift packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionReplayCoordinatorTests.swift
git commit -m "feat: recover iOS sessions with replay sync"
```

## Task 6: Run integrated verification and manual reconnect QA

**Files:**
- Verify only

- [ ] **Step 1: Run the TypeScript workspace tests**

Run: `pnpm run test:unit`
Expected: PASS with protocol and bridge changes compiled and tested together.

- [ ] **Step 2: Run the Swift package tests**

Run: `swift test --package-path packages/ios/CodePilotKit`
Expected: PASS.

- [ ] **Step 3: Do a manual bridge-to-iOS recovery check**

- Start the bridge from a disposable repo.
- Connect the iOS app or test client.
- Start a long-running command that emits several events.
- Disconnect the client after some output arrives.
- Reconnect and confirm:
  - the old timeline renders immediately from the local snapshot
  - the missing events are replayed in order
  - no duplicate timeline items appear
  - new live events continue after replay finishes

- [ ] **Step 4: Commit the final verified slice**

```bash
git add packages/protocol packages/bridge packages/ios
git commit -m "feat: add session replay recovery"
```
