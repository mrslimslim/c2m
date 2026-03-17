import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:net";
import WebSocket from "ws";
import { type PhoneMessage } from "@codepilot/protocol";
import { LocalTransport } from "../transport/local.js";
import {
  deriveSessionKey,
  encrypt,
  generateKeyPair,
} from "../pairing/crypto.js";

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
