/**
 * E2E Encryption module — X25519 key exchange + AES-256-GCM.
 *
 * Uses Node.js built-in `crypto` module (no external dependencies).
 *
 * Flow:
 * 1. Bridge generates X25519 keypair, puts public key in QR code
 * 2. Phone generates its own X25519 keypair
 * 3. Phone sends phone_pubkey + OTP in handshake message
 * 4. Both sides compute shared_secret via ECDH
 * 5. session_key = HKDF(shared_secret, salt=OTP)
 * 6. All subsequent messages encrypted with AES-256-GCM
 */

import {
  generateKeyPairSync,
  diffieHellman,
  hkdfSync,
  createCipheriv,
  createDecipheriv,
  randomBytes,
  createPublicKey,
  createPrivateKey,
  type KeyObject,
} from "node:crypto";

// ─── Types ────────────────────────────────────────────────────────────

export interface E2EKeyPair {
  publicKey: KeyObject;
  privateKey: KeyObject;
  publicKeyBase64: string;
}

export interface E2ESession {
  sessionKey: Buffer;
}

export interface EncryptedMessage {
  v: 1;
  nonce: string;   // 12 bytes, base64
  ciphertext: string; // base64
  tag: string;     // 16 bytes, base64 (GCM auth tag)
}

// ─── Key Generation ───────────────────────────────────────────────────

/**
 * Generate an X25519 keypair for ECDH key exchange.
 */
export function generateKeyPair(): E2EKeyPair {
  const { publicKey, privateKey } = generateKeyPairSync("x25519");

  // Export public key as raw 32 bytes for sharing
  const pubRaw = publicKey.export({ type: "spki", format: "der" });
  // X25519 SPKI DER has a 12-byte header; raw key is the last 32 bytes
  const pubKeyBytes = pubRaw.subarray(pubRaw.length - 32);
  const publicKeyBase64 = pubKeyBytes.toString("base64");

  return { publicKey, privateKey, publicKeyBase64 };
}

// ─── Key Derivation ───────────────────────────────────────────────────

/**
 * Given our private key and the remote party's public key (base64 raw),
 * derive a session key using ECDH + HKDF.
 */
export function deriveSessionKey(
  myPrivateKey: KeyObject,
  theirPublicKeyBase64: string,
  otp: string,
): E2ESession {
  // Reconstruct their public key from raw 32-byte base64
  const theirRawBytes = Buffer.from(theirPublicKeyBase64, "base64");
  if (theirRawBytes.length !== 32) {
    throw new Error("Invalid public key length");
  }

  // Wrap raw X25519 public key bytes in SPKI DER format
  // X25519 SPKI DER prefix (12 bytes) + 32 bytes raw key = 44 bytes
  const spkiPrefix = Buffer.from("302a300506032b656e032100", "hex");
  const spkiDer = Buffer.concat([spkiPrefix, theirRawBytes]);

  const theirPublicKey = createPublicKey({
    key: spkiDer,
    format: "der",
    type: "spki",
  });

  // ECDH shared secret
  const sharedSecret = diffieHellman({
    publicKey: theirPublicKey,
    privateKey: myPrivateKey,
  });

  // Derive 32-byte session key using HKDF
  const salt = Buffer.from(otp, "utf-8");
  const info = Buffer.from("codepilot-e2e-v1", "utf-8");
  const sessionKey = Buffer.from(
    hkdfSync("sha256", sharedSecret, salt, info, 32),
  );

  return { sessionKey };
}

/**
 * Derive session key from raw private key bytes (for browser/relay compatibility).
 */
export function deriveSessionKeyFromRaw(
  myPrivateKeyBase64: string,
  theirPublicKeyBase64: string,
  otp: string,
): E2ESession {
  const myRawBytes = Buffer.from(myPrivateKeyBase64, "base64");

  // Wrap in PKCS8 DER format for X25519
  // PKCS8 prefix for X25519 (16 bytes) + 32 bytes raw key
  const pkcs8Prefix = Buffer.from("302e020100300506032b656e04220420", "hex");
  const pkcs8Der = Buffer.concat([pkcs8Prefix, myRawBytes]);

  const myPrivateKey = createPrivateKey({
    key: pkcs8Der,
    format: "der",
    type: "pkcs8",
  });

  return deriveSessionKey(myPrivateKey, theirPublicKeyBase64, otp);
}

// ─── Encryption / Decryption ──────────────────────────────────────────

/**
 * Encrypt a plaintext string using AES-256-GCM.
 */
export function encrypt(session: E2ESession, plaintext: string): EncryptedMessage {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", session.sessionKey, nonce);

  const encrypted = Buffer.concat([
    cipher.update(plaintext, "utf-8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();

  return {
    v: 1,
    nonce: nonce.toString("base64"),
    ciphertext: encrypted.toString("base64"),
    tag: tag.toString("base64"),
  };
}

/**
 * Decrypt an EncryptedMessage using AES-256-GCM.
 */
export function decrypt(session: E2ESession, msg: EncryptedMessage): string {
  if (msg.v !== 1) {
    throw new Error(`Unsupported encryption version: ${msg.v}`);
  }

  const nonce = Buffer.from(msg.nonce, "base64");
  const ciphertext = Buffer.from(msg.ciphertext, "base64");
  const tag = Buffer.from(msg.tag, "base64");

  const decipher = createDecipheriv("aes-256-gcm", session.sessionKey, nonce);
  decipher.setAuthTag(tag);

  const decrypted = Buffer.concat([
    decipher.update(ciphertext),
    decipher.final(),
  ]);

  return decrypted.toString("utf-8");
}
