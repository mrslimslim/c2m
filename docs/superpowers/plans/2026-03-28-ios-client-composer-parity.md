# iOS Client Composer Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add honest competitor-inspired composer parity to the iOS client with protocol-backed `@files`, header session switching, and press-to-talk speech input while preserving existing slash workflows and plain-text command sending.

**Architecture:** Extend the existing phone/bridge protocol with a small file-search request/response pair, implement project-scoped file search in the Rust bridge, and route results through a dedicated iOS `FileSearchStore`. Keep `/commands` grounded in the current slash catalog, layer a focused composer-interaction model on top of the existing session view, add a header-driven session switcher, and keep speech input local to iOS using native Speech and AVFoundation APIs.

**Tech Stack:** Rust workspace (`serde`, existing bridge runtime), Swift Package Manager, SwiftUI, XCTest, iOS Speech framework, AVFoundation

---

**Execution note:** This checkout already contains unrelated modified and untracked files. Execute this plan from a dedicated worktree or keep every commit narrowly staged. Do not revert unrelated local changes.

## File Structure

### Rust protocol and bridge

- Modify: `crates/codepilot-protocol/src/messages.rs`
  - Add `file_search_req` and `file_search_results` message variants.
- Modify: `crates/codepilot-protocol/src/state.rs`
  - Add a lightweight file-search result model shared by bridge and tests.
- Modify: `crates/codepilot-protocol/tests/protocol_json_roundtrip.rs`
  - Add JSON round-trip coverage for the new message shapes.
- Modify: `crates/codepilot-bridge/src/bridge.rs`
  - Handle file-search requests, scope them to the current project, and send bounded results.
- Modify: `crates/codepilot-bridge/tests/validation.rs`
  - Ensure local transport validation accepts the new phone message.
- Modify: `crates/codepilot-bridge/tests/bridge.rs`
  - Add bridge-level integration coverage for project-scoped search and result emission.

### Swift protocol and core state

- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/FileSearchModels.swift`
  - Define `FileSearchMatch` and related lightweight payload types for the Swift side.
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift`
  - Add `fileSearchRequest` to the phone message enum.
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift`
  - Add `fileSearchResults` to the bridge message enum.
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/FileSearchStore.swift`
  - Track per-session query, loading, error, and search results independently from file contents.
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift`
  - Route `file_search_results` into `FileSearchStore`.
- Modify: `packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
  - Own the new store, expose search APIs and lookup helpers, and seed preview data.
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionDetailViewModel.swift`
  - Add a typed API for sending search requests through the existing sender.

### Swift feature logic and UI

- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionComposerContext.swift`
  - Parse draft triggers, maintain selected file chips, and serialize final send text.
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionSwitcherSheet.swift`
  - Render the project-scoped searchable session switcher.
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/ComposerFileChipRow.swift`
  - Render selected file chips above the composer input.
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/PressToTalkButton.swift`
  - Encapsulate the press-and-hold speech button gesture and UI state.
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/SpeechTranscriber.swift`
  - Wrap Speech and AVFoundation APIs for local speech-to-text.
- Modify: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift`
  - Integrate chips, `@files` results, the header tap target, the session switcher sheet, and speech input.
- Modify: `packages/ios/CodePilotApp/CodePilot/Resources/Info.plist`
  - Add microphone and speech-recognition usage descriptions.

### Tests

- Modify: `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`
  - Cover new Swift message variants.
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/FileSearchStoreTests.swift`
  - Cover query/result/loading/error behavior.
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionRoutingTests.swift`
  - Verify router delivery into the new store.
- Create: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerContextTests.swift`
  - Cover trigger parsing, chip insertion/removal, and final serialization.
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionDetailViewModelTests.swift`
  - Cover the new file-search request sender API.
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift`
  - Lock the new chip row, session-switcher trigger, and press-to-talk control into source assertions.

## Task 1: Lock The File-Search Protocol Contract

**Files:**
- Modify: `crates/codepilot-protocol/src/messages.rs`
- Modify: `crates/codepilot-protocol/src/state.rs`
- Modify: `crates/codepilot-protocol/tests/protocol_json_roundtrip.rs`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/FileSearchModels.swift`
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`

- [ ] **Step 1: Write the failing Rust and Swift protocol tests first**

```rust
#[test]
fn phone_file_search_request_round_trips() {
    let raw = r#"{"type":"file_search_req","sessionId":"s1","query":"turnview","limit":12}"#;
    assert_json_roundtrip::<PhoneMessage>(raw);
}

#[test]
fn bridge_file_search_results_round_trips() {
    let raw = r#"{"type":"file_search_results","sessionId":"s1","query":"turnview","results":[{"path":"Sources/TurnView.swift","displayName":"TurnView.swift","directoryHint":"Sources"}]}"#;
    assert_json_roundtrip::<BridgeMessage>(raw);
}
```

```swift
try assertRoundTrip(
    PhoneMessage.self,
    json: #"{"type":"file_search_req","sessionId":"session-1","query":"turnview","limit":12}"#,
    expected: .fileSearchRequest(sessionId: "session-1", query: "turnview", limit: 12)
)
```

- [ ] **Step 2: Run the protocol tests to verify they fail for the missing message types**

Run: `cargo test -p codepilot-protocol protocol_json_roundtrip -- --nocapture`
Expected: FAIL because `file_search_req` / `file_search_results` are unknown variants.

Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
Expected: FAIL because the Swift message enums do not yet model the new cases.

- [ ] **Step 3: Add the minimal message and model types in Rust and Swift**

```rust
pub struct FileSearchMatch {
    pub path: String,
    pub display_name: Option<String>,
    pub directory_hint: Option<String>,
}

pub enum PhoneMessage {
    FileSearchReq { session_id: String, query: String, limit: u64 },
    // existing cases...
}
```

```swift
public struct FileSearchMatch: Codable, Equatable, Sendable {
    public let path: String
    public let displayName: String?
    public let directoryHint: String?
}

case fileSearchRequest(sessionId: String, query: String, limit: Int)
case fileSearchResults(sessionId: String, query: String, results: [FileSearchMatch])
```

- [ ] **Step 4: Run the protocol tests again to verify green**

Run: `cargo test -p codepilot-protocol protocol_json_roundtrip -- --nocapture`
Expected: PASS with the two new round-trip tests included.

Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
Expected: PASS with new Swift protocol cases encoded and decoded correctly.

- [ ] **Step 5: Commit the protocol contract**

```bash
git add crates/codepilot-protocol/src/messages.rs crates/codepilot-protocol/src/state.rs crates/codepilot-protocol/tests/protocol_json_roundtrip.rs packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift packages/ios/CodePilotKit/Sources/CodePilotProtocol/FileSearchModels.swift packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift
git commit -m "feat: add file search protocol messages"
```

## Task 2: Implement Project-Scoped File Search In The Bridge

**Files:**
- Modify: `crates/codepilot-bridge/src/bridge.rs`
- Modify: `crates/codepilot-bridge/tests/validation.rs`
- Modify: `crates/codepilot-bridge/tests/bridge.rs`

- [ ] **Step 1: Write the failing bridge validation and integration tests**

```rust
#[test]
fn validate_phone_message_accepts_file_search_requests() {
    assert_eq!(
        validate_phone_message(json!({
            "type": "file_search_req",
            "sessionId": "session-1",
            "query": "turnview",
            "limit": 12,
        }))
        .map(|message| matches!(message, PhoneMessage::FileSearchReq { .. })),
        Some(true)
    );
}

#[test]
fn bridge_returns_project_scoped_file_search_results() {
    // seed repo files, send FileSearchReq, assert BridgeMessage::FileSearchResults
}
```

- [ ] **Step 2: Run the bridge tests to verify the missing handler fails cleanly**

Run: `cargo test -p codepilot-bridge validation -- --nocapture`
Expected: FAIL because local message validation does not accept `file_search_req`.

Run: `cargo test -p codepilot-bridge bridge_returns_project_scoped_file_search_results -- --exact --nocapture`
Expected: FAIL because `Bridge::handle_message` has no file-search branch yet.

- [ ] **Step 3: Add the smallest truthful bridge implementation**

```rust
PhoneMessage::FileSearchReq {
    session_id,
    query,
    limit,
} => self.handle_file_search(client, &session_id, &query, limit),
```

```rust
fn handle_file_search(
    &self,
    client: Arc<dyn TransportClient>,
    session_id: &str,
    query: &str,
    limit: u64,
) -> Result<()> {
    let results = self.search_project_files(query, limit)?;
    client.send(BridgeMessage::FileSearchResults {
        session_id: session_id.to_owned(),
        query: query.to_owned(),
        results,
    });
    Ok(())
}
```

Implementation notes:
- Resolve results from `self.options.work_dir`.
- Return relative paths only.
- Bound the result count defensively.
- Sort deterministically for stable tests.

- [ ] **Step 4: Re-run the bridge tests to verify the new behavior**

Run: `cargo test -p codepilot-bridge validation -- --nocapture`
Expected: PASS with the new request accepted.

Run: `cargo test -p codepilot-bridge bridge_returns_project_scoped_file_search_results -- --exact --nocapture`
Expected: PASS and assert a `BridgeMessage::FileSearchResults` payload with repo-relative paths.

- [ ] **Step 5: Commit the bridge support**

```bash
git add crates/codepilot-bridge/src/bridge.rs crates/codepilot-bridge/tests/validation.rs crates/codepilot-bridge/tests/bridge.rs
git commit -m "feat: add bridge file search support"
```

## Task 3: Add iOS File-Search Store And Routing

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/FileSearchStore.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionDetailViewModel.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/FileSearchStoreTests.swift`
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionRoutingTests.swift`
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing store, router, and view-model tests**

```swift
func testFileSearchStoreTracksLoadingResultsAndErrorsPerSession() {
    let store = FileSearchStore()
    store.markRequested(query: "turnview", sessionId: "session-1")
    XCTAssertTrue(store.state(for: "session-1")?.isLoading == true)
}

func testRouterRoutesFileSearchResultsToStore() {
    router.handle(.fileSearchResults(
        sessionId: "session-1",
        query: "turnview",
        results: [.init(path: "Sources/TurnView.swift", displayName: "TurnView.swift", directoryHint: "Sources")]
    ))
    XCTAssertEqual(store.state(for: "session-1")?.results.count, 1)
}

func testViewModelSendsFileSearchRequest() throws {
    try viewModel.searchFiles(query: "turnview", limit: 12)
    XCTAssertEqual(sender.messages, [.fileSearchRequest(sessionId: "session-1", query: "turnview", limit: 12)])
}
```

- [ ] **Step 2: Run the targeted Swift tests to verify they fail**

Run: `swift test --package-path packages/ios/CodePilotKit --filter FileSearchStoreTests`
Expected: FAIL because `FileSearchStore` does not exist yet.

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionRoutingTests`
Expected: FAIL once the new routing assertions are added because the router ignores `fileSearchResults`.

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionDetailViewModelTests`
Expected: FAIL because the view model cannot yet send file-search requests.

- [ ] **Step 3: Implement the new store and minimal app plumbing**

```swift
public struct FileSearchState: Equatable, Sendable {
    public let query: String
    public let results: [FileSearchMatch]
    public let isLoading: Bool
    public let errorMessage: String?
}
```

```swift
case let .fileSearchResults(sessionId, query, results):
    fileSearchStore.routeResults(sessionId: targetSessionId, query: query, results: results)
```

Implementation notes:
- Keep search state separate from `FileStore`.
- Thread the store through `AppModel`, `SessionMessageRouter`, and preview setup.
- Add `AppModel` accessors for the active search state.

- [ ] **Step 4: Re-run the Swift tests to verify the state pipeline works**

Run: `swift test --package-path packages/ios/CodePilotKit --filter FileSearchStoreTests`
Expected: PASS with loading, results, and error coverage.

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionRoutingTests`
Expected: PASS with `fileSearchResults` routed into the new store.

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionDetailViewModelTests`
Expected: PASS with the new `searchFiles(query:limit:)` sender API.

- [ ] **Step 5: Commit the iOS core search pipeline**

```bash
git add packages/ios/CodePilotKit/Sources/CodePilotCore/FileSearchStore.swift packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift packages/ios/CodePilotApp/CodePilot/App/RootView.swift packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionDetailViewModel.swift packages/ios/CodePilotKit/Tests/CodePilotCoreTests/FileSearchStoreTests.swift packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SessionRoutingTests.swift packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionDetailViewModelTests.swift
git commit -m "feat: add ios file search state pipeline"
```

## Task 4: Build The Composer Interaction Model For `@files`

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionComposerContext.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerContextTests.swift`

- [ ] **Step 1: Write failing tests for trigger parsing and send serialization**

```swift
func testDetectsActiveFileSearchTriggerFromDraftTail() {
    var context = SessionComposerContext(draft: "@turnv")
    XCTAssertEqual(context.activeFileSearchQuery, "turnv")
}

func testSelectingFileConvertsTailIntoChipAndLeavesRemainingDraft() {
    var context = SessionComposerContext(draft: "@turnv explain this")
    context.insertFile(.init(path: "Sources/TurnView.swift", displayName: "TurnView.swift", directoryHint: "Sources"))
    XCTAssertEqual(context.selectedFiles.map(\.path), ["Sources/TurnView.swift"])
    XCTAssertEqual(context.draft, " explain this")
}

func testSerializedSendTextPrefixesSelectedFilesAsPlainTextMentions() {
    var context = SessionComposerContext(draft: "Explain this view")
    context.selectedFiles = [.init(path: "Sources/TurnView.swift", displayName: "TurnView.swift", directoryHint: "Sources")]
    XCTAssertEqual(context.serializedCommandText, "@Sources/TurnView.swift Explain this view")
}
```

- [ ] **Step 2: Run the feature tests to verify the context model does not exist yet**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionComposerContextTests`
Expected: FAIL because the composer context type has not been implemented.

- [ ] **Step 3: Implement the smallest pure-Swift model that covers trigger parsing and chips**

```swift
public struct ComposerFileChip: Equatable, Sendable {
    public let path: String
    public let displayName: String
}

public struct SessionComposerContext: Equatable, Sendable {
    public var draft: String
    public var selectedFiles: [FileSearchMatch]

    public var activeFileSearchQuery: String? { /* parse trailing @token */ }
    public var serializedCommandText: String { /* prefix selected file paths */ }
}
```

Implementation notes:
- Keep it deterministic and free of SwiftUI dependencies.
- Do not build a rich-text editor.
- Preserve user-entered spacing intentionally where practical.

- [ ] **Step 4: Re-run the context tests to verify green**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionComposerContextTests`
Expected: PASS with trigger parsing, chip insertion, and serialization covered.

- [ ] **Step 5: Commit the composer model**

```bash
git add packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionComposerContext.swift packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerContextTests.swift
git commit -m "feat: add composer file reference state"
```

## Task 5: Integrate Chips And Header Session Switching Into The Conversation UI

**Files:**
- Modify: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/ComposerFileChipRow.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionSwitcherSheet.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift`
- Optionally modify: `packages/ios/CodePilotApp/CodePilot/Projects/ProjectDetailView.swift`
  - Only if shared UI helpers or “start new session” affordances need parity updates.

- [ ] **Step 1: Write the failing source-level assertions for chips and session switching**

```swift
XCTAssertTrue(
    source.contains("SessionSwitcherSheet("),
    "Session detail should present a searchable session switcher from the header."
)

XCTAssertTrue(
    source.contains("ComposerFileChipRow("),
    "Session detail should render selected file chips above the composer input."
)

XCTAssertTrue(
    source.contains("onTapGesture") && source.contains("showSessionSwitcher = true"),
    "The conversation header should open the session switcher."
)
```

- [ ] **Step 2: Run the source tests to verify they fail before UI changes**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionComposerLayoutSourceTests`
Expected: FAIL because the current session detail source has no chip row or session-switcher sheet.

- [ ] **Step 3: Implement the UI in small, focused components**

```swift
@State private var composerContext = SessionComposerContext()
@State private var showSessionSwitcher = false
```

```swift
SessionSwitcherSheet(
    sessions: appModel.sessionsForConnection(connectionID),
    activeSessionID: sessionID,
    onSelect: { selected in /* navigate */ }
)
```

Implementation notes:
- Keep `SessionDetailView` focused on orchestration.
- Move chip-row rendering into `ComposerFileChipRow`.
- Use the existing title area as the tap target for the session switcher.
- Serialize `composerContext.serializedCommandText` at send time.
- Reuse existing slash behavior rather than inventing a new command surface.

- [ ] **Step 4: Re-run the source tests and a broad Swift package pass**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionComposerLayoutSourceTests`
Expected: PASS with the new session-switcher and chip-row assertions.

Run: `swift test --package-path packages/ios/CodePilotKit`
Expected: PASS with no regressions in protocol, core, or feature tests.

- [ ] **Step 5: Commit the UI parity work**

```bash
git add packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift packages/ios/CodePilotApp/CodePilot/Sessions/ComposerFileChipRow.swift packages/ios/CodePilotApp/CodePilot/Sessions/SessionSwitcherSheet.swift packages/ios/CodePilotApp/CodePilot/App/RootView.swift packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift
git commit -m "feat: add session composer chips and switcher"
```

## Task 6: Add Press-To-Talk Speech Input

**Files:**
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/PressToTalkButton.swift`
- Create: `packages/ios/CodePilotApp/CodePilot/Sessions/SpeechTranscriber.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/Resources/Info.plist`
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift`

- [ ] **Step 1: Add the failing UI/source assertions for the new speech control**

```swift
XCTAssertTrue(
    source.contains("PressToTalkButton("),
    "Session detail should include a press-to-talk control in the composer row."
)

XCTAssertTrue(
    source.contains("onPressingChanged"),
    "The speech control should use a press lifecycle instead of a tap-only toggle."
)
```

- [ ] **Step 2: Run the source tests to verify the speech control is absent**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionComposerLayoutSourceTests`
Expected: FAIL because the composer currently has no press-to-talk control.

- [ ] **Step 3: Implement the smallest local speech wrapper and wire it into the composer**

```swift
final class SpeechTranscriber: ObservableObject {
    func beginCapture() { /* request permissions, start engine */ }
    func endCapture() async -> String? { /* stop and return text */ }
}
```

```swift
PressToTalkButton(
    onPressStart: { transcriber.beginCapture() },
    onPressEnd: { recognizedText in draft = appendSpeechResult(recognizedText, to: draft) }
)
```

Implementation notes:
- Add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- Do not auto-send recognized text.
- Preserve any existing draft text on errors.
- Keep platform-specific code in the app target, not `CodePilotKit`.

- [ ] **Step 4: Re-run the source tests and do one focused build/test pass**

Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionComposerLayoutSourceTests`
Expected: PASS with the press-to-talk assertions included.

Run: `swift test --package-path packages/ios/CodePilotKit`
Expected: PASS; note that Speech framework behavior still needs simulator/device manual QA.

- [ ] **Step 5: Commit the speech input support**

```bash
git add packages/ios/CodePilotApp/CodePilot/Sessions/PressToTalkButton.swift packages/ios/CodePilotApp/CodePilot/Sessions/SpeechTranscriber.swift packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift packages/ios/CodePilotApp/CodePilot/Resources/Info.plist packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift
git commit -m "feat: add press to talk composer input"
```

## Task 7: Final Regression Pass And Manual QA Notes

**Files:**
- Modify: `docs/debugging.md` only if implementation reveals a new required debug workflow
- Otherwise no doc changes required in this task

- [ ] **Step 1: Run focused Rust and Swift regression suites**

Run: `cargo test -p codepilot-protocol`
Expected: PASS.

Run: `cargo test -p codepilot-bridge`
Expected: PASS, including the new file-search coverage.

Run: `swift test --package-path packages/ios/CodePilotKit`
Expected: PASS.

- [ ] **Step 2: Run manual conversation-flow QA in the iOS app**

Checklist:
- connect to a project-backed bridge
- open a session and type `/`
- open and use `/model` or `/permissions`
- type `@turn` and select one or more file chips
- send the command and verify the serialized file mentions appear in the outgoing turn
- tap the header and switch to another session in the same project
- press and hold the microphone, release, and confirm text is inserted but not sent
- confirm existing `View Diff` and file-viewing paths still work

- [ ] **Step 3: Capture any regressions before cleanup**

If a regression appears, write a failing test first in the nearest relevant suite:

```swift
func testSendingDraftPrefixesSelectedFilesBeforeUserText() throws {
    // regression lock for final send formatting
}
```

- [ ] **Step 4: Stage only the intended feature files**

Run: `git status --short`
Expected: review only the files touched by this plan and exclude unrelated workspace changes.

- [ ] **Step 5: Commit the final verification checkpoint**

```bash
git add crates/codepilot-protocol crates/codepilot-bridge packages/ios/CodePilotApp packages/ios/CodePilotKit
git commit -m "test: verify ios composer parity rollout"
```

## Review Checklist

Before marking the implementation complete, confirm:

- `@files` works with real bridge-backed search results rather than hard-coded local data.
- selected files are visible as chips before send.
- sent commands stay plain text.
- session switching is scoped to the current project only.
- speech input requires a press gesture and never auto-sends.
- existing slash workflows still use the current catalog-based system.
- unrelated dirty-worktree files were not reverted or bundled accidentally.
