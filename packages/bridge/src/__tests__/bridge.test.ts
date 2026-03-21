import { test } from "node:test";
import assert from "node:assert/strict";
import type { AgentEvent, SessionInfo } from "@codepilot/protocol";
import type { AgentAdapter, SessionOptions } from "../adapters/types.js";
import { Bridge } from "../bridge.js";

class FakeAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  startSessionCalls = 0;
  executeCalls = 0;
  cancelCalls: string[] = [];
  deleteCalls: string[] = [];
  sessionMap = new Map<string, SessionInfo>();
  lastExecuteSessionId: string | null = null;

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
    this.cancelCalls.push(sessionId);
  }

  deleteSession(sessionId: string): void {
    this.deleteCalls.push(sessionId);
    this.sessionMap.delete(sessionId);
  }

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
