# Deep Testing And Optimization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add regression coverage for the highest-risk bridge paths and fix the implementation so the checks stay green.

**Architecture:** Reuse the current `node:test` setup, add integration-style tests around the bridge and local/relay transport boundaries, then apply minimal production fixes in bridge and transport layers. Avoid broad refactors so the new tests stay tightly coupled to the bugs they guard.

**Tech Stack:** TypeScript, Node.js test runner, pnpm workspaces, ws, Cloudflare relay package

---

### Task 1: Add regression tests for filesystem and transport safety

**Files:**
- Modify: `packages/bridge/src/__tests__/security.test.ts`
- Create: `packages/bridge/src/__tests__/local-transport.test.ts`
- Create: `packages/bridge/src/__tests__/relay-transport.test.ts`

**Step 1: Write the failing tests**

- Add a symlink escape test that proves lexical checks are insufficient.
- Add a local transport test that proves plaintext is rejected after E2E handshake.
- Add a relay transport test that proves `stop()` does not schedule reconnects.

**Step 2: Run the focused tests to verify they fail**

Run: `pnpm test -- --test-name-pattern=\"symlink|plaintext|stop\"`

Expected: at least one new test fails for the intended reason.

**Step 3: Write minimal implementation**

- Harden path validation with realpath-based checks.
- Reject plaintext fallback on E2E-authenticated sockets.
- Suppress reconnect after intentional relay shutdown.

**Step 4: Run tests to verify they pass**

Run: `pnpm test`

Expected: all unit tests pass.

### Task 2: Add bridge-level session remap regression coverage

**Files:**
- Create: `packages/bridge/src/__tests__/bridge.test.ts`
- Modify: `packages/bridge/src/bridge.ts`

**Step 1: Write the failing test**

- Simulate a Codex-style temp session ID that emits a later real thread ID and verify a follow-up command reuses the same session.

**Step 2: Run the targeted test to verify it fails**

Run: `pnpm test -- --test-name-pattern=\"session\"`

Expected: bridge creates a duplicate session before the fix.

**Step 3: Write minimal implementation**

- Keep bridge session lookup synchronized with the current `SessionInfo.id`.

**Step 4: Run tests to verify they pass**

Run: `pnpm test`

Expected: session remap regression passes with the rest of the suite.

### Task 3: Productize the test entrypoints

**Files:**
- Modify: `package.json`
- Optionally modify: `packages/bridge/package.json`

**Step 1: Add the smallest useful scripts**

- `test`
- `test:unit`
- `check`

**Step 2: Run the scripts**

Run: `pnpm test`
Run: `pnpm run check`

Expected: both succeed and cover the newly added regressions.
