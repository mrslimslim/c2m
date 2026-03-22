# Mobile Diff Viewer Design

**Topic:** On-demand diff viewing for the iOS client session timeline

**Goal:** Let the iOS client open a real code diff for each `code_change` timeline event without bloating timeline replay, transport payloads, or SwiftUI rendering on large edits.

## Scope

- Add a dedicated mobile `Diff Viewer` screen that opens from a timeline code-change card.
- Keep the timeline lightweight by showing only change summary metadata.
- Fetch diff details on demand from the bridge when the user opens a diff.
- Render each changed file incrementally:
  - load file metadata and the first hunk by default
  - reveal additional hunks only when the user requests them
- Preserve existing file viewing so the user can still open the post-change file contents.

## Non-Goals

- Inline diff rendering directly inside the timeline feed.
- Side-by-side desktop-style comparison UI.
- Arbitrary diffing between any two commits or workspace states.
- Editing files from the iOS client.
- Fully persisting complete diff payloads inside session event history.

## Problem Statement

The current protocol only tells the iOS client that files changed. `code_change` events contain `path` and `kind`, which is enough to render a compact summary card but not enough to inspect what actually changed. The iOS app can open a whole file through the existing file request flow, but that is not a diff experience and does not answer "what changed in this turn?"

Naively attaching full unified diffs to every `code_change` event would solve the feature gap but would create the wrong performance profile for mobile:

- timeline event payloads would become much larger
- session replay would become slower and memory-heavier
- event logs would grow quickly for long sessions
- SwiftUI would risk jank if the session detail screen had to decode and lay out many large patches

The design must therefore treat diff data as an on-demand detail surface, not as part of the default timeline hot path.

## Recommended Approach

Use a split model:

1. `code_change` timeline events remain summary-first and lightweight.
2. The protocol grows a dedicated on-demand diff request/response flow.
3. The bridge computes and serves diff payloads only when requested.
4. The iOS app renders diff files lazily, defaulting to the first hunk per file and revealing additional hunks explicitly.

This keeps the session detail screen fast while still providing a complete diff inspection path when the user asks for it.

## User Experience

### Session Timeline

- `CodeChangeCard` continues to appear inline in the timeline.
- The card shows:
  - number of files changed
  - per-file `path + kind`
  - optional tiny line stats if cheaply available
  - a clear `View Diff` action
- The card never renders raw patch text in the timeline.

### Diff Viewer

Opening `View Diff` pushes a dedicated `Diff Viewer` screen.

The screen layout:

1. Header summary
   - number of files changed
   - timestamp or event label
   - loading / error state if the bridge response is pending
2. Per-file diff sections
   - file name and relative path
   - change kind badge
   - optional line stats
   - the first hunk rendered immediately
   - a `Load next hunk` control if more hunks are available
3. File actions
   - `Open File` to jump into the existing read-only file viewer

### Large Diff Behavior

- If a file exceeds configured diff limits, the viewer shows a truncated state rather than trying to render everything.
- The user can still open the raw file contents via `Open File`.
- The UI should clearly distinguish:
  - no diff available yet
  - diff truncated for performance
  - deleted file, where full-file open may not be possible

## Performance Requirements

These constraints are part of the design, not optional implementation polish:

1. Timeline replay must not require loading full diff bodies.
2. Opening a session detail screen must not trigger diff loading for historical code-change events.
3. Diff rendering must be incremental per file and per hunk.
4. The first screenful of a diff should remain usable even for turns that changed many files.
5. The iOS app must avoid mounting large monolithic text views for the entire patch set.
6. The bridge should avoid recomputing the same diff repeatedly during a short viewing window.

## Architecture

### Protocol Layer

Add dedicated messages for on-demand diff loading.

Phone to bridge:

- `diff_req`
  - `sessionId`
  - `eventId`
- `diff_hunks_req`
  - `sessionId`
  - `eventId`
  - `path`
  - `afterHunkIndex`

Bridge to phone:

- `diff_content`
  - `sessionId`
  - `eventId`
  - `files`
- `diff_hunks_content`
  - `sessionId`
  - `eventId`
  - `path`
  - `hunks`
  - `nextHunkIndex`

Each returned file includes:

- `path`
- `kind`
- optional line stats such as `addedLines` and `deletedLines`
- `isTruncated`
- `truncationReason`
- `totalHunkCount`
- `loadedHunks`
- `nextHunkIndex`

Each hunk includes:

- unified diff header metadata such as old/new start and line counts
- an ordered list of diff lines with type:
  - context
  - add
  - delete

`diff_content` should include only the first hunk per file in `loadedHunks`. When the user taps `Load next hunk`, the iOS client sends `diff_hunks_req` for that file, and the bridge responds with the next chunk in `diff_hunks_content`. This keeps both the initial network payload and the mounted SwiftUI tree small.

### Session Event Model

`code_change` remains the event that anchors the viewer entry point.

It should stay summary-oriented:

- `changes: [FileChange]`
- optional `summary` metadata if cheap to compute

The event itself should not carry the full patch body.

### Bridge Layer

The bridge owns on-demand diff assembly.

Responsibilities:

- identify the requested `code_change` event from session history
- collect the changed files for that event
- derive a unified diff for those files from the working tree
- normalize the diff into file and hunk models the phone can render directly
- enforce truncation limits
- cache recent diff responses by `(sessionId, eventId)` for a short TTL

The bridge should keep the implementation conservative:

- use relative repo paths where possible
- avoid serving sensitive files that the existing file request path would refuse
- tolerate missing files for deletes or later workspace drift

### iOS State Management

Add a dedicated diff state store rather than overloading `FileStore`.

Suggested responsibilities:

- track loading state by `(sessionId, eventId)`
- store the lightweight diff response
- append newly loaded hunks for a specific file
- track `nextHunkIndex` per file
- surface error states and truncation metadata to the UI

This keeps raw file viewing and diff viewing separate:

- `FileStore` remains for full-file content
- `DiffStore` handles patch-specific state

### iOS UI Structure

Suggested view split:

- `CodeChangeCard`
  - summary and navigation trigger only
- `DiffViewerView`
  - top-level screen
- `DiffFileSection`
  - one changed file
- `DiffHunkView`
  - one hunk
- `DiffLineRow`
  - one line in a hunk

Use `LazyVStack` in the diff viewer and keep each file section self-contained so SwiftUI can dispose off-screen content more efficiently.

## Data Flow

1. Agent produces a `code_change` event.
2. Bridge persists and broadcasts the normal lightweight event.
3. iOS timeline shows the summary card without requesting any patch body.
4. User taps `View Diff`.
5. iOS sends `diff_req(sessionId, eventId)`.
6. Bridge builds or reuses cached diff data and replies with `diff_content`.
7. `DiffStore` saves the result and the viewer renders:
   - file headers
   - first hunk only
8. User taps `Load next hunk` for a file.
9. iOS sends `diff_hunks_req(sessionId, eventId, path, afterHunkIndex)`.
10. Bridge returns `diff_hunks_content` with the next hunk chunk for that file.
11. `DiffStore` appends the new hunks and the viewer reveals them.

## Diff Generation Strategy

For the first version, favor a deterministic unified diff source over adapter-specific patch events.

The bridge should generate diff content based on the changed file list associated with the target `code_change` event. This keeps the protocol adapter-agnostic and avoids depending on Codex- or Claude-specific partial patch payloads.

Important trade-off:

- the diff is derived from the current workspace state at view time, not from a fully snapshotted historical file version

This means a later workspace edit could cause the viewed diff to drift from the exact original turn. That is acceptable for the first version because:

- the app currently has no historical file snapshot model
- the priority is to unlock a practical mobile review experience with strong runtime performance
- the UI is anchored to recent active sessions where workspace drift is usually low

If historical exactness becomes important later, the architecture can evolve toward storing diff snapshots or versioned file blobs at event time.

## Limits And Guardrails

Define explicit bridge-side limits:

- max files returned per diff response
- max hunks returned per file
- max lines returned per hunk
- max total diff lines per response
- max raw bytes processed for diff generation

Behavior when a limit is exceeded:

- mark the file or response as truncated
- return what fits safely
- surface a user-facing message directing them to `Open File` when needed

These limits should be centralized constants so they can be tuned without rewriting the protocol.

## Error Handling

Bridge-side errors:

- event not found
- requested event is not a `code_change`
- file no longer exists
- diff generation failed
- response truncated

iOS behavior:

- show a clear empty/error state in `Diff Viewer`
- keep the session timeline unaffected
- allow retry for transient failures
- keep `Open File` available where possible

## Testing Strategy

### Protocol and Bridge

- unit tests for `diff_req`, `diff_content`, `diff_hunks_req`, and `diff_hunks_content` encoding/decoding
- bridge tests for loading the right event by `eventId`
- diff parsing tests that normalize unified diff text into file/hunk/line models
- hunk pagination tests for `afterHunkIndex`
- truncation tests for large files and multi-file turns
- cache tests verifying repeat requests reuse the recent result

### iOS Core and Features

- store tests for diff loading, caching, and expansion state
- session router tests for receiving `diff_content`
- view model tests for requesting a diff by `eventId`
- SwiftUI source-level tests for the viewer structure if this codebase already uses that pattern

### Manual Verification

- open a small one-file modification and confirm first hunk renders
- open a multi-file turn and confirm only first hunks render initially
- tap `Load next hunk` and confirm incremental reveal
- open a truncated diff and confirm the UI remains responsive
- switch back to the timeline and confirm session scrolling still feels unchanged

## Rollout Notes

Ship the feature as a dedicated viewer first. Do not also attempt timeline inline patch rendering in the same change set.

That keeps the implementation contained to:

- protocol additions
- bridge diff generation
- iOS diff state and UI

and avoids mixing a valuable feature with a much riskier timeline rendering rewrite.
