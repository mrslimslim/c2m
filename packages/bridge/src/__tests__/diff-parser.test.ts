import test from "node:test";
import assert from "node:assert/strict";
import { parseUnifiedDiff } from "../diff/parser.js";

test("parseUnifiedDiff normalizes a multi-hunk single-file diff", () => {
  const diffText = [
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

  const files = parseUnifiedDiff(diffText, [
    { path: "Sources/App.swift", kind: "update" },
  ]);

  assert.equal(files.length, 1);
  assert.equal(files[0]?.path, "Sources/App.swift");
  assert.equal(files[0]?.kind, "update");
  assert.equal(files[0]?.addedLines, 3);
  assert.equal(files[0]?.deletedLines, 1);
  assert.equal(files[0]?.hunks.length, 2);
  assert.deepEqual(
    files[0]?.hunks[0]?.lines.map((line) => line.kind),
    ["context", "delete", "add", "add"],
  );
});

test("parseUnifiedDiff preserves /dev/null additions as add file changes", () => {
  const diffText = [
    "diff --git a/NewFile.swift b/NewFile.swift",
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/NewFile.swift",
    "@@ -0,0 +1,2 @@",
    "+struct NewFile {}",
    "+",
  ].join("\n");

  const files = parseUnifiedDiff(diffText, [
    { path: "NewFile.swift", kind: "add" },
  ]);

  assert.equal(files.length, 1);
  assert.equal(files[0]?.path, "NewFile.swift");
  assert.equal(files[0]?.kind, "add");
  assert.equal(files[0]?.addedLines, 2);
  assert.equal(files[0]?.deletedLines, 0);
});
