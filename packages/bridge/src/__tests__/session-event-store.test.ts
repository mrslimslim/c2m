import test from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { defaultSessionEventLogPath, defaultSessionIndexPath } from "../session-store/path.js";
import { SessionEventLogStore } from "../session-store/event-log.js";

test("default session store paths are stable for the same workDir", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));

  try {
    const indexA = await defaultSessionIndexPath(workDir, { homeDir });
    const indexB = await defaultSessionIndexPath(join(workDir, "."), { homeDir });
    const eventLogPath = await defaultSessionEventLogPath(workDir, "session-1", { homeDir });

    assert.equal(indexA, indexB);
    assert.match(indexA, /[/\\]\.codepilot[/\\]sessions[/\\][a-f0-9]{16}[/\\]index\.json$/);
    assert.equal(dirname(eventLogPath), join(dirname(indexA), "events"));
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});

test("appendEvent writes JSONL and replay returns only events after cursor", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));
  const store = new SessionEventLogStore({ workDir, homeDir });

  try {
    const first = await store.appendEvent({
      sessionId: "session-1",
      timestamp: 1000,
      event: { type: "status", state: "thinking", message: "first" },
    });
    const second = await store.appendEvent({
      sessionId: "session-1",
      timestamp: 1001,
      event: { type: "status", state: "thinking", message: "second" },
    });
    const third = await store.appendEvent({
      sessionId: "session-1",
      timestamp: 1002,
      event: { type: "status", state: "thinking", message: "third" },
    });

    assert.equal(first.eventId, 1);
    assert.equal(second.eventId, 2);
    assert.equal(third.eventId, 3);

    const logPath = await defaultSessionEventLogPath(workDir, "session-1", { homeDir });
    const lines = (await readFile(logPath, "utf-8")).trim().split("\n");
    assert.equal(lines.length, 3);

    const persisted = lines.map((line) => JSON.parse(line) as Record<string, unknown>);
    assert.deepEqual(
      persisted.map((line) => line.eventId),
      [1, 2, 3],
    );

    const replay = await store.readEventsAfter("session-1", 1);
    assert.deepEqual(
      replay.map((record) => record.eventId),
      [2, 3],
    );
    assert.deepEqual(
      replay.map((record) => (record.event as { type: string }).type),
      ["status", "status"],
    );
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});

test("alias remaps persist and resolve to canonical session id", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));

  try {
    const firstStore = new SessionEventLogStore({ workDir, homeDir });
    await firstStore.remapSessionAlias("temp-session", "real-session");
    await firstStore.appendEvent({
      sessionId: "temp-session",
      timestamp: 2000,
      event: { type: "status", state: "thinking", message: "mapped write" },
    });

    const secondStore = new SessionEventLogStore({ workDir, homeDir });
    assert.equal(await secondStore.resolveSessionId("temp-session"), "real-session");
    assert.equal(await secondStore.resolveSessionId("real-session"), "real-session");

    const replay = await secondStore.readEventsAfter("temp-session", 0);
    assert.equal(replay.length, 1);
    assert.equal(replay[0]?.sessionId, "real-session");
    assert.equal(replay[0]?.eventId, 1);
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});

test("latestEventId survives fresh store instances", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));

  try {
    const firstStore = new SessionEventLogStore({ workDir, homeDir });
    await firstStore.appendEvent({
      sessionId: "session-2",
      timestamp: 3000,
      event: { type: "status", state: "thinking", message: "first" },
    });

    const reloadedStore = new SessionEventLogStore({ workDir, homeDir });
    const second = await reloadedStore.appendEvent({
      sessionId: "session-2",
      timestamp: 3001,
      event: { type: "status", state: "thinking", message: "second" },
    });

    assert.equal(second.eventId, 2);

    const index = await reloadedStore.loadSessionIndex("session-2");
    assert.equal(index?.latestEventId, 2);
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});
