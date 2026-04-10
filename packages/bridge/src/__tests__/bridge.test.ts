import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { AgentEvent, SessionConfig, SessionInfo } from "@codepilot/protocol";
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
  diffService: {
    loadDiff: (sessionId: string, eventId: number) => Promise<RecordedMessage>;
    loadMoreHunks: (
      sessionId: string,
      eventId: number,
      path: string,
      afterHunkIndex: number,
    ) => Promise<RecordedMessage>;
  };
  adapterVersion?: string;
  handleCommand: (
    client: TestClient,
    text: string,
    sessionId?: string,
    config?: SessionConfig,
  ) => Promise<void>;
  handleClientConnected: (client: TestClient) => void;
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
  cancelCalls: string[] = [];
  deleteCalls: string[] = [];
  sessionMap = new Map<string, SessionInfo>();
  lastExecuteSessionId: string | null = null;
  canceledSessionIds: string[] = [];
  lastStartOptions: SessionOptions | null = null;
  lastExecuteOptions: SessionOptions | undefined;

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    this.startSessionCalls += 1;
    this.lastStartOptions = opts;
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
    opts?: SessionOptions,
  ): Promise<void> {
    this.executeCalls += 1;
    this.lastExecuteOptions = opts;
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
    this.cancelCalls.push(sessionId);
  }

  deleteSession(sessionId: string): void {
    this.deleteCalls.push(sessionId);
    this.sessionMap.delete(sessionId);
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
    _opts?: SessionOptions,
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

  deleteSession(): void {}

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
    _opts?: SessionOptions,
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

  deleteSession(): void {}

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
    _opts?: SessionOptions,
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

  deleteSession(): void {}

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
    _opts?: SessionOptions,
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

  deleteSession(): void {}

  dispose(): void {}
}

class LateRemapStreamingAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  private readonly executeStarted = createDeferred<void>();
  private readonly executeFinished = createDeferred<void>();
  private session: SessionInfo | null = null;
  private onEvent: ((event: AgentEvent) => void) | null = null;

  constructor(
    private readonly tempSessionId: string,
    private readonly realSessionId: string,
  ) {}

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    if (!this.session) {
      this.session = {
        id: this.tempSessionId,
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
    _opts?: SessionOptions,
  ): Promise<void> {
    assert.equal(sessionId, this.tempSessionId);
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

  remapAndEmit(event: AgentEvent): void {
    assert.ok(this.session, "expected session to exist before remap");
    assert.ok(this.onEvent, "expected execute() to register an event callback");
    this.session.id = this.realSessionId;
    this.onEvent(event);
  }

  finish(): void {
    this.executeFinished.resolve();
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    if (!this.session) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    if (sessionId !== this.tempSessionId && sessionId !== this.realSessionId) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    return this.session;
  }

  cancel(): void {}

  deleteSession(): void {}

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

test("Bridge sends the slash catalog to newly connected clients", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new FakeAdapter();
    bridgeAny.adapterVersion = "0.116.0";

    const client = createClient("client");
    bridgeAny.handleClientConnected(client);

    assert.equal(client.sent[0]?.type, "session_list");
    assert.equal(client.sent[1]?.type, "slash_catalog");
    assert.equal(client.sent[1]?.adapter, "codex");
    assert.equal(client.sent[1]?.adapterVersion, "0.116.0");
  });
});

test("Bridge returns disabled reasons for slash_action requests that are not implemented", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new FakeAdapter();
    bridgeAny.adapterVersion = "0.116.0";

    const client = createClient("client");
    connectClient(bridgeAny, client);

    await bridgeAny.handleMessage(client, {
      type: "slash_action",
      commandId: "review",
      sessionId: "session-1",
    });

    const result = client.sent[client.sent.length - 1];
    assert.equal(result?.type, "slash_action_result");
    assert.equal(result?.commandId, "review");
    assert.equal(result?.ok, false);
    assert.match(String(result?.message ?? ""), /not implemented/i);
  });
});

test("Bridge passes reasoning effort through when starting a new session from config", async () => {
  await withBridgeHarness(async ({ bridgeAny, workDir }) => {
    const adapter = new FakeAdapter();
    bridgeAny.adapter = adapter;

    const client = createClient("client");
    connectClient(bridgeAny, client);

    await bridgeAny.handleCommand(client, "start with config", undefined, {
      model: "gpt-5.4",
      modelReasoningEffort: "xhigh",
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
    });

    assert.equal(adapter.startSessionCalls, 1);
    assert.deepEqual(adapter.lastStartOptions, {
      workDir,
      model: "gpt-5.4",
      modelReasoningEffort: "xhigh",
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
    });
  });
});

test("Bridge passes updated session config through on follow-up commands for an existing session", async () => {
  await withBridgeHarness(async ({ bridgeAny, workDir }) => {
    const adapter = new FakeAdapter();
    bridgeAny.adapter = adapter;

    const client = createClient("client");
    connectClient(bridgeAny, client);

    await bridgeAny.handleCommand(client, "first command");
    await bridgeAny.handleCommand(client, "follow-up with new permissions", "real-session", {
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
    });

    assert.equal(adapter.startSessionCalls, 1, "should keep the existing session");
    assert.equal(adapter.lastExecuteSessionId, "real-session");
    assert.deepEqual(adapter.lastExecuteOptions, {
      workDir,
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
    });
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

test("Bridge fans out cancel events to reconnected clients following the session", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new SingleSessionAdapter("session-cancel");

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    await bridgeAny.handleCommand(originalClient, "event 1");

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    await bridgeAny.handleMessage(reconnectClient, {
      type: "sync_session",
      sessionId: "session-cancel",
      afterEventId: 0,
    });
    await bridgeAny.handleMessage(originalClient, {
      type: "cancel",
      sessionId: "session-cancel",
    });

    assert.deepEqual(eventIds(reconnectClient), [1, 2]);
    assert.deepEqual(statusMessages(reconnectClient), ["event-1", "Cancelled"]);
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

test("Bridge clamps sync completion latestEventId when the client cursor is ahead of history", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new SingleSessionAdapter("session-stale-cursor");

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    await bridgeAny.handleCommand(originalClient, "event 1");
    await bridgeAny.handleCommand(originalClient, "event 2", "session-stale-cursor");

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    await bridgeAny.handleMessage(reconnectClient, {
      type: "sync_session",
      sessionId: "session-stale-cursor",
      afterEventId: 99,
    });

    assert.deepEqual(eventIds(reconnectClient), []);

    const syncComplete = lastSessionSyncComplete(reconnectClient);
    assert.equal(syncComplete.sessionId, "session-stale-cursor");
    assert.equal(syncComplete.latestEventId, 2);
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

test("Bridge arms replay queueing before awaited canonical resolution can delay sync", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new SingleSessionAdapter("session-gap");

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    await bridgeAny.handleCommand(originalClient, "event 1");
    await bridgeAny.handleCommand(originalClient, "event 2", "session-gap");
    await bridgeAny.handleCommand(originalClient, "event 3", "session-gap");

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    const store = bridgeAny.sessionEventStore;
    const originalResolveSessionId = store.resolveSessionId.bind(store);
    const resolveStarted = createDeferred<void>();
    const resolveRelease = createDeferred<void>();
    let resolveCallCount = 0;

    store.resolveSessionId = async (sessionId: string) => {
      resolveCallCount += 1;
      if (resolveCallCount === 1) {
        resolveStarted.resolve();
        await resolveRelease.promise;
      }
      return originalResolveSessionId(sessionId);
    };

    try {
      const syncPromise = bridgeAny.handleMessage(reconnectClient, {
        type: "sync_session",
        sessionId: "session-gap",
        afterEventId: 0,
      });

      await resolveStarted.promise;
      await bridgeAny.handleCommand(originalClient, "event 4", "session-gap");

      assert.deepEqual(
        eventIds(reconnectClient),
        [],
        "reconnecting client should queue live events even while canonical sync resolution is pending",
      );

      resolveRelease.resolve();
      await syncPromise;
    } finally {
      store.resolveSessionId = originalResolveSessionId;
    }

    assert.deepEqual(eventIds(reconnectClient), [1, 2, 3, 4]);
    assert.deepEqual(statusMessages(reconnectClient), [
      "event-1",
      "event-2",
      "event-3",
      "event-4",
    ]);
  });
});

test("Bridge queues canonical live events while store-only alias resolution is still pending", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    bridgeAny.adapter = new SingleSessionAdapter("real-session-store-only");

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    await bridgeAny.handleCommand(originalClient, "event 1");
    await bridgeAny.sessionEventStore.remapSessionAlias(
      "temp-session-store-only",
      "real-session-store-only",
    );

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    const store = bridgeAny.sessionEventStore;
    const originalResolveSessionId = store.resolveSessionId.bind(store);
    const resolveStarted = createDeferred<void>();
    const resolveRelease = createDeferred<void>();
    let delayedResolveCount = 0;

    store.resolveSessionId = async (sessionId: string) => {
      if (sessionId === "temp-session-store-only" && delayedResolveCount === 0) {
        delayedResolveCount += 1;
        resolveStarted.resolve();
        await resolveRelease.promise;
      }
      return originalResolveSessionId(sessionId);
    };

    try {
      const syncPromise = bridgeAny.handleMessage(reconnectClient, {
        type: "sync_session",
        sessionId: "temp-session-store-only",
        afterEventId: 0,
      });

      await resolveStarted.promise;
      await bridgeAny.handleCommand(originalClient, "event 2", "real-session-store-only");

      assert.deepEqual(
        eventIds(reconnectClient),
        [],
        "reconnecting client should queue canonical live events until store-backed alias resolution finishes",
      );

      resolveRelease.resolve();
      await syncPromise;
    } finally {
      store.resolveSessionId = originalResolveSessionId;
    }

    assert.deepEqual(eventIds(reconnectClient), [1, 2]);
    assert.deepEqual(statusMessages(reconnectClient), ["event-1", "event-2"]);

    const syncComplete = lastSessionSyncComplete(reconnectClient);
    assert.equal(syncComplete.sessionId, "real-session-store-only");
    assert.equal(syncComplete.resolvedSessionId, "real-session-store-only");
    assert.equal(syncComplete.latestEventId, 2);
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

test("Bridge keeps late temp-to-real remaps replay-safe during sync_session", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const adapter = new LateRemapStreamingAdapter("temp-session-late", "real-session-late");
    bridgeAny.adapter = adapter;

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    const commandPromise = bridgeAny.handleCommand(originalClient, "streaming command");
    await adapter.waitUntilExecuting();
    adapter.emit({
      type: "status",
      state: "thinking",
      message: "before late remap",
    });
    await waitFor(
      () => eventIds(originalClient).length === 1,
      "original client should receive the pre-remap live event",
    );

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    const store = bridgeAny.sessionEventStore;
    const originalReadEventsAfter = store.readEventsAfter.bind(store);
    const replayStarted = createDeferred<void>();
    const replayRelease = createDeferred<void>();

    store.readEventsAfter = async (sessionId: string, afterEventId: number) => {
      replayStarted.resolve();
      await replayRelease.promise;
      return originalReadEventsAfter(sessionId, afterEventId);
    };

    try {
      const syncPromise = bridgeAny.handleMessage(reconnectClient, {
        type: "sync_session",
        sessionId: "temp-session-late",
        afterEventId: 0,
      });

      await replayStarted.promise;
      adapter.remapAndEmit({
        type: "status",
        state: "thinking",
        message: "late remap event",
      });

      await waitFor(
        () => eventIds(originalClient).length === 2,
        "original client should receive the remapped live event",
      );

      assert.deepEqual(
        eventIds(reconnectClient),
        [],
        "reconnecting client should queue remapped live events until replay finishes",
      );

      replayRelease.resolve();
      await syncPromise;

      assert.deepEqual(eventIds(reconnectClient), [1, 2]);
      assert.deepEqual(statusMessages(reconnectClient), [
        "before late remap",
        "late remap event",
      ]);
      assert.deepEqual(
        eventMessages(reconnectClient).map((message) => message.sessionId),
        ["real-session-late", "real-session-late"],
      );

      const syncComplete = lastSessionSyncComplete(reconnectClient);
      assert.equal(syncComplete.sessionId, "real-session-late");
      assert.equal(syncComplete.resolvedSessionId, "real-session-late");
      assert.equal(syncComplete.latestEventId, 2);
    } finally {
      store.readEventsAfter = originalReadEventsAfter;
      adapter.finish();
      await commandPromise;
    }
  });
});

test("Bridge flushes late-remap events queued during final sync completion bookkeeping", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const adapter = new LateRemapStreamingAdapter("temp-session-final", "real-session-final");
    bridgeAny.adapter = adapter;

    const originalClient = createClient("client-original");
    connectClient(bridgeAny, originalClient);

    const commandPromise = bridgeAny.handleCommand(originalClient, "streaming command");
    await adapter.waitUntilExecuting();
    adapter.emit({
      type: "status",
      state: "thinking",
      message: "before final completion window",
    });
    await waitFor(
      () => eventIds(originalClient).length === 1,
      "original client should receive the pre-remap event",
    );

    const reconnectClient = createClient("client-reconnect");
    connectClient(bridgeAny, reconnectClient);

    const store = bridgeAny.sessionEventStore;
    const originalReadEventsAfter = store.readEventsAfter.bind(store);
    const originalLoadSessionIndex = store.loadSessionIndex.bind(store);
    const replayStarted = createDeferred<void>();
    const replayRelease = createDeferred<void>();
    const finalIndexStarted = createDeferred<void>();
    const finalIndexRelease = createDeferred<void>();

    store.readEventsAfter = async (sessionId: string, afterEventId: number) => {
      replayStarted.resolve();
      await replayRelease.promise;
      return originalReadEventsAfter(sessionId, afterEventId);
    };

    store.loadSessionIndex = async (sessionId: string) => {
      if (sessionId === "real-session-final") {
        finalIndexStarted.resolve();
        await finalIndexRelease.promise;
      }
      return originalLoadSessionIndex(sessionId);
    };

    try {
      const syncPromise = bridgeAny.handleMessage(reconnectClient, {
        type: "sync_session",
        sessionId: "temp-session-final",
        afterEventId: 0,
      });

      await replayStarted.promise;
      adapter.remapAndEmit({
        type: "status",
        state: "thinking",
        message: "late remap event",
      });
      await waitFor(
        () => eventIds(originalClient).length === 2,
        "original client should receive the remapped event",
      );

      replayRelease.resolve();
      await finalIndexStarted.promise;

      adapter.emit({
        type: "status",
        state: "thinking",
        message: "final completion window event",
      });
      await waitFor(
        () => eventIds(originalClient).length === 3,
        "original client should receive the final-window event",
      );

      assert.deepEqual(
        eventIds(reconnectClient),
        [1, 2],
        "reconnecting client should queue the final-window event until sync completes",
      );

      finalIndexRelease.resolve();
      await syncPromise;
    } finally {
      store.readEventsAfter = originalReadEventsAfter;
      store.loadSessionIndex = originalLoadSessionIndex;
      adapter.finish();
      await commandPromise;
    }

    assert.deepEqual(eventIds(reconnectClient), [1, 2, 3]);
    assert.deepEqual(statusMessages(reconnectClient), [
      "before final completion window",
      "late remap event",
      "final completion window event",
    ]);

    const syncComplete = lastSessionSyncComplete(reconnectClient);
    assert.equal(syncComplete.sessionId, "real-session-final");
    assert.equal(syncComplete.resolvedSessionId, "real-session-final");
    assert.equal(syncComplete.latestEventId, 3);
  });
});

test("Bridge delays remap session_list broadcast until the remap event has been persisted", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const broadcastMessages: RecordedMessage[] = [];
    bridgeAny.transport = {
      broadcast: (message?: unknown) => {
        if (typeof message === "object" && message !== null) {
          broadcastMessages.push(message as RecordedMessage);
        }
      },
    };
    bridgeAny.adapter = new RemapDuringExecuteAdapter();

    const client = createClient("client");
    connectClient(bridgeAny, client);

    const store = bridgeAny.sessionEventStore;
    const originalAppendEvent = store.appendEvent.bind(store);
    const appendStarted = createDeferred<void>();
    const appendRelease = createDeferred<void>();
    let appendCallCount = 0;

    store.appendEvent = async (input) => {
      appendCallCount += 1;
      if (appendCallCount === 1) {
        appendStarted.resolve();
        await appendRelease.promise;
      }
      return originalAppendEvent(input);
    };

    try {
      const commandPromise = bridgeAny.handleCommand(client, "command with remap");

      await appendStarted.promise;
      await waitFor(
        () => broadcastMessages.length >= 1,
        "expected initial session_list broadcast for the new session",
      );

      await new Promise((resolve) => setTimeout(resolve, 20));
      assert.equal(
        broadcastMessages.length,
        1,
        "remap session_list broadcast should wait until the remap event append finishes",
      );

      appendRelease.resolve();
      await commandPromise;
    } finally {
      store.appendEvent = originalAppendEvent;
    }

    assert.equal(broadcastMessages.length, 2);
    const remapBroadcast = broadcastMessages[1];
    assert.equal(remapBroadcast?.type, "session_list");
    assert.deepEqual(
      (remapBroadcast?.sessions as Array<{ id: string }>).map((session) => session.id),
      ["real-session-remap"],
    );
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

test("Bridge delete_session cancels busy sessions before removing them", async () => {
  const broadcasts: Array<{ type: string; sessions: SessionInfo[] }> = [];

  const bridge = new Bridge({
    agent: "codex",
    port: 0,
    workDir: process.cwd(),
  });

  const bridgeAny = bridge as unknown as {
    transport: { broadcast: (message: { type: string; sessions: SessionInfo[] }) => void };
    adapter: AgentAdapter;
    handleMessage: (client: { id: string; send: (...args: any[]) => void }, message: { type: "delete_session"; sessionId: string }) => Promise<void>;
    sessions: Map<string, SessionInfo>;
  };

  bridgeAny.transport = {
    broadcast: (message) => {
      broadcasts.push(message);
    },
  };
  const adapter = new FakeAdapter();
  bridgeAny.adapter = adapter;

  const busySession: SessionInfo = {
    id: "session-1",
    agentType: "codex",
    workDir: process.cwd(),
    state: "thinking",
    createdAt: Date.now(),
    lastActiveAt: Date.now(),
  };
  adapter.sessionMap.set(busySession.id, busySession);
  bridgeAny.sessions.set(busySession.id, busySession);

  const clientMessages: Array<{ type: string; message?: string }> = [];
  const client = {
    id: "client",
    send: (message: { type: string; message?: string }) => {
      clientMessages.push(message);
    },
  };

  await bridgeAny.handleMessage(client, {
    type: "delete_session",
    sessionId: busySession.id,
  });

  assert.deepEqual(adapter.cancelCalls, [busySession.id]);
  assert.deepEqual(adapter.deleteCalls, [busySession.id]);
  assert.equal(bridgeAny.sessions.has(busySession.id), false);
  assert.deepEqual(broadcasts, [{ type: "session_list", sessions: [] }]);
  assert.deepEqual(clientMessages, []);
});

test("Bridge routes diff_req to diff_content for the requesting client", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const client = createClient("client-diff");
    connectClient(bridgeAny, client);

    let recordedRequest: RecordedMessage | null = null;
    bridgeAny.diffService = {
      loadDiff: async (sessionId, eventId) => {
        recordedRequest = { sessionId, eventId };
        return {
          type: "diff_content",
          sessionId,
          eventId,
          files: [
            {
              path: "Sources/App.swift",
              kind: "update",
              isTruncated: false,
              totalHunkCount: 1,
              loadedHunks: [],
            },
          ],
        };
      },
      loadMoreHunks: async () => {
        throw new Error("not used");
      },
    };

    await bridgeAny.handleMessage(client, {
      type: "diff_req",
      sessionId: "session-1",
      eventId: 42,
    });

    assert.deepEqual(recordedRequest, { sessionId: "session-1", eventId: 42 });
    assert.deepEqual(client.sent[0], {
      type: "diff_content",
      sessionId: "session-1",
      eventId: 42,
      files: [
        {
          path: "Sources/App.swift",
          kind: "update",
          isTruncated: false,
          totalHunkCount: 1,
          loadedHunks: [],
        },
      ],
    });
  });
});

test("Bridge routes diff_hunks_req to diff_hunks_content for the requesting client", async () => {
  await withBridgeHarness(async ({ bridgeAny }) => {
    const client = createClient("client-diff-hunks");
    connectClient(bridgeAny, client);

    let recordedRequest: RecordedMessage | null = null;
    bridgeAny.diffService = {
      loadDiff: async () => {
        throw new Error("not used");
      },
      loadMoreHunks: async (sessionId, eventId, path, afterHunkIndex) => {
        recordedRequest = { sessionId, eventId, path, afterHunkIndex };
        return {
          type: "diff_hunks_content",
          sessionId,
          eventId,
          path,
          hunks: [
            {
              oldStart: 3,
              oldLineCount: 1,
              newStart: 3,
              newLineCount: 2,
              lines: [{ kind: "add", text: "+print(value)" }],
            },
          ],
          nextHunkIndex: undefined,
        };
      },
    };

    await bridgeAny.handleMessage(client, {
      type: "diff_hunks_req",
      sessionId: "session-1",
      eventId: 42,
      path: "Sources/App.swift",
      afterHunkIndex: 1,
    });

    assert.deepEqual(recordedRequest, {
      sessionId: "session-1",
      eventId: 42,
      path: "Sources/App.swift",
      afterHunkIndex: 1,
    });
    assert.deepEqual(client.sent[0], {
      type: "diff_hunks_content",
      sessionId: "session-1",
      eventId: 42,
      path: "Sources/App.swift",
      hunks: [
        {
          oldStart: 3,
          oldLineCount: 1,
          newStart: 3,
          newLineCount: 2,
          lines: [{ kind: "add", text: "+print(value)" }],
        },
      ],
      nextHunkIndex: undefined,
    });
  });
});
