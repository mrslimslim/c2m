import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const cliPath = fileURLToPath(new URL("../bin/codepilot.js", import.meta.url));

function runCli(args: string[]) {
  return spawnSync(process.execPath, [cliPath, ...args], {
    encoding: "utf8",
  });
}

test("codepilot help only exposes tunnel-first startup options", () => {
  const result = runCli(["--help"]);
  assert.equal(result.status, 0);

  const output = `${result.stdout}${result.stderr}`;
  assert.match(output, /Cloudflare Tunnel/i);
  assert.match(output, /--tunnel/);
  assert.match(output, /default/i);
  assert.doesNotMatch(output, /--relay(\s|$)/);
  assert.doesNotMatch(output, /--relay-url/);
  assert.doesNotMatch(output, /-p,\s+--port/);
  assert.doesNotMatch(output, /-H,\s+--host/);
  assert.doesNotMatch(output, /--advertised-host/);
});

test("codepilot rejects the removed relay option", () => {
  const result = runCli(["--relay", "--dir", "/tmp"]);

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unknown option '--relay'/i);
});

test("codepilot still accepts the tunnel compatibility flag", () => {
  const result = runCli(["--tunnel", "--version"]);

  assert.equal(result.status, 0);
  assert.match(result.stdout, /0\.1\.0/);
});
