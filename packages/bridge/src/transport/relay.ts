/**
 * RelayTransport — Bridge-side WebSocket client that connects to the Relay server.
 *
 * Implements the same TransportServer interface as LocalTransport,
 * so Bridge can use either without code changes.
 *
 * Channel ID = first 12 chars of hex(sha256(bridge_pubkey)).
 */

import WebSocket from "ws";
import { createHash, randomBytes } from "node:crypto";
import type { BridgeMessage, PhoneMessage } from "@codepilot/protocol";
import type { TransportClient, TransportServer } from "./types.js";
import {
  decrypt,
  deriveSessionKey,
  encrypt,
  generateKeyPair,
  type E2EKeyPair,
  type E2ESession,
  type EncryptedMessage,
} from "../pairing/crypto.js";
import type { PairingMaterial } from "../pairing/state.js";
import { log } from "../utils/logger.js";
import { validatePhoneMessage } from "./local.js";

const RECONNECT_DELAY_MS = 3000;
const MAX_RECONNECT_ATTEMPTS = 10;

type RelayWebSocket = {
  readyState: number;
  on(event: "open", listener: () => void): void;
  on(event: "message", listener: (data: string) => void): void;
  on(event: "close", listener: (code: number, reason: string) => void): void;
  on(event: "error", listener: (err: Error) => void): void;
  send(payload: string): void;
  close(code?: number, reason?: string): void;
};

type RelayWebSocketCtor = new (...args: any[]) => RelayWebSocket;

interface RelayTransportOptions {
  WebSocketCtor?: RelayWebSocketCtor;
  pairingMaterial?: PairingMaterial;
}

function isEncryptedWireMessage(value: unknown): value is EncryptedMessage {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const candidate = value as Record<string, unknown>;
  return (
    candidate.v === 1 &&
    typeof candidate.nonce === "string" &&
    typeof candidate.ciphertext === "string" &&
    typeof candidate.tag === "string"
  );
}

export class RelayTransport implements TransportServer {
  private relayUrl: string;
  private ws: RelayWebSocket | null = null;
  private channelId: string = "";
  private connected = false;
  private reconnectAttempts = 0;
  private readonly webSocketCtor: RelayWebSocketCtor;
  private stopping = false;
  private otp: string | null = null;
  private e2eSession: E2ESession | null = null;
  private authenticated = false;

  // E2E keypair
  private keyPair: E2EKeyPair;

  private messageHandlers: Array<
    (client: TransportClient, message: PhoneMessage) => void
  > = [];
  private connectHandlers: Array<(client: TransportClient) => void> = [];
  private disconnectHandlers: Array<(client: TransportClient) => void> = [];

  constructor(relayUrl: string, options: RelayTransportOptions = {}) {
    // Normalize URL (remove trailing slash)
    this.relayUrl = relayUrl.replace(/\/$/, "");
    this.webSocketCtor = options.WebSocketCtor ?? (WebSocket as unknown as RelayWebSocketCtor);
    this.keyPair = options.pairingMaterial?.keyPair ?? generateKeyPair();
    this.otp = options.pairingMaterial?.otp ?? null;

    this.channelId = this.deriveChannelId(this.keyPair.publicKeyBase64);
  }

  async start(): Promise<{
    url: string;
    httpUrl: string;
    pairingData: Record<string, unknown>;
    listenUrl: string;
  }> {
    this.stopping = false;
    this.authenticated = false;
    this.e2eSession = null;
    await this.connectToRelay();

    this.otp = this.otp ?? randomBytes(3).toString("hex");
    const pairingData = {
      relay: this.relayUrl,
      channel: this.channelId,
      bridge_pubkey: this.keyPair.publicKeyBase64,
      otp: this.otp,
      protocol: "codepilot-v1-e2e-relay",
    };

    const url = `${this.relayUrl}/ws?device=phone&channel=${this.channelId}`;
    return { url, httpUrl: "", pairingData, listenUrl: url };
  }

  private connectToRelay(): Promise<void> {
    return new Promise((resolve, reject) => {
      const wsUrl = `${this.relayUrl}/ws?device=bridge&channel=${this.channelId}`;
      log.info(`Connecting to relay: ${wsUrl}`);

      this.ws = new this.webSocketCtor(wsUrl);

      this.ws.on("open", () => {
        this.connected = true;
        this.reconnectAttempts = 0;
        log.success(`Connected to relay channel: ${this.channelId}`);
        resolve();
      });

      this.ws.on("message", (data) => {
        try {
          const raw = data.toString();
          const msg = JSON.parse(raw);

          // Relay control messages
          if (msg.type === "relay_peer_connected" && msg.device === "phone") {
            log.connection("Phone connected via relay");
            return;
          }

          if (msg.type === "relay_peer_disconnected" && msg.device === "phone") {
            log.connection("Phone disconnected from relay");
            const wasAuthenticated = this.authenticated;
            this.authenticated = false;
            this.e2eSession = null;

            if (wasAuthenticated) {
              const tc = this.makeTransportClient();
              for (const handler of this.disconnectHandlers) {
                handler(tc);
              }
            }
            return;
          }

          if (this.authenticated && this.e2eSession) {
            if (!isEncryptedWireMessage(msg)) {
              this.sendEncryptedError("Encrypted session requires encrypted messages");
              return;
            }

            const decrypted = decrypt(this.e2eSession, msg);
            const payload = JSON.parse(decrypted);
            const phoneMessage = validatePhoneMessage(payload);
            if (!phoneMessage) {
              this.sendEncryptedError("Invalid message format");
              return;
            }

            const tc = this.makeTransportClient();
            for (const handler of this.messageHandlers) {
              handler(tc, phoneMessage);
            }
            return;
          }

          if (
            msg.type === "handshake" &&
            typeof msg.phone_pubkey === "string" &&
            typeof msg.otp === "string"
          ) {
            if (!this.otp || msg.otp !== this.otp) {
              this.sendPlain({ type: "auth_failed", reason: "invalid_otp" });
              return;
            }

            try {
              this.e2eSession = deriveSessionKey(
                this.keyPair.privateKey,
                msg.phone_pubkey,
                msg.otp,
              );
              this.authenticated = true;

              const tc = this.makeTransportClient();
              this.sendPlain({
                type: "handshake_ok",
                encrypted: true,
                clientId: tc.id,
              });
              for (const handler of this.connectHandlers) {
                handler(tc);
              }
            } catch (error) {
              log.error(`Relay E2E handshake failed: ${String(error)}`);
              this.sendPlain({ type: "auth_failed", reason: "handshake_error" });
            }
            return;
          }

          this.sendPlain({ type: "auth_failed", reason: "handshake_required" });
        } catch (err) {
          if (this.authenticated && this.e2eSession) {
            this.sendEncryptedError("Invalid message format");
            return;
          }
          log.error(`Failed to parse relay message: ${err}`);
          this.sendPlain({ type: "auth_failed", reason: "invalid_message" });
        }
      });

      this.ws.on("close", () => {
        this.connected = false;
        log.warn("Relay connection closed");
        this.scheduleReconnect();
      });

      this.ws.on("error", (err) => {
        log.error(`Relay WebSocket error: ${err.message}`);
        if (!this.connected) {
          reject(err);
        }
      });
    });
  }

  private deriveChannelId(publicKeyBase64: string): string {
    return createHash("sha256")
      .update(publicKeyBase64)
      .digest("hex")
      .slice(0, 12);
  }

  private scheduleReconnect(): void {
      if (this.stopping) {
        return;
      }

      if (this.reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
        log.error("Max relay reconnect attempts reached");
        return;
      }

    this.reconnectAttempts++;
    const delay = RECONNECT_DELAY_MS * Math.min(this.reconnectAttempts, 5);
    log.info(`Reconnecting to relay in ${delay}ms (attempt ${this.reconnectAttempts})...`);

    setTimeout(() => {
      this.connectToRelay().catch((err) => {
        log.error(`Relay reconnection failed: ${err}`);
      });
    }, delay);
  }

  onMessage(
    handler: (client: TransportClient, message: PhoneMessage) => void,
  ): void {
    this.messageHandlers.push(handler);
  }

  onConnect(handler: (client: TransportClient) => void): void {
    this.connectHandlers.push(handler);
  }

  onDisconnect(handler: (client: TransportClient) => void): void {
    this.disconnectHandlers.push(handler);
  }

  broadcast(message: BridgeMessage): void {
    this.sendBridgeMessage(message);
  }

  async stop(): Promise<void> {
    this.stopping = true;
    if (this.ws) {
      this.ws.close(1000, "Bridge shutting down");
      this.ws = null;
    }
    this.connected = false;
  }

  private makeTransportClient(): TransportClient {
    return {
      id: `relay-phone-${this.channelId}`,
      send: (message: BridgeMessage) => {
        this.sendBridgeMessage(message);
      },
    };
  }

  private sendPlain(message: Record<string, unknown>): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message));
    }
  }

  private sendBridgeMessage(message: BridgeMessage): void {
    if (!this.e2eSession) {
      return;
    }

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(encrypt(this.e2eSession, JSON.stringify(message))));
    }
  }

  private sendEncryptedError(message: string): void {
    this.sendBridgeMessage({
      type: "error",
      message,
    });
  }
}
