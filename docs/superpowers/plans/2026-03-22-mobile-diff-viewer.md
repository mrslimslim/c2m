# Mobile Diff Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-demand mobile diff viewer with paged hunk loading, while keeping session timelines lightweight and responsive.

**Architecture:** Extend the phone/bridge protocol with diff request messages, teach the bridge to assemble and cache structured unified diffs for a `code_change` event, and add an iOS diff state/store plus a dedicated SwiftUI viewer. Timeline cards stay summary-only and navigate into the new viewer instead of rendering patch text inline.

**Tech Stack:** TypeScript, Node.js bridge runtime, Swift Package Manager, SwiftUI, XCTest, pnpm

---

### Task 1: Protocol Diff Messages And Models

**Files:**
- Modify: `packages/protocol/src/messages.ts`
- Modify: `packages/protocol/src/events.ts`
- Modify: `packages/protocol/src/state.ts`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/AgentEvent.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/SessionInfo.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`

- [ ] **Step 1: Write the failing protocol decoding/encoding tests**

Add tests that prove Swift models can encode/decode:
- `diff_req`
- `diff_hunks_req`
- `diff_content`
- `diff_hunks_content`

- [ ] **Step 2: Run the targeted Swift protocol tests and watch them fail**

Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
Expected: FAIL because diff message/model types do not exist yet.

- [ ] **Step 3: Add shared protocol types in TypeScript and Swift**

Define:
- diff line, hunk, and file summary/detail models
- phone messages for diff requests
- bridge messages for diff responses
- any summary fields added to `code_change`

- [ ] **Step 4: Re-run the targeted protocol tests**

Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
Expected: PASS

### Task 2: Bridge Diff Parsing And Caching

**Files:**
- Create: `packages/bridge/src/diff/parser.ts`
- Create: `packages/bridge/src/diff/service.ts`
- Create: `packages/bridge/src/__tests__/diff-parser.test.ts`
- Create: `packages/bridge/src/__tests__/diff-service.test.ts`
- Modify: `packages/bridge/package.json`

- [ ] **Step 1: Write failing bridge tests for unified diff parsing and hunk pagination**

Cover:
- parsing unified diff text into file/hunk/line models
- truncating large hunks and files safely
- paginating hunks by `afterHunkIndex`
- caching repeated requests for the same `(sessionId, eventId)`

- [ ] **Step 2: Run the targeted bridge tests and watch them fail**

Run: `pnpm --filter @codepilot/bridge test -- diff-parser diff-service`
Expected: FAIL because parser/service modules do not exist yet.

- [ ] **Step 3: Implement the parser and service minimally**

Build a bridge-local diff service that:
- resolves the requested `code_change` event
- computes workspace diff text for the changed files
- parses it into structured file/hunk/line data
- returns first-hunk summaries for `diff_content`
- returns subsequent hunk slices for `diff_hunks_content`
- caches recent results behind explicit size limits

- [ ] **Step 4: Re-run the targeted bridge tests**

Run: `pnpm --filter @codepilot/bridge test -- diff-parser diff-service`
Expected: PASS

### Task 3: Bridge Message Handling For Diff Requests

**Files:**
- Modify: `packages/bridge/src/bridge.ts`
- Modify: `packages/bridge/src/session-store/event-log.ts`
- Test: `packages/bridge/src/__tests__/bridge.test.ts`
- Test: `packages/bridge/src/__tests__/session-event-store.test.ts`

- [ ] **Step 1: Write failing bridge integration tests for `diff_req` and `diff_hunks_req`**

Cover:
- valid `code_change` event lookup by `eventId`
- non-`code_change` event rejection
- missing event rejection
- diff response routing back to the requesting client

- [ ] **Step 2: Run the targeted bridge integration tests and watch them fail**

Run: `pnpm --filter @codepilot/bridge test -- bridge session-event-store`
Expected: FAIL because the bridge does not route diff request messages yet.

- [ ] **Step 3: Implement bridge handlers**

Wire the new messages into `Bridge.handleMessage`, reuse persisted event history to find the requested event, and call the diff service for:
- initial diff summary + first hunk
- subsequent hunk pages for a specific file

- [ ] **Step 4: Re-run the targeted bridge integration tests**

Run: `pnpm --filter @codepilot/bridge test -- bridge session-event-store`
Expected: PASS

### Task 4: iOS Diff State, Routing, And View Model

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/DiffStore.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionDetailViewModel.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/StoreSnapshotTests.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionDetailViewModelTests.swift`

- [ ] **Step 1: Write failing Swift tests for diff store and diff request flows**

Cover:
- requesting a diff marks loading state for `(sessionId, eventId)`
- routing `diff_content` stores first hunks
- routing `diff_hunks_content` appends additional hunks
- failures do not poison unrelated file or timeline state

- [ ] **Step 2: Run the targeted Swift tests and watch them fail**

Run: `swift test --package-path packages/ios/CodePilotKit --filter 'SessionDetailViewModelTests|StoreSnapshotTests'`
Expected: FAIL because `DiffStore` and new routing methods do not exist yet.

- [ ] **Step 3: Implement the diff store and request helpers**

Add:
- `DiffStore`
- router handling for `diff_content` and `diff_hunks_content`
- view-model methods for requesting initial diff payloads and additional hunks

- [ ] **Step 4: Re-run the targeted Swift tests**

Run: `swift test --package-path packages/ios/CodePilotKit --filter 'SessionDetailViewModelTests|StoreSnapshotTests'`
Expected: PASS

### Task 5: SwiftUI Diff Viewer And Timeline Navigation

**Files:**
- Create: `packages/ios/CodePilotApp/CodePilot/Files/DiffViewerView.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/Theme/CodePilotTheme.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionCopyInteractionSourceTests.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift`

- [ ] **Step 1: Add failing UI/source tests for the new viewer entry and lazy section structure**

Check for:
- `View Diff` navigation from `CodeChangeCard`
- dedicated `DiffViewerView`
- `LazyVStack` usage in the diff screen
- `Load next hunk` affordance

- [ ] **Step 2: Run the targeted source tests and watch them fail**

Run: `swift test --package-path packages/ios/CodePilotKit --filter 'SessionCopyInteractionSourceTests|SessionComposerLayoutSourceTests'`
Expected: FAIL because the new viewer and navigation code are not present yet.

- [ ] **Step 3: Implement the SwiftUI viewer minimally**

Build:
- summary card button state
- dedicated diff screen
- per-file sections with first-hunk rendering
- per-file `Load next hunk`
- `Open File` fallback

- [ ] **Step 4: Re-run the targeted source tests**

Run: `swift test --package-path packages/ios/CodePilotKit --filter 'SessionCopyInteractionSourceTests|SessionComposerLayoutSourceTests'`
Expected: PASS

### Task 6: End-To-End Verification

**Files:**
- Modify: `docs/ios-testing.md`

- [ ] **Step 1: Add manual verification notes for mobile diff viewing**

Document:
- initial diff load
- paged hunk loading
- truncation behavior
- `Open File` fallback

- [ ] **Step 2: Run focused automated verification**

Run: `pnpm --filter @codepilot/bridge test`
Expected: PASS

Run: `swift test --package-path packages/ios/CodePilotKit`
Expected: PASS

- [ ] **Step 3: Run an app build smoke test**

Run: `xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CodePilot -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Review the diff for scope and performance regressions**

Run: `git diff --stat`
Expected: Changes limited to protocol, bridge diff handling, iOS state/UI, and docs.
