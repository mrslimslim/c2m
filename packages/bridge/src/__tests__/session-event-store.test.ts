import test from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { appendFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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

test("parallel appends to the same session return unique monotonic event ids", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));
  const store = new SessionEventLogStore({ workDir, homeDir });

  try {
    const writes = Array.from({ length: 10 }, (_, i) => store.appendEvent({
      sessionId: "parallel-session",
      timestamp: 4000 + i,
      event: { type: "status", state: "thinking", message: `parallel-${i}` },
    }));
    const events = await Promise.all(writes);
    const ids = events.map((event) => event.eventId).sort((a, b) => a - b);

    assert.deepEqual(ids, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});

test("parallel appends to different sessions both persist index entries", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));
  const store = new SessionEventLogStore({ workDir, homeDir });

  try {
    await Promise.all([
      store.appendEvent({
        sessionId: "session-a",
        timestamp: 5000,
        event: { type: "status", state: "thinking", message: "a" },
      }),
      store.appendEvent({
        sessionId: "session-b",
        timestamp: 5001,
        event: { type: "status", state: "thinking", message: "b" },
      }),
    ]);

    assert.ok(await store.loadSessionIndex("session-a"));
    assert.ok(await store.loadSessionIndex("session-b"));
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});

test("appendEvent recovers latest id from log when metadata lags behind", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));

  try {
    const store = new SessionEventLogStore({ workDir, homeDir });
    await store.appendEvent({
      sessionId: "session-recover",
      timestamp: 6000,
      event: { type: "status", state: "thinking", message: "first" },
    });
    await store.appendEvent({
      sessionId: "session-recover",
      timestamp: 6001,
      event: { type: "status", state: "thinking", message: "second" },
    });

    const indexPath = await defaultSessionIndexPath(workDir, { homeDir });
    const index = JSON.parse(await readFile(indexPath, "utf-8")) as {
      version: number;
      sessions: Record<string, { latestEventId: number }>;
      aliases: Record<string, string>;
    };
    index.sessions["session-recover"]!.latestEventId = 1;
    await writeFile(indexPath, `${JSON.stringify(index, null, 2)}\n`, "utf-8");

    const reloaded = new SessionEventLogStore({ workDir, homeDir });
    const third = await reloaded.appendEvent({
      sessionId: "session-recover",
      timestamp: 6002,
      event: { type: "status", state: "thinking", message: "third" },
    });

    assert.equal(third.eventId, 3);
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});

test("replay tolerates a torn final JSONL line", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));

  try {
    const store = new SessionEventLogStore({ workDir, homeDir });
    await store.appendEvent({
      sessionId: "session-torn",
      timestamp: 7000,
      event: { type: "status", state: "thinking", message: "first" },
    });
    await store.appendEvent({
      sessionId: "session-torn",
      timestamp: 7001,
      event: { type: "status", state: "thinking", message: "second" },
    });

    const logPath = await defaultSessionEventLogPath(workDir, "session-torn", { homeDir });
    await appendFile(logPath, "{\"eventId\":3", "utf-8");

    const replay = await store.readEventsAfter("session-torn", 0);
    assert.deepEqual(replay.map((event) => event.eventId), [1, 2]);
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});

test("alias remap preserves alias history when canonical log already exists", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));

  try {
    const store = new SessionEventLogStore({ workDir, homeDir });
    await store.appendEvent({
      sessionId: "temp-alias",
      timestamp: 8000,
      event: { type: "status", state: "thinking", message: "alias-before-remap" },
    });
    await store.appendEvent({
      sessionId: "real-canonical",
      timestamp: 8001,
      event: { type: "status", state: "thinking", message: "canonical-before-remap" },
    });

    await store.remapSessionAlias("temp-alias", "real-canonical");
    const replay = await store.readEventsAfter("real-canonical", 0);

    assert.deepEqual(
      replay.map((event) => (event.event as { message: string }).message),
      ["alias-before-remap", "canonical-before-remap"],
    );
    assert.deepEqual(replay.map((event) => event.eventId), [1, 2]);
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});
