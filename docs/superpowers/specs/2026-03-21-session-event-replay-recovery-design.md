# Session Event Replay Recovery Design

**Topic:** Bridge-side event persistence and client replay recovery for interrupted session streams

**Date:** 2026-03-21

## Goal

Prevent in-progress session output from appearing truncated when the mobile client disconnects, the app is backgrounded or relaunched, or network quality causes a transport interruption.

If the bridge has already received agent events, the system should persist them locally and replay any missing events after the client reconnects so the visible conversation can be reconstructed without gaps.

## Problem

Today the bridge behaves like a transient event forwarder:

- agent events are kept only in memory
- streamed output is pushed to the currently connected client only
- the iOS app persists a local snapshot of the timeline, but it cannot recover events that were emitted after the snapshot and before the app disconnected

This creates a severe failure mode for long-running turns:

- the user can see partial assistant output
- the app can be closed or disconnected during streaming
- reopening the app restores only the last local snapshot
- the missing portion of the assistant output is permanently lost even though the bridge may already have received it

## Scope

This design covers first-phase recovery semantics only:

- persist every bridge-received session event locally
- allow clients to request replay from a known event cursor
- resume real-time delivery after replay completes
- preserve compatibility with current session remap behavior
- integrate replay with existing iOS snapshot persistence

## Non-Goals

- recovering output that the bridge never received
- rehydrating full history directly from Codex or Claude after a bridge outage
- introducing a full database-backed delivery system
- redesigning the timeline UI
- multi-user coordination semantics

## Recommended Approach

Use an append-only per-session event log on the bridge plus a per-session monotonic `eventId`.

The bridge becomes the source of truth for replayable session history:

1. receive a unified `AgentEvent`
2. assign the next `eventId` for that session
3. persist the event record to disk
4. update in-memory session state
5. distribute the event to connected clients

Clients persist only their local projection:

- rendered timeline
- current session metadata
- `lastAppliedEventId` per session

After reconnect, the client requests replay from its last applied cursor and the bridge re-sends only the missing events.

## Architecture

### Bridge Event Store

Store replay data under the user home directory, parallel to pairing state:

- `~/.codepilot/sessions/<workDirHash>/index.json`
- `~/.codepilot/sessions/<workDirHash>/events/<sessionId>.jsonl`

Why this location:

- it avoids polluting the project worktree
- it remains stable across app relaunches
- it matches the persistence pattern already used for pairing material

`workDirHash` should be derived from the normalized real path of the bridge working directory using the same stable hashing approach already used for pairing state.

### Event Record Format

Each JSONL line represents exactly one replayable event:

```json
{
  "eventId": 14,
  "sessionId": "session-123",
  "timestamp": 1774060800000,
  "event": {
    "type": "agent_message",
    "text": "Draft complete."
  }
}
```

Rules:

- `eventId` is monotonically increasing within a session
- `timestamp` is the bridge send timestamp
- records are append-only
- replay order is strictly ascending by `eventId`

### Session Index Format

`index.json` keeps lightweight metadata needed for discovery and replay:

- session info snapshot
- latest persisted `eventId`
- canonical session id
- alias ids that now resolve to the canonical id
- log file path

This avoids scanning every JSONL file to answer simple questions such as the current session list or whether a replay request is valid.

### Session ID Remap Handling

Codex can replace an initial temporary session id with the real thread id. Replay must preserve continuity across this remap.

Bridge behavior:

- maintain an alias map from old id to canonical id
- migrate in-memory session bookkeeping when the real id appears
- persist alias metadata in `index.json`
- write all future events under the canonical session log

Client behavior:

- accept an optional `resolvedSessionId` during replay completion
- migrate local timeline, drafts, and cursor state from the temporary id to the canonical id

## Protocol Changes

### Existing Message Extension

Extend bridge `event` messages with `eventId`.

Current shape:

```json
{
  "type": "event",
  "sessionId": "session-123",
  "event": { "type": "thinking", "text": "..." },
  "timestamp": 1774060800000
}
```

New shape:

```json
{
  "type": "event",
  "sessionId": "session-123",
  "eventId": 14,
  "event": { "type": "thinking", "text": "..." },
  "timestamp": 1774060800000
}
```

### New Phone Message

Add `sync_session`:

```json
{
  "type": "sync_session",
  "sessionId": "session-123",
  "afterEventId": 11
}
```

Semantics:

- the client has successfully applied events through `11`
- the bridge should replay events starting from `12`

### New Bridge Message

Add `session_sync_complete`:

```json
{
  "type": "session_sync_complete",
  "sessionId": "session-123",
  "latestEventId": 14,
  "resolvedSessionId": "real-session-123"
}
```

`resolvedSessionId` is optional and is only used when alias resolution changed the canonical session id.

## Delivery And Replay Flow

### Real-Time Delivery

Per session, the bridge must follow this order:

1. allocate next `eventId`
2. append the event record to the session log
3. update in-memory session state
4. enqueue delivery for connected clients

The critical invariant is:

> If an event was visible to any bridge delivery path, it must already exist in persistent storage.

### Reconnect Flow

After socket reconnect and handshake:

1. bridge sends `session_list`
2. client restores local snapshot state
3. client sends `sync_session` for each session it wants to recover
4. bridge replays persisted events with `eventId > afterEventId`
5. bridge emits `session_sync_complete`
6. bridge continues normal live delivery

### Ordering Guarantee

Replay and live delivery must not interleave out of order for the same client and session.

Recommended bridge behavior:

- mark a `(clientId, sessionId)` pair as `syncing`
- while syncing, queue new live events for that client-session pair
- send replayed historical events in `eventId` order
- flush any queued live events in `eventId` order
- send `session_sync_complete`
- transition the pair back to live pass-through

This guarantees a client never sees:

- event `15` live
- then replayed event `12`
- then replayed event `13`

## Bridge Runtime Changes

The bridge currently forwards events to the client associated with the original command call. That behavior is incompatible with reconnect recovery because a new socket would miss ongoing output even after replay.

Required change:

- route session events through a session event hub
- broadcast or fan out to all connected clients that are authorized for the bridge
- keep replay state per client-session pair instead of binding live output to one stale client reference

This is required even for first-phase recovery.

## iOS Client Changes

The iOS app already persists:

- `SessionStore`
- `TimelineStore`
- `FileStore`
- session-to-connection mapping

That snapshot behavior should remain, but it needs replay cursors.

### New Local State

Persist:

- `lastAppliedEventIdBySessionID: [String: Int]`

This can be added to the existing `ConversationSnapshot`.

### Event Application Rules

When the app receives `BridgeMessage.event(sessionId, eventId, event, timestamp)`:

- resolve the canonical session id via existing alias logic
- read the local `lastAppliedEventId`
- if `eventId <= lastAppliedEventId`, ignore the event as a duplicate
- if `eventId == lastAppliedEventId + 1`, append it and advance the cursor
- if `eventId > lastAppliedEventId + 1`, mark the session as needing replay and request `sync_session`

The app should not rely on timestamps for deduplication or ordering.

### Relaunch Behavior

On cold launch:

1. restore the local conversation snapshot immediately
2. reconnect to the bridge
3. request `sync_session` for known sessions using stored cursors
4. merge replayed events into the existing timeline

This produces the desired UX:

- the user sees previously saved conversation state immediately
- any gap that the bridge can account for is filled automatically
- the session continues streaming from the point of reconnection

## Compatibility Strategy

The rollout should be backward compatible.

### New Bridge With Old Client

- old clients ignore replay-specific capabilities
- normal chat continues to work
- no replay recovery is available

### New Client With Old Bridge

- client detects missing `eventId` or unsupported `sync_session`
- client falls back to current snapshot-only behavior

### New Bridge With New Client

- full replay recovery is enabled

## Error Handling

### Missing Session Log

If the client asks to sync a session whose log no longer exists:

- bridge returns a normal error message
- client keeps the existing local snapshot
- UI can show that recovery could not be completed

### Corrupt Log

If a log file is corrupt:

- bridge should fail closed for that session
- do not emit partial, unverified replay from a damaged range
- report the error explicitly

### Large Replay

Phase one can replay the full missing range eagerly. If replay size becomes a practical issue later, chunking can be added without changing the core model.

## Testing

### Protocol Tests

- validate `sync_session` decoding and encoding
- validate `session_sync_complete` decoding and encoding
- validate `event` message round-trips with `eventId`

### Bridge Tests

- persist then replay missing events from a cursor
- preserve event order during replay
- handle Codex temp-id to real-id remap without splitting history
- continue live delivery after replay completes
- avoid duplicate delivery when replay overlaps with already-applied events
- keep old client behavior intact when no sync request is made

### iOS Tests

- snapshot round-trip includes per-session event cursors
- duplicate `eventId` is ignored
- replay gap detection triggers `sync_session`
- alias remap migrates cursor state
- cold launch restores snapshot and then applies replayed events without duplication

## Rollout Plan

1. Extend protocol models and validation
2. Implement bridge event store and replay API
3. Change bridge delivery from single-client forwarding to session event fan-out
4. Extend iOS protocol models and local snapshot schema
5. Implement iOS cursor tracking and replay requests
6. Add regression tests across protocol, bridge, and iOS packages

## Success Criteria

This work is successful when:

- a client can disconnect during an active turn
- the bridge continues receiving and persisting events
- the client reconnects and automatically requests replay
- the missing assistant output appears in the correct order
- the session continues streaming live without duplicate or out-of-order timeline items
