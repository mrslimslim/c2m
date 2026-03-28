# iOS Client Composer Parity Design

**Topic:** Bring the iOS client closer to the competitor interaction model with richer composer triggers, session switching, and press-to-talk input

**Date:** 2026-03-28

## Goal

Upgrade the current iOS client so the core mobile chat flow feels materially closer to the competitor screenshots without faking unsupported backend capabilities.

This phase should deliver:

- richer composer interactions driven by `/commands` and `@files`
- a searchable session switcher from the conversation header
- press-to-talk speech-to-text that fills the composer
- stronger UI affordances around existing timeline and diff capabilities

The result should feel more capable on-phone while staying truthful to what the bridge and protocol can actually support today.

## Scope

- Enhance the session composer in the conversation screen.
- Reuse the existing slash catalog system for `/commands`.
- Add `@files` file search for the current project, backed by a lightweight protocol extension.
- Render selected file references as chips in the composer before send.
- Serialize file chips into stable plain-text command content when sending.
- Add a searchable session switcher from the conversation header for the current project.
- Add press-to-talk speech-to-text that inserts recognized text into the composer but does not auto-send.
- Keep the current project/session navigation model and extend it rather than replacing it.
- Keep existing diff and file-viewing flows, but expose them more clearly where appropriate.

## Non-Goals

- `$skills` support in this phase.
- Full worktree, branch, or handoff management.
- Real `commit`, `push`, or GitHub actions from the mobile client.
- A brand new global command palette that replaces all existing navigation.
- Rich-text or structured attachment payloads in sent commands.
- Cross-project session switching from inside a conversation.
- Bridge-side skill enumeration or server-driven attachment chips.

## Problem Statement

The current iOS app already has the foundation for mobile command execution:

- a session detail screen with a timeline and bottom composer
- a protocol-driven slash menu
- project-scoped sessions
- file viewing and on-demand diff viewing

However, the interaction model is still noticeably thinner than the competitor flow shown in the reference images:

- the composer understands `/` but not `@files`
- selected file context is not visible as chips before send
- conversation switching is separated from the active conversation flow
- speech-to-text is absent
- the interface exposes capabilities as isolated screens rather than as part of one fluid mobile command surface

At the same time, the current protocol does not support repository-wide file search. The only file-related request today is a direct `fileRequest(path, sessionId)`, which assumes the client already knows the path. That means the competitor-style `@files` interaction cannot be built honestly as a UI-only feature.

This design must therefore improve the mobile experience while keeping the system truthful:

- reuse existing capabilities where they already exist
- extend the protocol only where the missing data is real and small
- avoid promising backend functionality that is not yet implemented

## Recommended Approach

Use a phased feature bundle centered on the existing conversation screen:

1. keep `/commands` grounded in the existing slash catalog flow
2. add a minimal bridge-backed file-search protocol for `@files`
3. manage selected file references as local composer chips
4. add a project-scoped, searchable session switcher from the conversation header
5. add local iOS press-to-talk speech recognition that only fills the composer

This keeps the architecture honest:

- `/commands` stays protocol-driven from the bridge
- `@files` gets only the missing data channel it actually needs
- sent commands remain plain text and backward-compatible
- session switching reuses local state already maintained by the app
- speech input remains entirely local to iOS and does not require bridge changes

## User Experience

### Conversation Composer

The conversation composer in `SessionDetailView` becomes a multi-trigger surface:

- typing `/` shows the existing slash workflow menu
- typing `@` shows file search results for the current project
- selected file results appear as chips above the input field
- the message draft remains plain editable text below the chips

The send action continues to submit a normal command message.

Before send, the app serializes selected file chips into a stable plain-text prefix. Example:

```text
@Sources/App.swift @README.md Explain how these files work together
```

This ensures the bridge and adapters can continue to operate on plain text while the mobile UI still presents a richer interaction model.

### Slash Commands

Slash behavior remains backed by the existing slash catalog:

- empty or partial `/` input shows the command list
- exact workflow commands such as `/model` and `/permissions` still open their existing structured menus
- selected config still appears as chips using the current session config flow

This phase does not create a second command system. The current slash metadata remains the single source of truth.

### File Search With `@`

When the user types `@`:

- the composer opens a file-search panel anchored to the current input
- the panel shows repository file matches for the current project
- selecting a result inserts a file chip and removes the active `@query` token from the draft
- the user can select multiple files before sending

The panel should support:

- incremental query updates
- empty state
- loading state
- connection-unavailable state
- error state with retry

This feature is project-scoped. It should search the repository associated with the current session or project connection, not the entire app across all saved connections.

### Session Switcher

Tapping the conversation title in the header opens a searchable session switcher sheet.

The switcher shows only sessions for the current project and includes:

- search field
- recent sessions sorted by activity
- state badges
- active-session indication
- quick action to start a new session if no relevant result exists

Selecting a session navigates directly to that session detail view and closes the switcher.

### Press-to-Talk Speech Input

The composer gains a microphone control with press-to-talk behavior:

- press and hold starts audio capture and speech recognition
- release stops capture
- recognized text is inserted into the draft
- the app never auto-sends recognized text

Failure modes should be explicit:

- microphone permission missing
- speech recognition unavailable
- interrupted or failed recognition

Speech input is additive. If the user already has draft text, recognized text appends in a readable way rather than overwriting the draft.

### Existing Diff And Timeline Capabilities

This phase should not invent fake Git action buttons.

Instead, the UI should better emphasize real existing capabilities when the timeline includes code changes:

- clear `View Diff` access for code-change turns
- clear file opening affordances where a changed file is available

This keeps the app grounded in supported behavior while still making the “mobile coding” story more visible.

## Architecture

### Protocol Layer

Add a minimal file-search request/response pair.

Phone to bridge:

- `file_search_req`
  - `sessionId`
  - `query`
  - `limit`

Bridge to phone:

- `file_search_results`
  - `sessionId`
  - `query`
  - `results`

Each result should be lightweight:

- `path`
- optional `displayName`
- optional `directoryHint`

This protocol should not attempt to send file contents, line previews, or semantic metadata in v1.

### Bridge Responsibilities

The bridge owns repository file search for the active project.

Responsibilities:

- resolve the project root from the current session or connection context
- search repository paths quickly for the incoming query
- return bounded results in stable relative-path form
- avoid exposing files outside the allowed project scope

The bridge should keep the implementation conservative:

- prefer a filesystem-backed search strategy already available in the runtime
- cap the result set
- tolerate workspace drift and deleted files
- return an empty list rather than failing when no files match

### iOS Composer State

Add a dedicated composer interaction model in `CodePilotFeatures` rather than embedding all trigger logic directly in SwiftUI state.

Suggested responsibilities:

- detect trigger mode: normal, slash, or file search
- track the active `@query`
- track selected file chips
- debounce outgoing file-search requests
- merge search results into a view-ready projection
- serialize chips into final send text

This keeps the current views simpler and makes the behavior easier to test outside SwiftUI.

### iOS Application State

`AppModel` should grow just enough state to support file search:

- last file-search results by session or connection
- loading state for in-flight searches
- error state for the current search

The existing session, slash catalog, and file-content stores should remain separate:

- `FileStore` stays responsible for concrete file contents loaded by path
- file-search state is query/result state, not file-content state
- slash workflow state remains unchanged except for how it coexists with the richer composer

### Session Switcher State

Session switching does not need new protocol messages.

It should reuse:

- `sessionsForConnection(_:)`
- existing session metadata already projected in `AppModel`
- current navigation behavior that already routes to `SessionDetailView`

The switcher itself should be a lightweight local projection:

- filter by current connection
- filter by search text
- sort by `lastActiveAt`

### Speech Input Layer

Speech input should remain local to the iOS app.

Use native speech-recognition and audio-session APIs to:

- request permissions
- manage press-to-talk lifecycle
- stream or collect recognized text
- return a final recognized string to the composer

No bridge or protocol dependency is needed for this phase.

## Data Flow

### Slash Command Flow

1. User types `/`.
2. The composer routes interaction to the existing slash workflow state.
3. The slash menu renders from the current slash catalog.
4. User chooses a command or option.
5. The app either:
   - updates local session config state
   - triggers an existing slash bridge action
   - updates input text
6. The composer returns to normal typing or send-ready state.

### File Search Flow

1. User types `@` and begins entering a path fragment.
2. The composer interaction model extracts the active file-search query.
3. iOS sends `file_search_req(sessionId, query, limit)`.
4. The bridge resolves the repository and returns `file_search_results`.
5. The app renders the results panel.
6. User selects one or more results.
7. The composer interaction model converts them into selected chips.
8. On send, chips are serialized into a stable plain-text prefix plus the remaining draft text.

### Session Switching Flow

1. User taps the title area in the conversation header.
2. The app presents the session switcher sheet.
3. The sheet loads sessions for the current connection from local app state.
4. User filters and selects a session.
5. The app navigates to that session detail view.
6. The switcher dismisses.

### Press-to-Talk Flow

1. User presses and holds the microphone control.
2. iOS requests or validates permissions as needed.
3. Audio capture and speech recognition begin.
4. User releases the control.
5. Recording stops and the recognized text is finalized.
6. The composer inserts or appends the recognized text into the draft.
7. The user reviews and manually sends the message if desired.

## Error Handling

### File Search

- If the bridge is disconnected, the file-search panel should show a connection-unavailable message.
- If the search request fails, the panel should show a retry affordance.
- If no results match, the panel should show an empty state without collapsing the interaction.
- File search failure must never block normal draft entry or message sending.

### Session Switcher

- If there are no sessions for the current project, show an empty state with a new-session shortcut.
- If the current session disappears because of deletion or reconnect changes, the switcher should simply refresh from current app state rather than caching stale identifiers.

### Speech Input

- If microphone permission is denied, show a permission-specific error.
- If speech recognition is unavailable, show an unavailable-state error.
- If recognition fails mid-capture, preserve the draft and return the composer to idle.
- Speech failure must never clear existing typed text.

## Performance Requirements

These are part of the design:

1. The composer must remain responsive while search queries are changing.
2. File search requests must be debounced to avoid flooding the bridge.
3. File search result sets must be capped.
4. Session switching must use local filtering and not hit the network.
5. Speech capture must not trigger layout instability in the composer row.
6. Existing slash menu performance and layout behavior must not regress.

## Testing Strategy

### Protocol Tests

Add protocol round-trip coverage for:

- `file_search_req`
- `file_search_results`
- lightweight file-search result models

### Feature Tests

Add tests for:

- trigger parsing between normal input, slash mode, and file-search mode
- file chip insertion and removal
- final serialization of file chips into send text
- session-switcher filtering and sorting
- speech-input state transitions where logic can be isolated from platform APIs

### App Source Tests

Extend source-level UI tests in the style already used by the iOS package to verify:

- the conversation header exposes a session-switcher trigger
- the composer includes file-chip rendering
- the composer includes a microphone press-to-talk control
- the slash menu continues to be instantiated from shared workflow state

### Manual Verification

Manual QA should cover:

- slash command selection still works
- `@files` can find repository files from the current project
- multiple file chips serialize correctly on send
- switching sessions from the header feels immediate
- press-to-talk inserts text without auto-send
- diff and file viewer entry points still behave correctly

## Rollout Plan

Implement in this order:

1. protocol models for file search
2. bridge file-search plumbing
3. iOS composer interaction model and file chips
4. session switcher UI
5. press-to-talk speech input
6. focused regression testing for existing slash, file, and diff flows

This order unlocks the highest-priority user value first while keeping regressions easier to isolate.

## Open Questions Resolved For This Phase

- `$skills` is intentionally excluded until the bridge can expose truthful capability data.
- `@files` is project-scoped, not global across all saved connections.
- recognized speech does not auto-send.
- session switching is exposed from the conversation header, not via a side drawer.
- sent commands remain plain text even when the composer UI uses chips.
