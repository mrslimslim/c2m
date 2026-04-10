import test from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { mkdtemp, rm, writeFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { startTunnel } from "../utils/tunnel.js";

test("startTunnel rejects when cloudflared only logs the quick tunnel API endpoint", async () => {
  const root = await mkdtemp(join(tmpdir(), "codepilot-cloudflared-"));
  const fakeCloudflared = join(root, "cloudflared");
  const originalPath = process.env.PATH ?? "";

  try {
    await writeFile(
      fakeCloudflared,
      `#!/bin/sh
echo '[cloudflared] 2026-03-21T07:16:28Z INF Requesting new quick Tunnel on trycloudflare.com...' >&2
echo '[cloudflared] failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": EOF' >&2
exit 1
`,
      "utf8",
    );
    await chmod(fakeCloudflared, 0o755);
    process.env.PATH = `${root}:${originalPath}`;

    await assert.rejects(
      startTunnel(19260),
      /cloudflared exited with code 1 before establishing tunnel/,
    );
  } finally {
    process.env.PATH = originalPath;
    await rm(root, { recursive: true, force: true });
  }
});
