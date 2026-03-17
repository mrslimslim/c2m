import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  generateKeyPair,
  deriveSessionKey,
  encrypt,
  decrypt,
  type E2EKeyPair,
  type E2ESession,
  type EncryptedMessage,
} from "../pairing/crypto.js";

// ─── generateKeyPair() ──────────────────────────────────────────────

describe("generateKeyPair", () => {
  it("returns publicKey, privateKey, and publicKeyBase64", () => {
    const kp = generateKeyPair();
    assert.ok(kp.publicKey, "publicKey should be present");
    assert.ok(kp.privateKey, "privateKey should be present");
    assert.ok(typeof kp.publicKeyBase64 === "string", "publicKeyBase64 should be a string");
  });

  it("publicKeyBase64 decodes to 32 bytes (raw X25519)", () => {
    const kp = generateKeyPair();
    const raw = Buffer.from(kp.publicKeyBase64, "base64");
    assert.equal(raw.length, 32);
  });

  it("generates unique keypairs each time", () => {
    const a = generateKeyPair();
    const b = generateKeyPair();
    assert.notEqual(a.publicKeyBase64, b.publicKeyBase64);
  });
});

// ─── deriveSessionKey() ─────────────────────────────────────────────

describe("deriveSessionKey", () => {
  const otp = "123456";

  it("both sides derive the same session key (symmetry)", () => {
    const alice = generateKeyPair();
    const bob = generateKeyPair();

    const sessionA = deriveSessionKey(alice.privateKey, bob.publicKeyBase64, otp);
    const sessionB = deriveSessionKey(bob.privateKey, alice.publicKeyBase64, otp);

    assert.ok(sessionA.sessionKey.equals(sessionB.sessionKey), "session keys must match");
  });

  it("session key is 32 bytes (AES-256)", () => {
    const alice = generateKeyPair();
    const bob = generateKeyPair();
    const session = deriveSessionKey(alice.privateKey, bob.publicKeyBase64, otp);
    assert.equal(session.sessionKey.length, 32);
  });

  it("different OTPs yield different session keys", () => {
    const alice = generateKeyPair();
    const bob = generateKeyPair();
    const s1 = deriveSessionKey(alice.privateKey, bob.publicKeyBase64, "111111");
    const s2 = deriveSessionKey(alice.privateKey, bob.publicKeyBase64, "222222");
    assert.ok(!s1.sessionKey.equals(s2.sessionKey), "different OTPs should produce different keys");
  });

  it("throws on invalid public key length (too short)", () => {
    const alice = generateKeyPair();
    const shortKey = Buffer.alloc(16).toString("base64");
    assert.throws(
      () => deriveSessionKey(alice.privateKey, shortKey, otp),
      /Invalid public key length/,
    );
  });

  it("throws on invalid public key length (too long)", () => {
    const alice = generateKeyPair();
    const longKey = Buffer.alloc(64).toString("base64");
    assert.throws(
      () => deriveSessionKey(alice.privateKey, longKey, otp),
      /Invalid public key length/,
    );
  });

  it("throws on empty public key", () => {
    const alice = generateKeyPair();
    assert.throws(
      () => deriveSessionKey(alice.privateKey, "", otp),
      /Invalid public key length/,
    );
  });
});

// ─── encrypt() + decrypt() round-trip ───────────────────────────────

describe("encrypt / decrypt round-trip", () => {
  function makeSession(): E2ESession {
    const a = generateKeyPair();
    const b = generateKeyPair();
    return deriveSessionKey(a.privateKey, b.publicKeyBase64, "otp-test");
  }

  it("round-trips a simple string", () => {
    const session = makeSession();
    const msg = "Hello, world!";
    const enc = encrypt(session, msg);
    const dec = decrypt(session, enc);
    assert.equal(dec, msg);
  });

  it("round-trips an empty string", () => {
    const session = makeSession();
    const enc = encrypt(session, "");
    const dec = decrypt(session, enc);
    assert.equal(dec, "");
  });

  it("round-trips unicode / emoji", () => {
    const session = makeSession();
    const msg = "Bonjour le monde! 🌍🚀";
    const enc = encrypt(session, msg);
    assert.equal(decrypt(session, enc), msg);
  });

  it("round-trips a large payload", () => {
    const session = makeSession();
    const msg = "x".repeat(100_000);
    const enc = encrypt(session, msg);
    assert.equal(decrypt(session, enc), msg);
  });

  it("encrypted message has correct structure", () => {
    const session = makeSession();
    const enc = encrypt(session, "test");
    assert.equal(enc.v, 1);
    assert.equal(typeof enc.nonce, "string");
    assert.equal(typeof enc.ciphertext, "string");
    assert.equal(typeof enc.tag, "string");
    // nonce = 12 bytes base64
    assert.equal(Buffer.from(enc.nonce, "base64").length, 12);
    // tag = 16 bytes base64
    assert.equal(Buffer.from(enc.tag, "base64").length, 16);
  });

  it("produces different ciphertexts for the same plaintext (random nonce)", () => {
    const session = makeSession();
    const enc1 = encrypt(session, "same");
    const enc2 = encrypt(session, "same");
    assert.notEqual(enc1.nonce, enc2.nonce, "nonces should differ");
    assert.notEqual(enc1.ciphertext, enc2.ciphertext, "ciphertexts should differ");
  });
});

// ─── Tamper detection ───────────────────────────────────────────────

describe("tamper detection", () => {
  function makeSession(): E2ESession {
    const a = generateKeyPair();
    const b = generateKeyPair();
    return deriveSessionKey(a.privateKey, b.publicKeyBase64, "otp-tamper");
  }

  it("rejects tampered ciphertext", () => {
    const session = makeSession();
    const enc = encrypt(session, "secret");
    const tampered: EncryptedMessage = {
      ...enc,
      ciphertext: Buffer.from("tampered-data").toString("base64"),
    };
    assert.throws(() => decrypt(session, tampered));
  });

  it("rejects tampered auth tag", () => {
    const session = makeSession();
    const enc = encrypt(session, "secret");
    const tagBuf = Buffer.from(enc.tag, "base64");
    tagBuf[0] ^= 0xff;
    const tampered: EncryptedMessage = { ...enc, tag: tagBuf.toString("base64") };
    assert.throws(() => decrypt(session, tampered));
  });

  it("rejects tampered nonce", () => {
    const session = makeSession();
    const enc = encrypt(session, "secret");
    const nonceBuf = Buffer.from(enc.nonce, "base64");
    nonceBuf[0] ^= 0xff;
    const tampered: EncryptedMessage = { ...enc, nonce: nonceBuf.toString("base64") };
    assert.throws(() => decrypt(session, tampered));
  });

  it("rejects decryption with wrong session key", () => {
    const s1 = makeSession();
    const s2 = makeSession();
    const enc = encrypt(s1, "secret");
    assert.throws(() => decrypt(s2, enc));
  });

  it("rejects unsupported encryption version", () => {
    const session = makeSession();
    const enc = encrypt(session, "test");
    const bad = { ...enc, v: 2 as any };
    assert.throws(() => decrypt(session, bad), /Unsupported encryption version/);
  });
});
