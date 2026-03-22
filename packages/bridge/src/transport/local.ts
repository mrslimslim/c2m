/**
 * LocalTransport — local WebSocket server used behind the tunnel.
 *
 * Listens on a local interface and accepts connections authenticated with a
 * random token or E2E handshake.
 */

import { WebSocketServer, WebSocket } from "ws";
import { randomBytes } from "node:crypto";
import {
  SESSION_REPLAY_CAPABILITY,
  SLASH_CATALOG_CAPABILITY,
  type BridgeMessage,
  type PhoneMessage,
} from "@codepilot/protocol";
import type { TransportClient, TransportServer } from "./types.js";
import {
  generateKeyPair,
  deriveSessionKey,
  encrypt,
  decrypt,
  type E2ESession,
} from "../pairing/crypto.js";
import type { PairingMaterial } from "../pairing/state.js";
import { log } from "../utils/logger.js";

const DEFAULT_PORT = 0;

/** Valid PhoneMessage types */
const VALID_MESSAGE_TYPES = new Set([
  "command",
  "cancel",
  "file_req",
  "delete_session",
  "list_sessions",
  "ping",
  "sync_session",
  "diff_req",
  "diff_hunks_req",
  "slash_action",
]);

/**
 * Runtime validation of incoming phone messages.
 * Returns a valid PhoneMessage or null if invalid.
 */
export function validatePhoneMessage(data: unknown): PhoneMessage | null {
  if (typeof data !== "object" || data === null) return null;

  const msg = data as Record<string, unknown>;
  const type = msg.type;
  if (typeof type !== "string" || !VALID_MESSAGE_TYPES.has(type)) return null;

  switch (type) {
    case "command":
      if (typeof msg.text !== "string" || msg.text.length === 0) return null;
      if (msg.sessionId !== undefined && typeof msg.sessionId !== "string") return null;
      return msg as unknown as PhoneMessage;

    case "cancel":
      if (typeof msg.sessionId !== "string") return null;
      return msg as unknown as PhoneMessage;

    case "file_req":
      if (typeof msg.path !== "string" || typeof msg.sessionId !== "string") return null;
      return msg as unknown as PhoneMessage;

    case "delete_session":
      if (typeof msg.sessionId !== "string") return null;
      return msg as unknown as PhoneMessage;

    case "list_sessions":
      return msg as unknown as PhoneMessage;

    case "ping":
      if (typeof msg.ts !== "number") return null;
      return msg as unknown as PhoneMessage;

    case "sync_session":
      if (typeof msg.sessionId !== "string") return null;
      if (typeof msg.afterEventId !== "number") return null;
      return msg as unknown as PhoneMessage;

    case "diff_req":
      if (typeof msg.sessionId !== "string") return null;
      if (typeof msg.eventId !== "number") return null;
      return msg as unknown as PhoneMessage;

    case "diff_hunks_req":
      if (typeof msg.sessionId !== "string") return null;
      if (typeof msg.eventId !== "number") return null;
      if (typeof msg.path !== "string") return null;
      if (typeof msg.afterHunkIndex !== "number") return null;
      return msg as unknown as PhoneMessage;

    case "slash_action":
      if (typeof msg.commandId !== "string" || msg.commandId.length === 0) return null;
      if (msg.sessionId !== undefined && typeof msg.sessionId !== "string") return null;
      if (
        msg.arguments !== undefined &&
        (typeof msg.arguments !== "object" || msg.arguments === null || Array.isArray(msg.arguments))
      ) {
        return null;
      }
      return msg as unknown as PhoneMessage;

    default:
      return null;
  }
}

interface ConnectedClient {
  id: string;
  ws: WebSocket;
  authenticated: boolean;
  e2e: E2ESession | null;
}

export class LocalTransport implements TransportServer {
  private wss: WebSocketServer | null = null;
  private clients = new Map<string, ConnectedClient>();
  private token: string;
  private port: number;
  private host: string;

  // E2E encryption keypair
  private keyPair: ReturnType<typeof generateKeyPair>;
  private otp: string;

  private messageHandlers: Array<
    (client: TransportClient, message: PhoneMessage) => void
  > = [];
  private connectHandlers: Array<(client: TransportClient) => void> = [];
  private disconnectHandlers: Array<(client: TransportClient) => void> = [];

  constructor(
    port: number = DEFAULT_PORT,
    host: string = "127.0.0.1",
    pairingMaterial?: PairingMaterial,
  ) {
    this.port = port;
    this.host = this.normalizeHost(host);
    this.token = pairingMaterial?.token ?? randomBytes(16).toString("hex");
    this.keyPair = pairingMaterial?.keyPair ?? generateKeyPair();
    this.otp = pairingMaterial?.otp ?? randomBytes(3).toString("hex"); // 6-char hex OTP
  }

  async start(): Promise<{
    url: string;
    pairingData: Record<string, unknown>;
    listenUrl: string;
  }> {
    return new Promise((resolvePromise, reject) => {
      let startupSettled = false;
      const rejectStartup = (error: Error) => {
        const normalizedError = this.normalizeStartupError(error);
        if (startupSettled) {
          return;
        }
        startupSettled = true;
        this.wss?.off("error", rejectStartup);
        reject(normalizedError);
      };

      this.wss = new WebSocketServer({ host: this.host, port: this.port });
      this.wss.once("error", rejectStartup);
      this.wss.once("listening", () => {
        const address = this.wss?.address();
        if (!address || typeof address === "string") {
          rejectStartup(new Error("Failed to resolve the local bridge address"));
          return;
        }

        this.port = address.port;
        startupSettled = true;
        this.wss?.off("error", rejectStartup);
        this.wss?.on("error", (error) => {
          log.error(`WebSocket server error: ${error.message}`);
        });
        const pairingHost = this.resolvePairingHost();
        const hostForUrl = pairingHost.includes(":") ? `[${pairingHost}]` : pairingHost;
        const url = `ws://${hostForUrl}:${this.port}`;
        const pairingData = {
          host: pairingHost,
          port: this.port,
          token: this.token,
          bridge_pubkey: this.keyPair.publicKeyBase64,
          otp: this.otp,
          protocol: "codepilot-v1-e2e",
        };
        resolvePromise({ url, pairingData, listenUrl: url });
      });

      this.wss.on("connection", (ws) => {
        const clientId = `client-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
        const client: ConnectedClient = { id: clientId, ws, authenticated: false, e2e: null };

        // First message must be auth (legacy) or handshake (E2E)
        ws.on("message", (data) => {
          try {
            const raw = data.toString();

            // If client has E2E session, try to decrypt
            if (client.authenticated && client.e2e) {
              try {
                const encrypted = JSON.parse(raw);
                if (encrypted.v === 1 && encrypted.nonce && encrypted.ciphertext && encrypted.tag) {
                  const decrypted = decrypt(client.e2e, encrypted);
                  const msg = JSON.parse(decrypted);
                  const phoneMsg = validatePhoneMessage(msg);
                  if (!phoneMsg) {
                    ws.send(this.encryptForClient(client, { type: "error", message: "Invalid message format" }));
                    return;
                  }
                  const tc = this.makeTransportClient(client);
                  for (const handler of this.messageHandlers) {
                    handler(tc, phoneMsg);
                  }
                  return;
                }
              } catch {
                // Invalid encrypted payload
              }

              ws.send(
                this.encryptForClient(client, {
                  type: "error",
                  message: "Encrypted session requires encrypted messages",
                }),
              );
              return;
            }

            const msg = JSON.parse(raw);

            if (!client.authenticated) {
              // E2E handshake: { type: "handshake", phone_pubkey: "...", otp: "..." }
              if (msg.type === "handshake" && typeof msg.phone_pubkey === "string" && typeof msg.otp === "string") {
                if (msg.otp !== this.otp) {
                  ws.send(JSON.stringify({ type: "auth_failed", reason: "invalid_otp" }));
                  ws.close(4001, "OTP verification failed");
                  return;
                }

                // Derive session key
                try {
                  const e2eSession = deriveSessionKey(
                    this.keyPair.privateKey,
                    msg.phone_pubkey,
                    msg.otp,
                  );
                  client.e2e = e2eSession;
                  client.authenticated = true;
                  this.clients.set(clientId, client);

                  // Reply in plaintext (this is the last plaintext message)
                  ws.send(JSON.stringify({
                    type: "handshake_ok",
                    encrypted: true,
                    clientId,
                    capabilities: [SESSION_REPLAY_CAPABILITY, SLASH_CATALOG_CAPABILITY],
                  }));

                  const tc = this.makeTransportClient(client);
                  for (const handler of this.connectHandlers) {
                    handler(tc);
                  }
                  log.connection(`E2E handshake completed for ${clientId}`);
                } catch (err) {
                  log.error(`E2E handshake failed: ${err}`);
                  ws.send(JSON.stringify({ type: "auth_failed", reason: "handshake_error" }));
                  ws.close(4001, "Handshake failed");
                }
                return;
              }

              // Legacy auth: { type: "auth", token: "..." }
              if (msg.type === "auth" && msg.token === this.token) {
                client.authenticated = true;
                this.clients.set(clientId, client);
                ws.send(JSON.stringify({ type: "auth_ok", clientId }));

                const tc = this.makeTransportClient(client);
                for (const handler of this.connectHandlers) {
                  handler(tc);
                }
              } else {
                ws.send(JSON.stringify({ type: "auth_failed" }));
                ws.close(4001, "Authentication failed");
              }
              return;
            }

            // Authenticated plaintext message (non-E2E client)
            const phoneMsg = validatePhoneMessage(msg);
            if (!phoneMsg) {
              ws.send(JSON.stringify({ type: "error", message: "Invalid message format" }));
              return;
            }
            const tc = this.makeTransportClient(client);
            for (const handler of this.messageHandlers) {
              handler(tc, phoneMsg);
            }
          } catch {
            ws.send(
              JSON.stringify({ type: "error", message: "Invalid message format" }),
            );
          }
        });

        ws.on("close", () => {
          if (client.authenticated) {
            this.clients.delete(clientId);
            const tc = this.makeTransportClient(client);
            for (const handler of this.disconnectHandlers) {
              handler(tc);
            }
          }
        });

        ws.on("error", (err) => {
          log.error(`WebSocket error for client ${clientId}: ${err.message}`);
          this.clients.delete(clientId);
          // Trigger disconnect handlers so Bridge can clean up
          if (client.authenticated) {
            const tc = this.makeTransportClient(client);
            for (const handler of this.disconnectHandlers) {
              handler(tc);
            }
          }
        });
      });
    });
  }

  onMessage(handler: (client: TransportClient, message: PhoneMessage) => void): void {
    this.messageHandlers.push(handler);
  }

  onConnect(handler: (client: TransportClient) => void): void {
    this.connectHandlers.push(handler);
  }

  onDisconnect(handler: (client: TransportClient) => void): void {
    this.disconnectHandlers.push(handler);
  }

  broadcast(message: BridgeMessage): void {
    const plainPayload = JSON.stringify(message);
    for (const client of this.clients.values()) {
      if (client.ws.readyState === WebSocket.OPEN) {
        if (client.e2e) {
          const encrypted = encrypt(client.e2e, plainPayload);
          client.ws.send(JSON.stringify(encrypted));
        } else {
          client.ws.send(plainPayload);
        }
      }
    }
  }

  async stop(): Promise<void> {
    for (const client of this.clients.values()) {
      client.ws.close(1000, "Server shutting down");
    }
    this.clients.clear();
    if (this.wss) {
      return new Promise((resolve) => {
        this.wss!.close(() => resolve());
        this.wss = null;
      });
    }
  }

  /** Get the token for pairing (displayed in QR code) */
  getToken(): string {
    return this.token;
  }

  private makeTransportClient(client: ConnectedClient): TransportClient {
    return {
      id: client.id,
      send: (message: BridgeMessage) => {
        if (client.ws.readyState === WebSocket.OPEN) {
          if (client.e2e) {
            const encrypted = encrypt(client.e2e, JSON.stringify(message));
            client.ws.send(JSON.stringify(encrypted));
          } else {
            client.ws.send(JSON.stringify(message));
          }
        }
      },
    };
  }

  /** Encrypt a message for a specific client (helper) */
  private encryptForClient(client: ConnectedClient, message: Record<string, unknown>): string {
    if (client.e2e) {
      return JSON.stringify(encrypt(client.e2e, JSON.stringify(message)));
    }
    return JSON.stringify(message);
  }

  private normalizeStartupError(error: Error): Error {
    if (this.isErrnoException(error) && error.code === "EADDRINUSE") {
      return new Error(
        `Port ${this.port} is already in use on ${this.host}. Stop the other bridge and retry.`,
      );
    }
    return error;
  }

  private resolvePairingHost(): string {
    if (this.host === "0.0.0.0") {
      return "127.0.0.1";
    }
    if (this.host === "::") {
      return "::1";
    }
    return this.host;
  }

  private normalizeHost(host: string): string {
    const trimmed = host.trim();
    if (!trimmed) {
      return "127.0.0.1";
    }

    return trimmed.replace(/^\[(.*)\]$/, "$1");
  }

  private isErrnoException(error: unknown): error is NodeJS.ErrnoException {
    return typeof error === "object" && error !== null && "code" in error;
  }
}
