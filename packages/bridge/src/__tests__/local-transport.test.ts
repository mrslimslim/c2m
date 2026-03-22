import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:net";
import { join } from "node:path";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import WebSocket from "ws";
import { SESSION_REPLAY_CAPABILITY, type PhoneMessage } from "@codepilot/protocol";
import { LocalTransport } from "../transport/local.js";
import {
  deriveSessionKey,
  encrypt,
  generateKeyPair,
} from "../pairing/crypto.js";
import { loadOrCreatePairingMaterial } from "../pairing/state.js";

async function getAvailablePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("failed to allocate port"));
        return;
      }
      const { port } = address;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
    server.on("error", reject);
  });
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

describe("LocalTransport E2E sessions", () => {
  it("reuses persisted pairing material across transport restarts", async () => {
    const root = await mkdtemp(join(tmpdir(), "codepilot-local-pairing-"));
    const filePath = join(root, "pairing.json");
    const firstPort = await getAvailablePort();
    const secondPort = await getAvailablePort();

    try {
      const firstMaterial = await loadOrCreatePairingMaterial({ filePath });
      const firstTransport = new LocalTransport(firstPort, "127.0.0.1", undefined, firstMaterial);
      const first = await firstTransport.start();
      await firstTransport.stop();

      const secondMaterial = await loadOrCreatePairingMaterial({ filePath });
      const secondTransport = new LocalTransport(secondPort, "127.0.0.1", undefined, secondMaterial);
      const second = await secondTransport.start();
      await secondTransport.stop();

      assert.equal(second.pairingData.bridge_pubkey, first.pairingData.bridge_pubkey);
      assert.equal(second.pairingData.otp, first.pairingData.otp);
      assert.equal(second.pairingData.token, first.pairingData.token);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("uses the advertised host in pairing output without changing the listen port", async () => {
    const port = await getAvailablePort();
    const transport = new LocalTransport(port, "127.0.0.1", "codepilot.tailnet.ts.net");

    try {
      const { url, httpUrl, pairingData } = await transport.start();

      assert.equal(url, `ws://codepilot.tailnet.ts.net:${port}`);
      assert.equal(httpUrl, `http://codepilot.tailnet.ts.net:${port}`);
      assert.equal(pairingData.host, "codepilot.tailnet.ts.net");
      assert.equal(pairingData.port, port);
    } finally {
      await transport.stop();
    }
  });

  it("rejects plaintext messages after an encrypted handshake", async () => {
    const port = await getAvailablePort();
    const transport = new LocalTransport(port);
    const received: PhoneMessage[] = [];

    transport.onMessage((_client, message) => {
      received.push(message);
    });

    const { pairingData } = await transport.start();
    const ws = new WebSocket(`ws://127.0.0.1:${String(pairingData.port)}`);
    const phone = generateKeyPair();
    const session = deriveSessionKey(
      phone.privateKey,
      String(pairingData.bridge_pubkey),
      String(pairingData.otp),
    );

    try {
      await once(ws, "open");

      ws.send(JSON.stringify({
        type: "handshake",
        phone_pubkey: phone.publicKeyBase64,
        otp: pairingData.otp,
      }));

      const [handshakeRaw] = await once(ws, "message");
      const handshake = JSON.parse(handshakeRaw.toString());
      assert.equal(handshake.type, "handshake_ok");
      assert.deepEqual(handshake.capabilities, [SESSION_REPLAY_CAPABILITY]);

      ws.send(JSON.stringify({ type: "ping", ts: Date.now() }));
      await delay(75);
      assert.equal(received.length, 0);

      ws.send(JSON.stringify(encrypt(session, JSON.stringify({
        type: "ping",
        ts: Date.now(),
      }))));

      await delay(75);
      assert.equal(received.length, 1);
      assert.equal(received[0]?.type, "ping");
    } finally {
      ws.close();
      await transport.stop();
    }
  });
});
