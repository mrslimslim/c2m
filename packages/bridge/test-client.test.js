import test from "node:test";
import assert from "node:assert/strict";
import {
  buildSocketUrl,
  canInitiateConnection,
  resolveInitialConfig,
  validateConnectionInput,
} from "./test-client.js";

test("buildSocketUrl creates a LAN websocket URL", () => {
  assert.equal(
    buildSocketUrl({
      mode: "lan",
      host: "127.0.0.1",
      port: "19260",
    }),
    "ws://127.0.0.1:19260",
  );
});

test("buildSocketUrl creates a relay websocket URL", () => {
  assert.equal(
    buildSocketUrl({
      mode: "relay",
      relay: "wss://relay.example.com/",
      channel: "abc123",
    }),
    "wss://relay.example.com/ws?device=phone&channel=abc123",
  );
});

test("canInitiateConnection blocks duplicate connects while a socket is still active", () => {
  assert.equal(canInitiateConnection(null), true);
  assert.equal(canInitiateConnection({ readyState: 0 }), false);
  assert.equal(canInitiateConnection({ readyState: 1 }), false);
  assert.equal(canInitiateConnection({ readyState: 2 }), true);
  assert.equal(canInitiateConnection({ readyState: 3 }), true);
});

test("validateConnectionInput allows LAN E2E without a token", () => {
  assert.equal(
    validateConnectionInput({
      mode: "lan",
      host: "127.0.0.1",
      port: "19260",
      token: "",
      bridgePubkey: "pubkey",
      pairingOtp: "otp",
    }),
    null,
  );
});

test("validateConnectionInput requires relay pairing data in relay mode", () => {
  assert.match(
    String(validateConnectionInput({
      mode: "relay",
      relay: "wss://relay.example.com",
      channel: "abc123",
      bridgePubkey: "",
      pairingOtp: "",
    }) ?? ""),
    /pairing/i,
  );
});

test("resolveInitialConfig detects relay mode from URL params", () => {
  const config = resolveInitialConfig(
    new URLSearchParams(
      "relay=wss%3A%2F%2Frelay.example.com&channel=abc123&bridge_pubkey=pub&otp=otp",
    ),
    {
      hostname: "127.0.0.1",
      port: "19260",
    },
  );

  assert.equal(config.mode, "relay");
  assert.equal(config.relay, "wss://relay.example.com");
  assert.equal(config.channel, "abc123");
  assert.equal(config.shouldAutoConnect, true);
});
