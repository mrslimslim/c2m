/**
 * Unit tests for validatePhoneMessage()
 *
 * Covers:
 * - All valid message types pass validation
 * - Missing required fields are rejected
 * - Unknown message types are rejected
 * - Non-object inputs are rejected
 * - Empty text in command messages is rejected
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { validatePhoneMessage } from "../transport/local.js";

// ─── Valid messages ─────────────────────────────────────────────────────────

describe("validatePhoneMessage – valid messages", () => {
  it("accepts a valid command message", () => {
    const result = validatePhoneMessage({ type: "command", text: "hello" });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "command");
  });

  it("accepts a command message with optional sessionId", () => {
    const result = validatePhoneMessage({
      type: "command",
      text: "hello",
      sessionId: "sess-1",
    });
    assert.notEqual(result, null);
  });

  it("accepts a valid cancel message", () => {
    const result = validatePhoneMessage({
      type: "cancel",
      sessionId: "sess-1",
    });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "cancel");
  });

  it("accepts a valid file_req message", () => {
    const result = validatePhoneMessage({
      type: "file_req",
      path: "/tmp/file.txt",
      sessionId: "sess-1",
    });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "file_req");
  });

  it("accepts a valid delete_session message", () => {
    const result = validatePhoneMessage({
      type: "delete_session",
      sessionId: "sess-1",
    });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "delete_session");
  });

  it("accepts a valid list_sessions message", () => {
    const result = validatePhoneMessage({ type: "list_sessions" });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "list_sessions");
  });

  it("accepts a valid ping message", () => {
    const result = validatePhoneMessage({ type: "ping", ts: Date.now() });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "ping");
  });

  it("accepts a valid sync_session message", () => {
    const result = validatePhoneMessage({
      type: "sync_session",
      sessionId: "sess-1",
      afterEventId: 42,
    });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "sync_session");
  });

  it("accepts a valid diff_req message", () => {
    const result = validatePhoneMessage({
      type: "diff_req",
      sessionId: "sess-1",
      eventId: 42,
    });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "diff_req");
  });

  it("accepts a valid diff_hunks_req message", () => {
    const result = validatePhoneMessage({
      type: "diff_hunks_req",
      sessionId: "sess-1",
      eventId: 42,
      path: "Sources/App.swift",
      afterHunkIndex: 1,
    });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "diff_hunks_req");
  });

  it("accepts a valid slash_action message", () => {
    const result = validatePhoneMessage({
      type: "slash_action",
      sessionId: "sess-1",
      commandId: "review",
      arguments: { depth: "full", apply: false, count: 2 },
    });
    assert.notEqual(result, null);
    assert.equal((result as any).type, "slash_action");
  });
});

// ─── Missing required fields ────────────────────────────────────────────────

describe("validatePhoneMessage – missing required fields", () => {
  it("rejects command without text", () => {
    assert.equal(validatePhoneMessage({ type: "command" }), null);
  });

  it("rejects cancel without sessionId", () => {
    assert.equal(validatePhoneMessage({ type: "cancel" }), null);
  });

  it("rejects file_req without path", () => {
    assert.equal(
      validatePhoneMessage({ type: "file_req", sessionId: "s1" }),
      null,
    );
  });

  it("rejects file_req without sessionId", () => {
    assert.equal(
      validatePhoneMessage({ type: "file_req", path: "/tmp/f.txt" }),
      null,
    );
  });

  it("rejects delete_session without sessionId", () => {
    assert.equal(validatePhoneMessage({ type: "delete_session" }), null);
  });

  it("rejects ping without ts", () => {
    assert.equal(validatePhoneMessage({ type: "ping" }), null);
  });

  it("rejects ping with non-number ts", () => {
    assert.equal(
      validatePhoneMessage({ type: "ping", ts: "not-a-number" }),
      null,
    );
  });

  it("rejects sync_session without sessionId", () => {
    assert.equal(
      validatePhoneMessage({ type: "sync_session", afterEventId: 42 }),
      null,
    );
  });

  it("rejects sync_session with non-number afterEventId", () => {
    assert.equal(
      validatePhoneMessage({
        type: "sync_session",
        sessionId: "sess-1",
        afterEventId: "not-a-number",
      }),
      null,
    );
  });

  it("rejects diff_req without sessionId", () => {
    assert.equal(
      validatePhoneMessage({ type: "diff_req", eventId: 42 }),
      null,
    );
  });

  it("rejects diff_req without numeric eventId", () => {
    assert.equal(
      validatePhoneMessage({ type: "diff_req", sessionId: "sess-1", eventId: "42" }),
      null,
    );
  });

  it("rejects diff_hunks_req without path", () => {
    assert.equal(
      validatePhoneMessage({
        type: "diff_hunks_req",
        sessionId: "sess-1",
        eventId: 42,
        afterHunkIndex: 1,
      }),
      null,
    );
  });

  it("rejects diff_hunks_req without numeric afterHunkIndex", () => {
    assert.equal(
      validatePhoneMessage({
        type: "diff_hunks_req",
        sessionId: "sess-1",
        eventId: 42,
        path: "Sources/App.swift",
        afterHunkIndex: "1",
      }),
      null,
    );
  });

  it("rejects slash_action without commandId", () => {
    assert.equal(
      validatePhoneMessage({ type: "slash_action", sessionId: "sess-1" }),
      null,
    );
  });

  it("rejects slash_action with non-object arguments", () => {
    assert.equal(
      validatePhoneMessage({
        type: "slash_action",
        commandId: "review",
        arguments: "full",
      }),
      null,
    );
  });
});

// ─── Unknown type ───────────────────────────────────────────────────────────

describe("validatePhoneMessage – unknown type", () => {
  it("rejects an unknown type string", () => {
    assert.equal(
      validatePhoneMessage({ type: "unknown_action", text: "hi" }),
      null,
    );
  });

  it("rejects numeric type", () => {
    assert.equal(validatePhoneMessage({ type: 42 }), null);
  });

  it("rejects missing type field", () => {
    assert.equal(validatePhoneMessage({ text: "hello" }), null);
  });
});

// ─── Non-object inputs ──────────────────────────────────────────────────────

describe("validatePhoneMessage – non-object inputs", () => {
  it("rejects null", () => {
    assert.equal(validatePhoneMessage(null), null);
  });

  it("rejects undefined", () => {
    assert.equal(validatePhoneMessage(undefined), null);
  });

  it("rejects a number", () => {
    assert.equal(validatePhoneMessage(123), null);
  });

  it("rejects a string", () => {
    assert.equal(validatePhoneMessage("hello"), null);
  });

  it("rejects a boolean", () => {
    assert.equal(validatePhoneMessage(true), null);
  });

  it("rejects an array", () => {
    assert.equal(
      validatePhoneMessage([{ type: "command", text: "hi" }]),
      null,
    );
  });
});

// ─── Empty text in command ──────────────────────────────────────────────────

describe("validatePhoneMessage – empty text in command", () => {
  it("rejects command with empty string text", () => {
    assert.equal(validatePhoneMessage({ type: "command", text: "" }), null);
  });

  it("rejects command with non-string text", () => {
    assert.equal(validatePhoneMessage({ type: "command", text: 123 }), null);
  });

  it("rejects command with non-string sessionId", () => {
    assert.equal(
      validatePhoneMessage({ type: "command", text: "hi", sessionId: 42 }),
      null,
    );
  });
});
