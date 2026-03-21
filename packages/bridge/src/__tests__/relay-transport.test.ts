import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { join } from "node:path";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import type { PhoneMessage } from "@codepilot/protocol";
import {
  decrypt,
  deriveSessionKey,
  encrypt,
  generateKeyPair,
} from "../pairing/crypto.js";
import { RelayTransport } from "../transport/relay.js";
import { loadOrCreatePairingMaterial } from "../pairing/state.js";

class FakeWebSocket extends EventEmitter {
  static CONNECTING: 0 = 0;
  static OPEN: 1 = 1;
  static CLOSING: 2 = 2;
  static CLOSED: 3 = 3;
  static instances: FakeWebSocket[] = [];

  readyState: 1 = FakeWebSocket.OPEN;
  url: string;
  sent: string[] = [];

  constructor(address: string | URL, _protocols?: string | string[] | null, _options?: unknown) {
    super();
    this.url = address.toString();
    FakeWebSocket.instances.push(this);
  }

  send(payload: string): void {
    this.sent.push(payload);
  }

  close(code?: number, reason?: string): void {
    this.emit("close", code ?? 1000, reason ?? "closed");
  }
}

const waitForInstance = async (): Promise<FakeWebSocket> => {
  while (FakeWebSocket.instances.length === 0) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  return FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
};

test("stop() prevents relay reconnect scheduling", async () => {
  FakeWebSocket.instances.length = 0;
  const transport = new RelayTransport("wss://relay", {
    WebSocketCtor: FakeWebSocket,
  });

  const startPromise = transport.start();
  const ws = await waitForInstance();
  ws.emit("open");
  await startPromise;

  transport.stop();
  ws.emit("close");

  assert.equal((transport as any).reconnectAttempts, 0, "should not schedule reconnect when explicitly stopped");
});

test("relay transport reuses persisted pairing material across restarts", async () => {
  FakeWebSocket.instances.length = 0;
  const root = await mkdtemp(join(tmpdir(), "codepilot-relay-pairing-"));
  const filePath = join(root, "pairing.json");

  try {
    const firstMaterial = await loadOrCreatePairingMaterial({ filePath });
    const firstTransport = new RelayTransport("wss://relay", {
      WebSocketCtor: FakeWebSocket,
      pairingMaterial: firstMaterial,
    });

    const firstStart = firstTransport.start();
    const firstSocket = await waitForInstance();
    firstSocket.emit("open");
    const first = await firstStart;

    const secondMaterial = await loadOrCreatePairingMaterial({ filePath });
    const secondTransport = new RelayTransport("wss://relay", {
      WebSocketCtor: FakeWebSocket,
      pairingMaterial: secondMaterial,
    });

    const secondStart = secondTransport.start();
    const secondSocket = await waitForInstance();
    secondSocket.emit("open");
    const second = await secondStart;

    assert.equal(second.pairingData.bridge_pubkey, first.pairingData.bridge_pubkey);
    assert.equal(second.pairingData.otp, first.pairingData.otp);
    assert.equal(second.pairingData.channel, first.pairingData.channel);

    firstTransport.stop();
    secondTransport.stop();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("relay handshake enables encrypted messaging and authenticated lifecycle", async () => {
  FakeWebSocket.instances.length = 0;
  const transport = new RelayTransport("wss://relay", {
    WebSocketCtor: FakeWebSocket,
  });

  const received: PhoneMessage[] = [];
  let connected = 0;
  let disconnected = 0;
  transport.onConnect(() => {
    connected += 1;
  });
  transport.onDisconnect(() => {
    disconnected += 1;
  });
  transport.onMessage((_client, message) => {
    received.push(message);
  });

  const startPromise = transport.start();
  const ws = await waitForInstance();
  ws.emit("open");
  const { pairingData } = await startPromise;

  ws.emit("message", JSON.stringify({ type: "relay_peer_connected", device: "phone" }));
  assert.equal(connected, 0, "relay peer presence alone should not authenticate the phone");

  const phone = generateKeyPair();
  const session = deriveSessionKey(
    phone.privateKey,
    String(pairingData.bridge_pubkey),
    String(pairingData.otp),
  );

  ws.emit("message", JSON.stringify({
    type: "handshake",
    phone_pubkey: phone.publicKeyBase64,
    otp: pairingData.otp,
  }));

  const handshake = JSON.parse(ws.sent.at(-1) ?? "{}");
  assert.equal(handshake.type, "handshake_ok");
  assert.equal(connected, 1);

  ws.sent.length = 0;
  ws.emit("message", JSON.stringify(encrypt(session, JSON.stringify({
    type: "ping",
    ts: 42,
  }))));
  assert.equal(received.length, 1);
  assert.equal(received[0]?.type, "ping");

  transport.broadcast({ type: "pong", latencyMs: 7 });
  assert.equal(ws.sent.length, 1);
  const outbound = JSON.parse(ws.sent[0] ?? "{}");
  const decrypted = JSON.parse(decrypt(session, outbound));
  assert.deepEqual(decrypted, { type: "pong", latencyMs: 7 });

  ws.emit("message", JSON.stringify({ type: "relay_peer_disconnected", device: "phone" }));
  assert.equal(disconnected, 1);
});

test("relay rejects plaintext messages after an encrypted handshake", async () => {
  FakeWebSocket.instances.length = 0;
  const transport = new RelayTransport("wss://relay", {
    WebSocketCtor: FakeWebSocket,
  });

  const received: PhoneMessage[] = [];
  transport.onMessage((_client, message) => {
    received.push(message);
  });

  const startPromise = transport.start();
  const ws = await waitForInstance();
  ws.emit("open");
  const { pairingData } = await startPromise;

  const phone = generateKeyPair();
  const session = deriveSessionKey(
    phone.privateKey,
    String(pairingData.bridge_pubkey),
    String(pairingData.otp),
  );

  ws.emit("message", JSON.stringify({
    type: "handshake",
    phone_pubkey: phone.publicKeyBase64,
    otp: pairingData.otp,
  }));

  ws.sent.length = 0;
  ws.emit("message", JSON.stringify({ type: "ping", ts: 99 }));

  assert.equal(received.length, 0);
  assert.equal(ws.sent.length, 1);
  const errorWire = JSON.parse(ws.sent[0] ?? "{}");
  const error = JSON.parse(decrypt(session, errorWire));
  assert.equal(error.type, "error");
  assert.match(String(error.message ?? ""), /encrypted/i);
});
