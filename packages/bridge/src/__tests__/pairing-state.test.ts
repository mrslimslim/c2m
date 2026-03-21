import test from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { loadOrCreatePairingMaterial } from "../pairing/state.js";

test("loadOrCreatePairingMaterial persists stable pairing material to disk", async () => {
  const root = await mkdtemp(join(tmpdir(), "codepilot-pairing-"));
  const filePath = join(root, "pairing.json");

  try {
    const first = await loadOrCreatePairingMaterial({ filePath });
    const second = await loadOrCreatePairingMaterial({ filePath });
    const persisted = JSON.parse(await readFile(filePath, "utf-8")) as Record<string, unknown>;

    assert.equal(second.keyPair.publicKeyBase64, first.keyPair.publicKeyBase64);
    assert.equal(second.otp, first.otp);
    assert.equal(second.token, first.token);

    assert.equal(persisted.version, 1);
    assert.equal(persisted.otp, first.otp);
    assert.equal(persisted.token, first.token);
    assert.equal(typeof persisted.privateKeyBase64, "string");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
