import test from "node:test";
import assert from "node:assert/strict";
import { CodexAdapter } from "../adapters/codex.js";

function makeAdapterWithCapturedStartOptions() {
  let receivedOptions: any = null;

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
  };
  (adapter as any).sessions = new Map();

  return { adapter, getReceivedOptions: () => receivedOptions };
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
