/**
 * Security tests for file-path safety mechanisms in Bridge.
 *
 * Covers:
 * 1. SENSITIVE_PATTERNS regex matching (positive & negative)
 * 2. Path traversal detection (.. segments)
 * 3. resolve + startsWith sandbox logic
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { resolve as resolvePath } from "node:path";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SENSITIVE_PATTERNS } from "../bridge.js";
import { Bridge } from "../bridge.js";

// ---------------------------------------------------------------------------
// Helper: returns true if any SENSITIVE_PATTERN matches the given relative path
// ---------------------------------------------------------------------------
function isSensitive(relativePath: string): boolean {
  return SENSITIVE_PATTERNS.some((p) => p.test(relativePath));
}

// ---------------------------------------------------------------------------
// Helper: sandbox check (mirrors handleFileRequest logic)
// ---------------------------------------------------------------------------
function isInsideSandbox(workDir: string, filePath: string): boolean {
  const absolutePath = resolvePath(workDir, filePath);
  const workDirAbs = resolvePath(workDir);
  return (
    absolutePath.startsWith(workDirAbs + "/") || absolutePath === workDirAbs
  );
}

function containsTraversal(filePath: string): boolean {
  return filePath.includes("..");
}

// ===========================================================================
// 1. SENSITIVE_PATTERNS — positive matches (should be blocked)
// ===========================================================================
describe("SENSITIVE_PATTERNS — positive matches", () => {
  const shouldMatch = [
    ".env",
    ".env.local",
    ".env.production",
    ".env.development.local",
    ".git/config",
    ".git/credentials",
    ".ssh/id_rsa",
    ".ssh/id_ed25519",
    ".ssh/known_hosts",
    ".npmrc",
    "credentials.json",
    "src/credentials.json",
    "secrets.json",
    "secrets.yaml",
    "secrets.yml",
    "secrets.toml",
    "secret.json",
    "secret.yaml",
    "secret.yml",
    "server.pem",
    "certs/server.pem",
    "private.key",
    "ssl/private.key",
  ];

  for (const p of shouldMatch) {
    it(`should block: ${p}`, () => {
      assert.ok(isSensitive(p), `Expected "${p}" to match a sensitive pattern`);
    });
  }
});

// ===========================================================================
// 2. SENSITIVE_PATTERNS — negative matches (should NOT be blocked)
// ===========================================================================
describe("SENSITIVE_PATTERNS — negative matches", () => {
  const shouldNotMatch = [
    "src/index.ts",
    "package.json",
    "README.md",
    "tsconfig.json",
    "src/utils/logger.ts",
    "dist/index.js",
    ".github/workflows/ci.yml",
    "src/env.ts",
    "docs/setup.md",
    "lib/main.css",
  ];

  for (const p of shouldNotMatch) {
    it(`should allow: ${p}`, () => {
      assert.ok(
        !isSensitive(p),
        `Expected "${p}" NOT to match any sensitive pattern`,
      );
    });
  }
});

// ===========================================================================
// 3. Path traversal detection
// ===========================================================================
describe("Path traversal detection", () => {
  const traversals = [
    "../../etc/passwd",
    "../secret",
    "foo/../../bar",
    "../.env",
    "subdir/../../../etc/shadow",
  ];

  for (const p of traversals) {
    it(`should detect traversal: ${p}`, () => {
      assert.ok(
        containsTraversal(p),
        `Expected "${p}" to be detected as path traversal`,
      );
    });
  }

  const safe = ["src/index.ts", "a/b/c.ts", "file.txt"];

  for (const p of safe) {
    it(`should not flag safe path: ${p}`, () => {
      assert.ok(
        !containsTraversal(p),
        `Expected "${p}" NOT to be flagged as traversal`,
      );
    });
  }
});

// ===========================================================================
// 4. Sandbox logic — resolve + startsWith
// ===========================================================================
describe("Sandbox: resolve + startsWith", () => {
  const workDir = "/home/user/project";

  it("allows a file inside workDir", () => {
    assert.ok(isInsideSandbox(workDir, "src/index.ts"));
  });

  it("allows the workDir itself", () => {
    assert.ok(isInsideSandbox(workDir, "."));
  });

  it("rejects path that escapes via ..", () => {
    assert.ok(!isInsideSandbox(workDir, "../../etc/passwd"));
  });

  it("rejects absolute path outside workDir", () => {
    assert.ok(!isInsideSandbox(workDir, "/etc/passwd"));
  });

  it("rejects sibling directory escape", () => {
    assert.ok(!isInsideSandbox(workDir, "../sibling/secret.txt"));
  });

  it("rejects workDir prefix trick (e.g. /home/user/project-evil)", () => {
    // This tests that we use workDirAbs + "/" and not just startsWith(workDirAbs)
    const evilPath = "/home/user/project-evil/hack.ts";
    const abs = resolvePath(evilPath);
    const wdAbs = resolvePath(workDir);
    const inside =
      abs.startsWith(wdAbs + "/") || abs === wdAbs;
    assert.ok(!inside, "Should reject paths that merely share a prefix");
  });
});

describe("file request sandbox hardening", () => {
  it("rejects symlink targets that escape the working directory", async () => {
    const root = await mkdtemp(join(tmpdir(), "codepilot-security-"));
    const workDir = join(root, "work");
    const outsideDir = join(root, "outside");
    const outsideFile = join(outsideDir, "secret.txt");
    const linkPath = join(workDir, "linked-outside");

    await mkdir(workDir, { recursive: true });
    await mkdir(outsideDir, { recursive: true });
    await writeFile(outsideFile, "top-secret");
    await symlink(outsideDir, linkPath);

    const bridge = new Bridge({
      agent: "codex",
      port: 19260,
      workDir,
    }) as any;

    const messages: Array<Record<string, unknown>> = [];
    const client = {
      id: "test-client",
      send(message: Record<string, unknown>) {
        messages.push(message);
      },
    };

    try {
      await bridge.handleFileRequest(client, "linked-outside/secret.txt", "session-1");

      assert.equal(messages.length, 1);
      assert.equal(messages[0]?.type, "error");
      assert.match(
        String(messages[0]?.message ?? ""),
        /access denied|outside the working directory/i,
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
