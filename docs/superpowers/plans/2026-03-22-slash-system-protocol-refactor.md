# Slash System Protocol Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the iOS client's hard-coded slash UI with a protocol-driven slash system where the bridge publishes adapter/version-specific command metadata and the client renders recursive workflows such as `/model -> reasoning effort`.

**Architecture:** Extend the wire protocol with slash catalog and slash action messages, add `modelReasoningEffort` to `SessionConfig`, and let the bridge generate a normalized slash catalog keyed by adapter and detected version. The iOS app stores the latest catalog per connection, renders it through a shared workflow engine used by both composers, and applies slash effects locally or routes bridge actions back through the transport.

**Tech Stack:** TypeScript, Node.js, `@openai/codex-sdk`, Swift, SwiftUI, Swift Package Manager, XCTest

---

## Scope And Constraints

- This refactor intentionally treats slash as a first-class subsystem, not as a text-field helper.
- The bridge is the source of truth for command availability, labels, helper text, workflow structure, and disabled reasons.
- The client must support recursive menus because commands like `/model` are multi-step workflows.
- The first shippable version should make `/model`, `/permissions`, and `/new` behave correctly end-to-end.
- Commands that cannot yet be executed truthfully must remain visible only if they are marked `disabled` with an explicit reason.

## File Map

### Protocol Layer

- Modify: `packages/protocol/src/messages.ts`
  - Add `modelReasoningEffort` to `SessionConfig`
  - Add `SlashCatalogMessage`, `SlashActionMessage`, `SlashActionResultMessage`
  - Add shared slash metadata types used by bridge and iOS
- Modify: `packages/protocol/src/index.ts`
  - Re-export the new slash protocol types
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift`
  - Add `modelReasoningEffort`
  - Add `slashAction` case and encoding/decoding support
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift`
  - Add `slashCatalog` and `slashActionResult` cases
  - Add capability constant for `slash_catalog_v1`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/SlashCatalog.swift`
  - Define Swift mirror models for slash metadata to keep `BridgeMessage.swift` focused
- Test: `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`
  - Extend protocol coverage for message encoding/decoding

### Bridge Layer

- Create: `packages/bridge/src/slash/catalog.ts`
  - Public generator entry point for slash catalogs
- Create: `packages/bridge/src/slash/codex.ts`
  - Codex-specific catalog builder and command rollout policy
- Create: `packages/bridge/src/slash/version.ts`
  - Adapter version detection utilities
- Create: `packages/bridge/src/slash/actions.ts`
  - Bridge-side action dispatcher for slash actions that are not local client actions
- Modify: `packages/bridge/src/adapters/types.ts`
  - Add `modelReasoningEffort` to `SessionOptions`
- Modify: `packages/bridge/src/adapters/codex.ts`
  - Pass `modelReasoningEffort` to Codex SDK as `modelReasoningEffort`
- Modify: `packages/bridge/src/bridge.ts`
  - Send slash catalog after successful connection
  - Handle incoming `slash_action`
  - Include new capability in handshake behavior
- Create: `packages/bridge/src/__tests__/slash-catalog.test.ts`
  - Verify adapter/version catalog generation
- Modify: `packages/bridge/src/__tests__/codex-adapter.test.ts`
  - Assert reasoning effort passthrough
- Modify: `packages/bridge/src/__tests__/bridge.test.ts`
  - Assert catalog broadcast and slash action routing

### iOS Client Layer

- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/SlashCatalogStore.swift`
  - Store the latest catalog for the active bridge connection
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift`
  - Route `slash_catalog` and `slash_action_result` messages
- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SlashWorkflowState.swift`
  - Shared recursive workflow state for slash menus
- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SlashCatalogProjector.swift`
  - Resolve `current`, `default`, and `disabled` badges from catalog plus composer state
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionDetailViewModel.swift`
  - Expose catalog-driven slash actions and workflow hooks
- Modify: `packages/ios/CodePilotApp/CodePilot/Theme/SlashCommandMenu.swift`
  - Rewrite as recursive metadata-driven menu renderer
- Modify: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift`
  - Replace hard-coded slash logic with workflow engine
- Modify: `packages/ios/CodePilotApp/CodePilot/Projects/ProjectDetailView.swift`
  - Reuse the same workflow engine used in the session composer
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SlashCatalogStoreTests.swift`
  - Verify catalog persistence and refresh behavior
- Create: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SlashWorkflowStateTests.swift`
  - Verify recursive menu navigation and effect application
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionDetailViewModelTests.swift`
  - Verify slash action sending and config writes
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift`
  - Update expectations for the new recursive slash menu layout only if layout assertions remain valuable

## Slash Catalog v1 Shape

### Protocol Additions

```ts
export interface SessionConfig {
  model?: string;
  modelReasoningEffort?: "minimal" | "low" | "medium" | "high" | "xhigh";
  approvalPolicy?: "never" | "on-request" | "on-failure" | "untrusted";
  sandboxMode?: "read-only" | "workspace-write" | "danger-full-access";
}

export interface SlashCatalogMessage {
  type: "slash_catalog";
  capability: "slash_catalog_v1";
  adapter: "codex" | "claude";
  adapterVersion?: string;
  catalogVersion: string;
  defaults: SessionConfig;
  commands: SlashCommandMeta[];
}

export interface SlashActionMessage {
  type: "slash_action";
  sessionId?: string;
  commandId: string;
  arguments?: Record<string, string | number | boolean>;
}

export interface SlashActionResultMessage {
  type: "slash_action_result";
  commandId: string;
  ok: boolean;
  message?: string;
}
```

### Slash Metadata Model

```ts
export interface SlashCommandMeta {
  id: string;
  label: string;
  description: string;
  kind: "workflow" | "bridge_action" | "client_action" | "insert_text";
  availability: "enabled" | "disabled" | "hidden";
  disabledReason?: string;
  searchTerms?: string[];
  menu?: SlashMenuNode;
  action?: SlashActionMeta;
}

export interface SlashMenuNode {
  title: string;
  helperText?: string;
  presentation: "list" | "grid";
  options: SlashMenuOption[];
}

export interface SlashMenuOption {
  id: string;
  label: string;
  description?: string;
  badges?: ("default" | "recommended")[];
  effects?: SlashEffect[];
  next?: SlashMenuNode;
}

export type SlashEffect =
  | { type: "set_session_config"; field: "model" | "modelReasoningEffort" | "approvalPolicy" | "sandboxMode"; value: string }
  | { type: "set_input_text"; value: string }
  | { type: "clear_input_text" };
```

### Message Flow

1. Bridge accepts a connection and completes the existing handshake.
2. `handshake_ok.capabilities` includes `slash_catalog_v1`.
3. Bridge sends `slash_catalog` immediately after the connection is considered live.
4. Client caches the catalog and renders slash UI from it.
5. Client applies local slash effects immediately for workflow or client actions.
6. Client sends `slash_action` for bridge actions.
7. Bridge responds with `slash_action_result` when needed.

## Codex Slash Rollout Policy

### v1 Command Matrix

- `/model`
  - `kind: workflow`
  - `availability: enabled`
  - End-to-end in v1
- `/permissions`
  - `kind: workflow`
  - `availability: enabled`
  - End-to-end in v1
- `/new`
  - `kind: client_action`
  - `availability: enabled`
  - Client opens the new-session composer or clears current slash flow depending on screen
- `/review`
  - `kind: bridge_action`
  - `availability: disabled` in v1 unless a truthful non-interactive bridge implementation exists
- `/rename`
  - `kind: bridge_action`
  - `availability: disabled` in v1 unless thread naming is implemented server-side
- `/fast`
  - `kind: bridge_action`
  - `availability: disabled` in v1 because current SDK integration does not expose Codex TUI fast-mode semantics directly
- `/skills`
  - `kind: bridge_action`
  - `availability: disabled` in v1 until bridge can enumerate and apply skills truthfully
- `/experimental`
  - `kind: bridge_action`
  - `availability: disabled` in v1 until bridge can inspect and toggle feature flags safely

### `/model` Workflow Contract

- Root menu title: `Select Model and Effort`
- Root helper text: `Access legacy models by running codex -m <model_name> or in your config.toml`
- Each model option may include `default` based on catalog defaults
- Selecting a model with reasoning choices opens a second menu
- Second menu title: `Select Reasoning Level for <model>`
- Reasoning choices should expose `current` based on the current composer config
- Final leaf applies both `model` and `modelReasoningEffort`

### `/permissions` Workflow Contract

- Root menu title: `Select Permissions`
- First step selects approval policy
- Optional second step selects sandbox mode if the workflow is designed as a pair
- Final leaf writes `approvalPolicy` and `sandboxMode`

## Task Breakdown

### Task 1: Lock Protocol v1

**Files:**
- Modify: `packages/protocol/src/messages.ts`
- Modify: `packages/protocol/src/index.ts`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotProtocol/SlashCatalog.swift`
- Test: `packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`

- [ ] **Step 1: Write the failing protocol tests**
  - Add TypeScript-level bridge tests that expect `slash_catalog` and `slash_action` payloads to compile and route.
  - Add Swift protocol tests that decode a sample `slash_catalog` payload and encode a `slash_action` payload.

- [ ] **Step 2: Run protocol-focused tests to verify they fail**
  - Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
  - Expected: failures for unknown slash message types or missing `modelReasoningEffort`

- [ ] **Step 3: Implement the protocol types**
  - Add slash catalog metadata interfaces and message unions in TypeScript.
  - Add matching Swift models and enum cases.

- [ ] **Step 4: Run tests to verify protocol support passes**
  - Run: `swift test --package-path packages/ios/CodePilotKit --filter ProtocolModelTests`
  - Expected: PASS

- [ ] **Step 5: Commit**
  - Run: `git add packages/protocol/src/messages.ts packages/protocol/src/index.ts packages/ios/CodePilotKit/Sources/CodePilotProtocol/PhoneMessage.swift packages/ios/CodePilotKit/Sources/CodePilotProtocol/BridgeMessage.swift packages/ios/CodePilotKit/Sources/CodePilotProtocol/SlashCatalog.swift packages/ios/CodePilotKit/Tests/CodePilotProtocolTests/ProtocolModelTests.swift`
  - Run: `git commit -m "feat: add slash catalog protocol models"`

### Task 2: Add Bridge Slash Catalog Generation

**Files:**
- Create: `packages/bridge/src/slash/catalog.ts`
- Create: `packages/bridge/src/slash/codex.ts`
- Create: `packages/bridge/src/slash/version.ts`
- Create: `packages/bridge/src/__tests__/slash-catalog.test.ts`

- [ ] **Step 1: Write the failing bridge catalog tests**
  - Cover `codex-cli 0.116.0` command set and disabled reasons for unsupported commands.
  - Cover fallback behavior when version detection fails.

- [ ] **Step 2: Run the catalog tests to verify they fail**
  - Run: `pnpm --filter @codepilot/bridge build && node --test packages/bridge/dist/__tests__/slash-catalog.test.js`
  - Expected: FAIL because the slash catalog generator does not exist yet

- [ ] **Step 3: Implement version detection and catalog generation**
  - Read adapter version from a dedicated helper instead of embedding shell logic in `bridge.ts`.
  - Normalize the returned metadata into the protocol shape.

- [ ] **Step 4: Run tests to verify catalog generation passes**
  - Run: `pnpm --filter @codepilot/bridge build && node --test packages/bridge/dist/__tests__/slash-catalog.test.js`
  - Expected: PASS

- [ ] **Step 5: Commit**
  - Run: `git add packages/bridge/src/slash/catalog.ts packages/bridge/src/slash/codex.ts packages/bridge/src/slash/version.ts packages/bridge/src/__tests__/slash-catalog.test.ts`
  - Run: `git commit -m "feat: generate slash catalogs by adapter version"`

### Task 3: Thread Reasoning Effort Through Bridge And Codex SDK

**Files:**
- Modify: `packages/bridge/src/adapters/types.ts`
- Modify: `packages/bridge/src/adapters/codex.ts`
- Modify: `packages/bridge/src/bridge.ts`
- Modify: `packages/bridge/src/__tests__/codex-adapter.test.ts`
- Modify: `packages/bridge/src/__tests__/bridge.test.ts`

- [ ] **Step 1: Write the failing tests**
  - Assert that `SessionOptions.modelReasoningEffort` reaches `codex.startThread({ modelReasoningEffort })`.
  - Assert that `handleCommand(..., config)` passes `modelReasoningEffort` into session options.

- [ ] **Step 2: Run tests to verify they fail**
  - Run: `pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge test`
  - Expected: FAIL on missing reasoning effort assertions

- [ ] **Step 3: Implement minimal bridge passthrough**
  - Extend `SessionOptions`.
  - Map `config.modelReasoningEffort` to the adapter option.
  - Pass the field to the Codex SDK thread options.

- [ ] **Step 4: Run tests to verify passthrough works**
  - Run: `pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge test`
  - Expected: PASS

- [ ] **Step 5: Commit**
  - Run: `git add packages/bridge/src/adapters/types.ts packages/bridge/src/adapters/codex.ts packages/bridge/src/bridge.ts packages/bridge/src/__tests__/codex-adapter.test.ts packages/bridge/src/__tests__/bridge.test.ts`
  - Run: `git commit -m "feat: pass slash reasoning config to codex"`

### Task 4: Publish Slash Catalog And Handle Slash Actions In Bridge

**Files:**
- Modify: `packages/bridge/src/bridge.ts`
- Create: `packages/bridge/src/slash/actions.ts`
- Modify: `packages/bridge/src/__tests__/bridge.test.ts`

- [ ] **Step 1: Write the failing transport tests**
  - Assert that a connected client receives `slash_catalog`.
  - Assert that `slash_action` dispatches to the bridge action handler.
  - Assert that unsupported actions return a truthful disabled or error response.

- [ ] **Step 2: Run tests to verify they fail**
  - Run: `pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge test`
  - Expected: FAIL because bridge does not yet emit or handle slash messages

- [ ] **Step 3: Implement bridge slash message flow**
  - Include `slash_catalog_v1` in capabilities.
  - Send the latest slash catalog after a successful connection.
  - Add a `slash_action` branch in `handleMessage`.
  - Return `slash_action_result` where needed.

- [ ] **Step 4: Run tests to verify bridge flow passes**
  - Run: `pnpm --filter @codepilot/bridge build && pnpm --filter @codepilot/bridge test`
  - Expected: PASS

- [ ] **Step 5: Commit**
  - Run: `git add packages/bridge/src/bridge.ts packages/bridge/src/slash/actions.ts packages/bridge/src/__tests__/bridge.test.ts`
  - Run: `git commit -m "feat: publish slash catalog and route slash actions"`

### Task 5: Add iOS Slash Catalog Storage And Routing

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotCore/SlashCatalogStore.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SlashCatalogStoreTests.swift`

- [ ] **Step 1: Write the failing iOS core tests**
  - Decode a `slash_catalog` message and verify it is stored for the active connection.
  - Decode a `slash_action_result` message and verify it reaches the right consumer or state store.

- [ ] **Step 2: Run tests to verify they fail**
  - Run: `swift test --package-path packages/ios/CodePilotKit --filter SlashCatalogStoreTests`
  - Expected: FAIL because no slash catalog store or routing exists

- [ ] **Step 3: Implement minimal storage and routing**
  - Add a store with replace/get semantics keyed by connection or active slot.
  - Route incoming bridge messages into that store.

- [ ] **Step 4: Run tests to verify core support passes**
  - Run: `swift test --package-path packages/ios/CodePilotKit --filter SlashCatalogStoreTests`
  - Expected: PASS

- [ ] **Step 5: Commit**
  - Run: `git add packages/ios/CodePilotKit/Sources/CodePilotCore/SlashCatalogStore.swift packages/ios/CodePilotKit/Sources/CodePilotCore/SessionMessageRouter.swift packages/ios/CodePilotKit/Tests/CodePilotCoreTests/SlashCatalogStoreTests.swift`
  - Run: `git commit -m "feat: store slash catalogs in ios client"`

### Task 6: Build Shared Slash Workflow Engine

**Files:**
- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SlashWorkflowState.swift`
- Create: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SlashCatalogProjector.swift`
- Modify: `packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionDetailViewModel.swift`
- Create: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SlashWorkflowStateTests.swift`
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing workflow tests**
  - Cover command filtering for `/`, `/m`, and `/model`.
  - Cover entering `/model`, drilling into reasoning choices, applying config effects, and backing out.
  - Cover bridge action dispatch from the view model.

- [ ] **Step 2: Run tests to verify they fail**
  - Run: `swift test --package-path packages/ios/CodePilotKit --filter SlashWorkflowStateTests`
  - Expected: FAIL because the workflow engine does not exist

- [ ] **Step 3: Implement minimal workflow state**
  - Add recursive menu stack support.
  - Add effect application for `set_session_config`, `set_input_text`, and `clear_input_text`.
  - Expose a projection model with `default/current/disabled` UI flags.

- [ ] **Step 4: Run tests to verify workflow state passes**
  - Run: `swift test --package-path packages/ios/CodePilotKit --filter SlashWorkflowStateTests`
  - Expected: PASS

- [ ] **Step 5: Commit**
  - Run: `git add packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SlashWorkflowState.swift packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SlashCatalogProjector.swift packages/ios/CodePilotKit/Sources/CodePilotFeatures/Sessions/SessionDetailViewModel.swift packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SlashWorkflowStateTests.swift packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionDetailViewModelTests.swift`
  - Run: `git commit -m "feat: add slash workflow engine for ios"`

### Task 7: Replace Hard-Coded Slash UI In Both Composers

**Files:**
- Modify: `packages/ios/CodePilotApp/CodePilot/Theme/SlashCommandMenu.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift`
- Modify: `packages/ios/CodePilotApp/CodePilot/Projects/ProjectDetailView.swift`
- Modify: `packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift`

- [ ] **Step 1: Write the failing UI source and behavior tests**
  - Assert that the slash menu reads from workflow state rather than hard-coded commands.
  - Assert that the session and new-session composers both instantiate the shared workflow state.

- [ ] **Step 2: Run tests to verify they fail**
  - Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionComposerLayoutSourceTests`
  - Expected: FAIL because the current source still references hard-coded slash commands

- [ ] **Step 3: Implement the recursive menu renderer**
  - Rewrite the menu UI to render generic slash metadata.
  - Add breadcrumb or back-navigation affordance for nested menus.
  - Preserve keyboard and focus behavior in both composer surfaces.

- [ ] **Step 4: Run targeted tests to verify the UI integration passes**
  - Run: `swift test --package-path packages/ios/CodePilotKit --filter SessionComposerLayoutSourceTests`
  - Expected: PASS

- [ ] **Step 5: Commit**
  - Run: `git add packages/ios/CodePilotApp/CodePilot/Theme/SlashCommandMenu.swift packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift packages/ios/CodePilotApp/CodePilot/Projects/ProjectDetailView.swift packages/ios/CodePilotKit/Tests/CodePilotFeaturesTests/SessionComposerLayoutSourceTests.swift`
  - Run: `git commit -m "feat: render slash menus from bridge metadata"`

### Task 8: End-To-End Verification And Docs Sync

**Files:**
- Modify: `docs/technical.md`
- Modify: `docs/ios-testing.md`

- [ ] **Step 1: Update technical documentation**
  - Document the new slash catalog protocol, capability flag, and reasoning effort config path.

- [ ] **Step 2: Update manual test guidance**
  - Add a slash-system acceptance scenario for `/model` and `/permissions`.

- [ ] **Step 3: Run the full verification commands**
  - Run: `pnpm --filter @codepilot/bridge build`
  - Run: `pnpm --filter @codepilot/bridge test`
  - Run: `swift test --package-path packages/ios/CodePilotKit`
  - Expected: PASS across bridge and Swift package tests

- [ ] **Step 4: Smoke-test the bridge version probe manually**
  - Run: `codex --version`
  - Expected: prints the detected Codex version used to select the catalog

- [ ] **Step 5: Commit**
  - Run: `git add docs/technical.md docs/ios-testing.md`
  - Run: `git commit -m "docs: describe protocol-driven slash system"`

## Acceptance Criteria

- The bridge advertises `slash_catalog_v1` and sends a `slash_catalog` payload after connection.
- The catalog contents vary by adapter and detected version without client code changes.
- The iOS client can render nested slash workflows from metadata alone.
- `/model` updates both `model` and `modelReasoningEffort` and the bridge passes both to Codex SDK.
- `/permissions` updates session configuration through the same metadata-driven effect system.
- `/new` is handled as a client action rather than text insertion.
- Unsupported commands are either omitted or surfaced as disabled with a reason.
- Existing non-slash command sending still works.

## Risks And Mitigations

- Risk: Codex TUI-only commands do not map cleanly to the SDK integration.
  - Mitigation: declare them `disabled` until bridge support is truthful.
- Risk: Recursive slash menus can introduce focus and keyboard regressions.
  - Mitigation: keep one shared workflow engine and add explicit tests for both composer surfaces.
- Risk: Protocol growth can bloat `BridgeMessage.swift` and `messages.ts`.
  - Mitigation: move slash model details into dedicated files and keep message unions thin.
- Risk: Version detection may fail in some environments.
  - Mitigation: generate a conservative fallback catalog with `adapterVersion: undefined`.

## Out Of Scope For This Plan

- Full bridge execution for `/review`, `/rename`, `/fast`, `/skills`, and `/experimental`
- Dynamic remote fetching of slash definitions from OpenAI services
- Reworking the entire composer visual design beyond what is necessary to support nested slash flows
