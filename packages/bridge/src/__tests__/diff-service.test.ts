import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { SessionEventLogStore } from "../session-store/event-log.js";
import { DiffService } from "../diff/service.js";

test("DiffService returns first hunk initially and paginates subsequent hunks", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));
  const store = new SessionEventLogStore({ workDir, homeDir });

  try {
    await store.appendEvent({
      sessionId: "session-1",
      timestamp: 1000,
      event: {
        type: "code_change",
        changes: [{ path: "Sources/App.swift", kind: "update" }],
      },
    });

    let loadCount = 0;
    const service = new DiffService({
      workDir,
      eventStore: store,
      hunkPageSize: 1,
      loadDiffText: async () => {
        loadCount += 1;
        return [
          "diff --git a/Sources/App.swift b/Sources/App.swift",
          "index 1111111..2222222 100644",
          "--- a/Sources/App.swift",
          "+++ b/Sources/App.swift",
          "@@ -1,2 +1,3 @@",
          " import Foundation",
          "-let value = 1",
          "+let value = 2",
          "+let label = \"ok\"",
          "@@ -10,1 +11,2 @@",
          " func run() {}",
          "+print(value)",
        ].join("\n");
      },
    });

    const initial = await service.loadDiff("session-1", 1);
    assert.equal(loadCount, 1);
    assert.equal(initial.files.length, 1);
    assert.equal(initial.files[0]?.loadedHunks.length, 1);
    assert.equal(initial.files[0]?.totalHunkCount, 2);
    assert.equal(initial.files[0]?.nextHunkIndex, 1);

    const next = await service.loadMoreHunks("session-1", 1, "Sources/App.swift", 1);
    assert.equal(loadCount, 1);
    assert.equal(next.hunks.length, 1);
    assert.equal(next.nextHunkIndex, undefined);
    assert.equal(next.hunks[0]?.lines[1]?.text, "+print(value)");
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});

test("DiffService rejects non-code-change events", async () => {
  const homeDir = await mkdtemp(join(tmpdir(), "codepilot-home-"));
  const workDir = await mkdtemp(join(tmpdir(), "codepilot-work-"));
  const store = new SessionEventLogStore({ workDir, homeDir });

  try {
    await store.appendEvent({
      sessionId: "session-1",
      timestamp: 1000,
      event: {
        type: "status",
        state: "thinking",
        message: "working",
      },
    });

    const service = new DiffService({
      workDir,
      eventStore: store,
      loadDiffText: async () => "",
    });

    await assert.rejects(
      service.loadDiff("session-1", 1),
      /not a code_change event/,
    );
  } finally {
    await rm(homeDir, { recursive: true, force: true });
    await rm(workDir, { recursive: true, force: true });
  }
});
