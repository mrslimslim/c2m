import test from "node:test";
import assert from "node:assert/strict";
import { CodexAdapter } from "../adapters/codex.js";

function makeAdapterWithCapturedStartOptions() {
  let receivedOptions: any = null;
  let resumedThreadId: string | null = null;
  let resumedOptions: any = null;

  const adapter = Object.create(CodexAdapter.prototype) as CodexAdapter;

  (adapter as any).codex = {
    startThread: (options: Record<string, unknown>) => {
      receivedOptions = options;
      return {
        runStreamed: () => {
          throw new Error("not used in this test");
        },
      };
    },
    resumeThread: (threadId: string, options: Record<string, unknown>) => {
      resumedThreadId = threadId;
      resumedOptions = options;
      return {
        runStreamed: async () => ({
          events: (async function* () {
            yield { type: "turn.completed", usage: { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0 } };
          })(),
        }),
      };
    },
  };
  (adapter as any).sessions = new Map();

  return {
    adapter,
    getReceivedOptions: () => receivedOptions,
    getResumedThreadId: () => resumedThreadId,
    getResumedOptions: () => resumedOptions,
  };
}

test("CodexAdapter starts threads with gpt-5.4 as the default model", async () => {
  const { adapter, getReceivedOptions } = makeAdapterWithCapturedStartOptions();

  await adapter.startSession({
    workDir: "/tmp/non-git-dir",
  });

  const receivedOptions = getReceivedOptions();
  assert.ok(receivedOptions, "startThread should receive thread options");
  assert.equal(receivedOptions.model, "gpt-5.4");
});

test("CodexAdapter preserves an explicit model override", async () => {
  const { adapter, getReceivedOptions } = makeAdapterWithCapturedStartOptions();

  await adapter.startSession({
    workDir: "/tmp/non-git-dir",
    model: "gpt-5.2",
  });

  const receivedOptions = getReceivedOptions();
  assert.ok(receivedOptions, "startThread should receive thread options");
  assert.equal(receivedOptions.model, "gpt-5.2");
});

test("CodexAdapter preserves an explicit reasoning effort override", async () => {
  const { adapter, getReceivedOptions } = makeAdapterWithCapturedStartOptions();

  await adapter.startSession({
    workDir: "/tmp/non-git-dir",
    modelReasoningEffort: "xhigh",
  });

  const receivedOptions = getReceivedOptions();
  assert.ok(receivedOptions, "startThread should receive thread options");
  assert.equal(receivedOptions.modelReasoningEffort, "xhigh");
});

test("CodexAdapter starts threads with skipGitRepoCheck enabled", async () => {
  const { adapter, getReceivedOptions } = makeAdapterWithCapturedStartOptions();

  await adapter.startSession({
    workDir: "/tmp/non-git-dir",
  });

  const receivedOptions = getReceivedOptions();
  assert.ok(receivedOptions, "startThread should receive thread options");
  assert.equal(receivedOptions.workingDirectory, "/tmp/non-git-dir");
  assert.equal(receivedOptions.skipGitRepoCheck, true);
});

test("CodexAdapter rebinds an existing thread with updated session options before executing", async () => {
  const {
    adapter,
    getResumedThreadId,
    getResumedOptions,
  } = makeAdapterWithCapturedStartOptions();

  (adapter as any).sessions.set("session-1", {
    info: {
      id: "session-1",
      agentType: "codex",
      workDir: "/tmp/non-git-dir",
      state: "idle",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    },
    thread: {
      runStreamed: async () => {
        throw new Error("old thread should be replaced before execute");
      },
    },
    abortController: new AbortController(),
    options: {
      workDir: "/tmp/non-git-dir",
      model: "gpt-5.4",
      modelReasoningEffort: "medium",
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
    },
  });

  await adapter.execute(
    "session-1",
    "apply new permissions",
    () => {},
    {
      workDir: "/tmp/non-git-dir",
      model: "gpt-5.2",
      modelReasoningEffort: "high",
    },
  );

  assert.equal(getResumedThreadId(), "session-1");
  assert.deepEqual(getResumedOptions(), {
    model: "gpt-5.2",
    workingDirectory: "/tmp/non-git-dir",
    skipGitRepoCheck: true,
    modelReasoningEffort: "high",
    sandboxMode: "workspace-write",
    approvalPolicy: "on-request",
  });
});

test("CodexAdapter uses CLI bypass mode for true Full Access permissions", () => {
  const { adapter } = makeAdapterWithCapturedStartOptions();

  (adapter as any).codex = {
    startThread: () => {
      throw new Error("SDK thread should not be used for Full Access");
    },
    resumeThread: () => {
      throw new Error("SDK thread should not be used for Full Access");
    },
  };

  const thread = (adapter as any).createThread({
    workDir: "/tmp/non-git-dir",
    model: "gpt-5.4",
    modelReasoningEffort: "medium",
    approvalPolicy: "never",
    sandboxMode: "danger-full-access",
  }, "session-1");

  assert.equal(typeof thread.runStreamed, "function");
  assert.equal(
    (adapter as any).shouldBypassApprovalsAndSandbox({
      workDir: "/tmp/non-git-dir",
      model: "gpt-5.4",
      modelReasoningEffort: "medium",
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
    }),
    true,
  );
});
