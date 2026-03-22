/**
 * LocalTransport — WebSocket server for LAN connections.
 *
 * Listens on 0.0.0.0 and accepts connections authenticated with a random token.
 * Supports E2E encryption via handshake protocol.
 */

import { WebSocketServer, WebSocket } from "ws";
import { createServer, type Server as HttpServer } from "node:http";
import { readFileSync } from "node:fs";
import { networkInterfaces } from "node:os";
import { randomBytes } from "node:crypto";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { SESSION_REPLAY_CAPABILITY, type BridgeMessage, type PhoneMessage } from "@codepilot/protocol";
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

const DEFAULT_PORT = 19260;

/** Valid PhoneMessage types */
const VALID_MESSAGE_TYPES = new Set([
  "command",
  "cancel",
  "file_req",
  "delete_session",
  "list_sessions",
  "ping",
  "sync_session",
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
  private httpServer: HttpServer | null = null;
  private clients = new Map<string, ConnectedClient>();
  private token: string;
  private port: number;
  private host: string;
  private advertisedHost?: string;

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
    host: string = "0.0.0.0",
    advertisedHost?: string,
    pairingMaterial?: PairingMaterial,
  ) {
    this.port = port;
    this.host = host;
    this.advertisedHost = this.normalizeAdvertisedHost(advertisedHost);
    this.token = pairingMaterial?.token ?? randomBytes(16).toString("hex");
    this.keyPair = pairingMaterial?.keyPair ?? generateKeyPair();
    this.otp = pairingMaterial?.otp ?? randomBytes(3).toString("hex"); // 6-char hex OTP
  }

  async start(): Promise<{
    url: string;
    httpUrl: string;
    pairingData: Record<string, unknown>;
    listenUrl: string;
  }> {
    return new Promise((resolvePromise, reject) => {
      // Create HTTP server to serve test client
      this.httpServer = createServer((req, res) => {
        if (
          req.url === "/" ||
          req.url === "/test-client.html" ||
          req.url?.startsWith("/?") ||
          req.url?.startsWith("/test-client.html?")
        ) {
          // Serve test-client.html — look for it relative to the package
          try {
            const __dirname = dirname(fileURLToPath(import.meta.url));
            const htmlPath = resolve(__dirname, "../../test-client.html");
            const html = readFileSync(htmlPath, "utf-8");
            res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
            res.end(html);
          } catch {
            res.writeHead(404);
            res.end("test-client.html not found");
          }
        } else if (req.url === "/test-client.js" || req.url?.startsWith("/test-client.js?")) {
          try {
            const __dirname = dirname(fileURLToPath(import.meta.url));
            const jsPath = resolve(__dirname, "../../test-client.js");
            const js = readFileSync(jsPath, "utf-8");
            res.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8" });
            res.end(js);
          } catch {
            res.writeHead(404);
            res.end("test-client.js not found");
          }
        } else {
          res.writeHead(404);
          res.end("Not found");
        }
      });

      // Create WebSocket server attached to HTTP server
      this.wss = new WebSocketServer({ server: this.httpServer });

      this.httpServer.listen(this.port, this.host, () => {
        const isIPv6 = this.host.includes(":");
        const localIp = this.getLocalIp(isIPv6);
        const advertisedHost = this.advertisedHost ?? localIp;
        const hostForUrl = advertisedHost.includes(":") ? `[${advertisedHost}]` : advertisedHost;
        const listenHostForUrl = localIp.includes(":") ? `[${localIp}]` : localIp;
        const url = `ws://${hostForUrl}:${this.port}`;
        const httpUrl = `http://${hostForUrl}:${this.port}`;
        const listenUrl = `ws://${listenHostForUrl}:${this.port}`;
        const pairingData = {
          host: advertisedHost,
          port: this.port,
          token: this.token,
          bridge_pubkey: this.keyPair.publicKeyBase64,
          otp: this.otp,
          protocol: "codepilot-v1-e2e",
        };
        resolvePromise({ url, httpUrl, pairingData, listenUrl });
      });

      this.httpServer.on("error", reject);

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
                    capabilities: [SESSION_REPLAY_CAPABILITY],
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
      this.wss.close();
      this.wss = null;
    }
    if (this.httpServer) {
      return new Promise((resolve) => {
        this.httpServer!.close(() => resolve());
        this.httpServer = null;
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

  private getLocalIp(preferIPv6: boolean = false): string {
    const interfaces = networkInterfaces();
    // If preferring IPv6, look for global unicast address first
    if (preferIPv6) {
      for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name] ?? []) {
          if (
            iface.family === "IPv6" &&
            !iface.internal &&
            !iface.address.startsWith("fe80")  // skip link-local
          ) {
            return iface.address;
          }
        }
      }
    }
    // Fallback to IPv4
    for (const name of Object.keys(interfaces)) {
      for (const iface of interfaces[name] ?? []) {
        if (iface.family === "IPv4" && !iface.internal) {
          return iface.address;
        }
      }
    }
    return preferIPv6 ? "::1" : "127.0.0.1";
  }

  private normalizeAdvertisedHost(host?: string): string | undefined {
    const trimmed = host?.trim();
    if (!trimmed) {
      return undefined;
    }

    return trimmed.replace(/^\[(.*)\]$/, "$1");
  }
}
