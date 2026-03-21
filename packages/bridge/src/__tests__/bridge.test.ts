import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { AgentEvent, SessionInfo } from "@codepilot/protocol";
import type { AgentAdapter, SessionOptions } from "../adapters/types.js";
import { Bridge } from "../bridge.js";
import { SessionEventLogStore } from "../session-store/event-log.js";

type RecordedMessage = Record<string, unknown>;

interface TestClient {
  id: string;
  sent: RecordedMessage[];
  send(message: unknown): void;
}

interface BridgeInternals {
  transport: { broadcast: (message?: unknown) => void };
  adapter: AgentAdapter;
  handleCommand: (
    client: TestClient,
    text: string,
    sessionId?: string,
  ) => Promise<void>;
  handleMessage: (
    client: TestClient,
    message: Record<string, unknown>,
  ) => Promise<void>;
  sessions: Map<string, SessionInfo>;
  connectedClients: Map<string, TestClient>;
  sessionEventStore: SessionEventLogStore;
}

interface BridgeHarness {
  bridgeAny: BridgeInternals;
  homeDir: string;
  workDir: string;
}

function createDeferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (reason?: unknown) => void;
} {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function createClient(id: string): TestClient {
  const sent: RecordedMessage[] = [];
  return {
    id,
    sent,
    send(message: unknown): void {
      if (typeof message === "object" && message !== null) {
        sent.push(message as RecordedMessage);
      }
    },
  };
}

function connectClient(bridgeAny: BridgeInternals, client: TestClient): void {
  bridgeAny.connectedClients.set(client.id, client);
}

function eventMessages(client: TestClient): RecordedMessage[] {
  return client.sent.filter((message) => message.type === "event");
}

function eventIds(client: TestClient): number[] {
  return eventMessages(client).map((message) => message.eventId as number);
}

function statusMessages(client: TestClient): string[] {
  return eventMessages(client).map((message) => {
    const event = message.event as Record<string, unknown>;
    return String(event.message);
  });
}

function lastSessionSyncComplete(client: TestClient): RecordedMessage {
  const message = [...client.sent].reverse().find((entry) => entry.type === "session_sync_complete");
  assert.ok(message, "expected session_sync_complete message");
  return message;
}

async function waitFor(
  predicate: () => boolean,
  failureMessage: string,
): Promise<void> {
  for (let i = 0; i < 100; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(failureMessage);
}

async function createBridgeHarness(): Promise<BridgeHarness> {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));
  const bridge = new Bridge({
    agent: "codex",
    port: 0,
    workDir,
  });
  const bridgeAny = bridge as unknown as BridgeInternals;
  bridgeAny.transport = { broadcast: () => {} };
  bridgeAny.connectedClients = new Map<string, TestClient>();
  bridgeAny.sessionEventStore = new SessionEventLogStore({ workDir, homeDir });
  return { bridgeAny, homeDir, workDir };
}

async function withBridgeHarness(
  run: (harness: BridgeHarness) => Promise<void>,
): Promise<void> {
  const harness = await createBridgeHarness();
  try {
    await run(harness);
  } finally {
    await rm(harness.homeDir, { recursive: true, force: true });
    await rm(harness.workDir, { recursive: true, force: true });
  }
}

class FakeAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  startSessionCalls = 0;
  executeCalls = 0;
  sessionMap = new Map<string, SessionInfo>();
  lastExecuteSessionId: string | null = null;
  canceledSessionIds: string[] = [];

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    this.startSessionCalls += 1;
    const session: SessionInfo = {
      id: "temp-session",
      agentType: "codex",
      workDir: opts.workDir,
      state: "idle",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    };
    this.sessionMap.set(session.id, session);
    return session;
  }

  async execute(
    sessionId: string,
    _input: string,
    onEvent: (event: AgentEvent) => void,
  ): Promise<void> {
    this.executeCalls += 1;
    const session = this.sessionMap.get(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const realId = sessionId === "temp-session" ? "real-session" : sessionId;
    if (realId !== session.id) {
      this.sessionMap.delete(session.id);
      session.id = realId;
      this.sessionMap.set(session.id, session);
    }

    this.lastExecuteSessionId = session.id;
    onEvent({
      type: "status",
      state: "thinking",
      message: "Simulating thread id remap",
    });
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    const session = this.sessionMap.get(sessionId);
    if (!session) {
      throw new Error("resumeSession not implemented for unknown id");
    }
    return session;
  }

  cancel(sessionId: string): void {
    this.canceledSessionIds.push(sessionId);
  }

  dispose(): void {}
}

class MultiSessionAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  private counter = 0;
  startedSessionIds: string[] = [];

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    this.counter += 1;
    const id = `session-${this.counter}`;
    this.startedSessionIds.push(id);
    return {
      id,
      agentType: "codex",
      workDir: opts.workDir,
      state: "idle",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    };
  }

  async execute(
    _sessionId: string,
    _input: string,
    onEvent: (event: AgentEvent) => void,
  ): Promise<void> {
    onEvent({
      type: "status",
      state: "thinking",
      message: "event",
    });
  }

  async resumeSession(_sessionId: string): Promise<SessionInfo> {
    throw new Error("not used");
  }

  cancel(): void {}

  dispose(): void {}
}

class RemapDuringExecuteAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  sessionMap = new Map<string, SessionInfo>();

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    const session: SessionInfo = {
      id: "temp-session-remap",
      agentType: "codex",
      workDir: opts.workDir,
      state: "idle",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    };
    this.sessionMap.set(session.id, session);
    return session;
  }

  async execute(
    sessionId: string,
    _input: string,
    onEvent: (event: AgentEvent) => void,
  ): Promise<void> {
    const session = this.sessionMap.get(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    onEvent({ type: "status", state: "thinking", message: "before remap" });

    this.sessionMap.delete(session.id);
    session.id = "real-session-remap";
    this.sessionMap.set(session.id, session);

    onEvent({ type: "status", state: "thinking", message: "after remap" });
  }

  async resumeSession(_sessionId: string): Promise<SessionInfo> {
    throw new Error("not used");
  }

  cancel(): void {}

  dispose(): void {}
}

class SingleSessionAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  private session: SessionInfo | null = null;
  private eventCounter = 0;

  constructor(private readonly sessionId: string) {}

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    if (!this.session) {
      this.session = {
        id: this.sessionId,
        agentType: "codex",
        workDir: opts.workDir,
        state: "idle",
        createdAt: Date.now(),
        lastActiveAt: Date.now(),
      };
    }
    return this.session;
  }

  async execute(
    sessionId: string,
    _input: string,
    onEvent: (event: AgentEvent) => void,
  ): Promise<void> {
    assert.equal(sessionId, this.sessionId);
    this.eventCounter += 1;
    onEvent({
      type: "status",
      state: "thinking",
      message: `event-${this.eventCounter}`,
    });
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    if (!this.session || this.session.id !== sessionId) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    return this.session;
  }

  cancel(): void {}

  dispose(): void {}
}

class ControlledStreamingAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  private readonly executeStarted = createDeferred<void>();
  private readonly executeFinished = createDeferred<void>();
  private session: SessionInfo | null = null;
  private onEvent: ((event: AgentEvent) => void) | null = null;

  constructor(private readonly sessionId: string) {}

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    if (!this.session) {
      this.session = {
        id: this.sessionId,
        agentType: "codex",
        workDir: opts.workDir,
        state: "idle",
        createdAt: Date.now(),
        lastActiveAt: Date.now(),
      };
    }
    return this.session;
  }

  async execute(
    sessionId: string,
    _input: string,
    onEvent: (event: AgentEvent) => void,
  ): Promise<void> {
    assert.equal(sessionId, this.sessionId);
    this.onEvent = onEvent;
    this.executeStarted.resolve();
    await this.executeFinished.promise;
  }

  async waitUntilExecuting(): Promise<void> {
    await this.executeStarted.promise;
  }

  emit(event: AgentEvent): void {
    assert.ok(this.onEvent, "expected execute() to register an event callback");
    this.onEvent(event);
  }

  finish(): void {
    this.executeFinished.resolve();
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    if (!this.session || this.session.id !== sessionId) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    return this.session;
  }

  cancel(): void {}

  dispose(): void {}
}

test("Bridge keeps the new Codex thread ID and reuses it for follow-up commands", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const adapter = new FakeAdapter();
    bridgeAny.adapter = adapter;

    const client = createClient("client");
    connectClient(bridgeAny, client);

    await bridgeAny.handleCommand(client, "first command", undefined);
    assert.equal(adapter.startSessionCalls, 1);
    assert.equal(adapter.executeCalls, 1);
    assert.equal(adapter.lastExecuteSessionId, "real-session");
    assert.ok(bridgeAny.sessions.has("real-session"));
    assert.ok(!bridgeAny.sessions.has("temp-session"));

    await bridgeAny.handleCommand(client, "second command", "real-session");
    assert.equal(adapter.startSessionCalls, 1, "should not restart the session");
    assert.equal(adapter.executeCalls, 2);
    assert.equal(adapter.lastExecuteSessionId, "real-session");
  });
});

test("Bridge emits eventId values that are monotonic within each session", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const adapter = new MultiSessionAdapter();
    bridgeAny.adapter = adapter;

    const client = createClient("client");
    connectClient(bridgeAny, client);

    await bridgeAny.handleCommand(client, "s1 first");
    await bridgeAny.handleCommand(client, "s2 first");
    await bridgeAny.handleCommand(client, "s1 second", "session-1");
    await bridgeAny.handleCommand(client, "s2 second", "session-2");

    const bySession = new Map<string, number[]>();
    for (const message of eventMessages(client)) {
      const sessionId = message.sessionId;
      const eventId = message.eventId;
      assert.equal(typeof sessionId, "string");
      assert.equal(typeof eventId, "number");
      const ids = bySession.get(sessionId as string) ?? [];
      ids.push(eventId as number);
      bySession.set(sessionId as string, ids);
    }

    assert.deepEqual(bySession.get("session-1"), [1, 2]);
    assert.deepEqual(bySession.get("session-2"), [1, 2]);
  });
});

test("Bridge preserves eventId continuity across temp-to-real session remaps", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new RemapDuringExecuteAdapter();

    const client = createClient("client");
    connectClient(bridgeAny, client);

    await bridgeAny.handleCommand(client, "command with remap");
    await bridgeAny.handleCommand(client, "follow-up after remap", "real-session-remap");

    assert.deepEqual(eventIds(client), [1, 2, 3, 4]);
  });
});

test("Bridge resolves temp session aliases for follow-up command and cancel", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const adapter = new FakeAdapter();
    bridgeAny.adapter = adapter;

    const client = createClient("client");
    connectClient(bridgeAny, client);

    await bridgeAny.handleCommand(client, "first command");
    await bridgeAny.handleCommand(client, "follow-up command still using temp id", "temp-session");

    assert.equal(adapter.startSessionCalls, 1);
    assert.equal(adapter.executeCalls, 2);
    assert.equal(adapter.lastExecuteSessionId, "real-session");
    assert.deepEqual(eventIds(client), [1, 2]);

    await bridgeAny.handleMessage(client, { type: "cancel", sessionId: "temp-session" });
    assert.deepEqual(adapter.canceledSessionIds, ["real-session"]);

    const cancelEvent = client.sent[client.sent.length - 1];
    assert.equal(cancelEvent.type, "event");
    assert.equal(cancelEvent.sessionId, "real-session");
    assert.equal(cancelEvent.eventId, 3);
  });
});

test("Bridge replays only events after the requested event cursor on reconnect", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new SingleSessionAdapter("session-replay");

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    await bridgeAny.handleCommand(originalClient, "event 1");
    await bridgeAny.handleCommand(originalClient, "event 2", "session-replay");
    await bridgeAny.handleCommand(originalClient, "event 3", "session-replay");
    await bridgeAny.handleCommand(originalClient, "event 4", "session-replay");
    await bridgeAny.handleCommand(originalClient, "event 5", "session-replay");

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    await bridgeAny.handleMessage(reconnectClient, {
      type: "sync_session",
      sessionId: "session-replay",
      afterEventId: 3,
    });

    assert.deepEqual(eventIds(reconnectClient), [4, 5]);
    assert.deepEqual(statusMessages(reconnectClient), ["event-4", "event-5"]);

    const syncComplete = lastSessionSyncComplete(reconnectClient);
    assert.equal(syncComplete.sessionId, "session-replay");
    assert.equal(syncComplete.latestEventId, 5);
  });
});

test("Bridge queues live events during replay and flushes them in eventId order", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new SingleSessionAdapter("session-queue");

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    await bridgeAny.handleCommand(originalClient, "event 1");
    await bridgeAny.handleCommand(originalClient, "event 2", "session-queue");
    await bridgeAny.handleCommand(originalClient, "event 3", "session-queue");

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    const store = bridgeAny.sessionEventStore;
    const replaySnapshot = await store.readEventsAfter("session-queue", 0);
    const originalReadEventsAfter = store.readEventsAfter.bind(store);
    const replayStarted = createDeferred<void>();
    const replayRelease = createDeferred<void>();

    store.readEventsAfter = async () => {
      replayStarted.resolve();
      await replayRelease.promise;
      return replaySnapshot;
    };

    try {
      const syncPromise = bridgeAny.handleMessage(reconnectClient, {
        type: "sync_session",
        sessionId: "session-queue",
        afterEventId: 0,
      });

      await replayStarted.promise;
      await bridgeAny.handleCommand(originalClient, "event 4", "session-queue");
      await bridgeAny.handleCommand(originalClient, "event 5", "session-queue");

      assert.deepEqual(
        eventIds(reconnectClient),
        [],
        "reconnecting client should not receive live events before replay finishes",
      );

      replayRelease.resolve();
      await syncPromise;
    } finally {
      store.readEventsAfter = originalReadEventsAfter;
    }

    assert.deepEqual(eventIds(reconnectClient), [1, 2, 3, 4, 5]);
    assert.deepEqual(statusMessages(reconnectClient), [
      "event-1",
      "event-2",
      "event-3",
      "event-4",
      "event-5",
    ]);

    const syncComplete = lastSessionSyncComplete(reconnectClient);
    assert.equal(syncComplete.sessionId, "session-queue");
    assert.equal(syncComplete.latestEventId, 5);
  });
});

test("Bridge replays a temp Codex session alias as one continuous session history", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new RemapDuringExecuteAdapter();

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    await bridgeAny.handleCommand(originalClient, "first command");
    await bridgeAny.handleCommand(originalClient, "second command", "real-session-remap");

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    await bridgeAny.handleMessage(reconnectClient, {
      type: "sync_session",
      sessionId: "temp-session-remap",
      afterEventId: 1,
    });

    assert.deepEqual(eventIds(reconnectClient), [2, 3, 4]);
    assert.deepEqual(
      eventMessages(reconnectClient).map((message) => message.sessionId),
      ["real-session-remap", "real-session-remap", "real-session-remap"],
    );

    const syncComplete = lastSessionSyncComplete(reconnectClient);
    assert.equal(syncComplete.sessionId, "real-session-remap");
    assert.equal(syncComplete.resolvedSessionId, "real-session-remap");
    assert.equal(syncComplete.latestEventId, 4);
  });
});

test("Bridge sends ongoing session output to a newly connected client after replay", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const adapter = new ControlledStreamingAdapter("session-live");
    bridgeAny.adapter = adapter;

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    const commandPromise = bridgeAny.handleCommand(originalClient, "streaming command");
    await adapter.waitUntilExecuting();

    adapter.emit({ type: "status", state: "thinking", message: "event-1" });
    await waitFor(
      () => eventIds(originalClient).length === 1,
      "original client should receive the first live event",
    );

    bridgeAny.connectedClients.delete(originalClient.id);

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    await bridgeAny.handleMessage(reconnectClient, {
      type: "sync_session",
      sessionId: "session-live",
      afterEventId: 0,
    });

    adapter.emit({ type: "status", state: "thinking", message: "event-2" });
    await waitFor(
      () => eventIds(reconnectClient).length === 2,
      "reconnected client should receive replayed and live events",
    );

    adapter.finish();
    await commandPromise;

    assert.deepEqual(statusMessages(originalClient), ["event-1"]);
    assert.deepEqual(statusMessages(reconnectClient), ["event-1", "event-2"]);
  });
});
