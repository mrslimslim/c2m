import { test } from "node:test";
import assert from "node:assert/strict";
import type { AgentEvent, SessionInfo } from "@codepilot/protocol";
import type { AgentAdapter, SessionOptions } from "../adapters/types.js";
import { Bridge } from "../bridge.js";

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

test("Bridge keeps the new Codex thread ID and reuses it for follow-up commands", async () => {
  const transport = {
    broadcast: () => {},
  } as const;

  const bridge = new Bridge({
    agent: "codex",
    port: 0,
    workDir: process.cwd(),
  });

  const bridgeAny = bridge as unknown as {
    transport: { broadcast: () => void };
    adapter: AgentAdapter;
    handleCommand: (client: { id: string; send: (...args: any[]) => void }, text: string, sessionId?: string) => Promise<void>;
    sessions: Map<string, SessionInfo>;
  };

  bridgeAny.transport = transport;
  const adapter = new FakeAdapter();
  bridgeAny.adapter = adapter;

  const client = { id: "client", send: () => {} };

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

test("Bridge emits eventId values that are monotonic within each session", async () => {
  const bridge = new Bridge({
    agent: "codex",
    port: 0,
    workDir: process.cwd(),
  });

  const bridgeAny = bridge as unknown as {
    transport: { broadcast: () => void };
    adapter: AgentAdapter;
    handleCommand: (client: { id: string; send: (message: unknown) => void }, text: string, sessionId?: string) => Promise<void>;
  };

  bridgeAny.transport = { broadcast: () => {} };
  const adapter = new MultiSessionAdapter();
  bridgeAny.adapter = adapter;

  const sent: Array<Record<string, unknown>> = [];
  const client = {
    id: "client",
    send: (message: unknown) => {
      if (typeof message === "object" && message !== null) {
        sent.push(message as Record<string, unknown>);
      }
    },
  };

  await bridgeAny.handleCommand(client, "s1 first");
  await bridgeAny.handleCommand(client, "s2 first");
  await bridgeAny.handleCommand(client, "s1 second", "session-1");
  await bridgeAny.handleCommand(client, "s2 second", "session-2");

  const eventMessages = sent.filter((message) => message.type === "event");
  assert.equal(eventMessages.length, 4);

  const bySession = new Map<string, number[]>();
  for (const message of eventMessages) {
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

test("Bridge preserves eventId continuity across temp-to-real session remaps", async () => {
  const bridge = new Bridge({
    agent: "codex",
    port: 0,
    workDir: process.cwd(),
  });

  const bridgeAny = bridge as unknown as {
    transport: { broadcast: () => void };
    adapter: AgentAdapter;
    handleCommand: (client: { id: string; send: (message: unknown) => void }, text: string, sessionId?: string) => Promise<void>;
  };

  bridgeAny.transport = { broadcast: () => {} };
  bridgeAny.adapter = new RemapDuringExecuteAdapter();

  const sent: Array<Record<string, unknown>> = [];
  const client = {
    id: "client",
    send: (message: unknown) => {
      if (typeof message === "object" && message !== null) {
        sent.push(message as Record<string, unknown>);
      }
    },
  };

  await bridgeAny.handleCommand(client, "command with remap");
  await bridgeAny.handleCommand(client, "follow-up after remap", "real-session-remap");

  const eventMessages = sent.filter((message) => message.type === "event");
  const eventIds = eventMessages.map((message) => message.eventId);
  assert.deepEqual(eventIds, [1, 2, 3, 4]);
});

test("Bridge resolves temp session aliases for follow-up command and cancel", async () => {
  const bridge = new Bridge({
    agent: "codex",
    port: 0,
    workDir: process.cwd(),
  });

  const bridgeAny = bridge as unknown as {
    transport: { broadcast: () => void };
    adapter: AgentAdapter;
    handleCommand: (client: { id: string; send: (message: unknown) => void }, text: string, sessionId?: string) => Promise<void>;
    handleMessage: (
      client: { id: string; send: (message: unknown) => void },
      message: { type: "cancel"; sessionId: string }
    ) => Promise<void>;
  };

  bridgeAny.transport = { broadcast: () => {} };
  const adapter = new FakeAdapter();
  bridgeAny.adapter = adapter;

  const sent: Array<Record<string, unknown>> = [];
  const client = {
    id: "client",
    send: (message: unknown) => {
      if (typeof message === "object" && message !== null) {
        sent.push(message as Record<string, unknown>);
      }
    },
  };

  await bridgeAny.handleCommand(client, "first command");
  await bridgeAny.handleCommand(client, "follow-up command still using temp id", "temp-session");

  assert.equal(adapter.startSessionCalls, 1);
  assert.equal(adapter.executeCalls, 2);
  assert.equal(adapter.lastExecuteSessionId, "real-session");

  const eventMessages = sent.filter((message) => message.type === "event");
  const eventIds = eventMessages.map((message) => message.eventId);
  assert.deepEqual(eventIds, [1, 2]);

  await bridgeAny.handleMessage(client, { type: "cancel", sessionId: "temp-session" });
  assert.deepEqual(adapter.canceledSessionIds, ["real-session"]);

  const cancelEvent = sent[sent.length - 1];
  assert.equal(cancelEvent.type, "event");
  assert.equal(cancelEvent.sessionId, "real-session");
  assert.equal(cancelEvent.eventId, 3);
});
