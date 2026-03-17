/**
 * Channel — Durable Object that manages a relay channel between bridge and phone.
 *
 * Each channel holds at most two WebSocket connections (bridge + phone).
 * Messages are forwarded as-is (encrypted ciphertext — relay never decrypts).
 * Offline messages are cached (max 100, 24h expiry).
 */

interface CachedMessage {
  data: string;
  timestamp: number;
}

interface Env {
  CHANNEL: DurableObjectNamespace;
}

const MAX_CACHED_MESSAGES = 100;
const MESSAGE_EXPIRY_MS = 24 * 60 * 60 * 1000; // 24 hours

type DeviceRole = "bridge" | "phone";

export class Channel implements DurableObject {
  private state: DurableObjectState;
  private sockets: Map<DeviceRole, WebSocket> = new Map();
  private messageCache: Map<DeviceRole, CachedMessage[]> = new Map();

  constructor(state: DurableObjectState, _env: Env) {
    this.state = state;

    // Restore cached messages from storage
    this.state.blockConcurrencyWhile(async () => {
      const stored = await this.state.storage.get<Map<DeviceRole, CachedMessage[]>>("cache");
      if (stored) {
        this.messageCache = stored;
      }
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    // WebSocket upgrade
    const upgradeHeader = request.headers.get("Upgrade");
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }

    const device = url.searchParams.get("device") as DeviceRole | null;
    if (device !== "bridge" && device !== "phone") {
      return new Response("Invalid device parameter. Must be 'bridge' or 'phone'.", {
        status: 400,
      });
    }

    // Check if this role is already connected
    const existingSocket = this.sockets.get(device);
    if (existingSocket) {
      try {
        existingSocket.close(1000, "Replaced by new connection");
      } catch {
        // Already closed
      }
      this.sockets.delete(device);
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];

    // Accept the server-side socket using Hibernation API
    this.state.acceptWebSocket(server, [device]);
    this.sockets.set(device, server);

    // Send cached messages for this device
    const otherDevice: DeviceRole = device === "bridge" ? "phone" : "bridge";
    const cached = this.messageCache.get(device) ?? [];
    const now = Date.now();
    const validCached = cached.filter((m) => now - m.timestamp < MESSAGE_EXPIRY_MS);

    for (const msg of validCached) {
      server.send(msg.data);
    }

    // Clear delivered cache
    if (validCached.length > 0) {
      this.messageCache.set(device, []);
      await this.state.storage.put("cache", this.messageCache);
    }

    // Notify the other side that this device connected
    const otherSocket = this.sockets.get(otherDevice);
    if (otherSocket) {
      try {
        otherSocket.send(
          JSON.stringify({ type: "relay_peer_connected", device }),
        );
      } catch {
        // Other socket may be dead
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: ArrayBuffer | string): Promise<void> {
    // Determine which device sent this message
    const tags = this.state.getTags(ws);
    const senderDevice = tags[0] as DeviceRole;
    const targetDevice: DeviceRole = senderDevice === "bridge" ? "phone" : "bridge";

    const data = typeof message === "string" ? message : new TextDecoder().decode(message);

    // Try to forward to the other side
    const targetSocket = this.sockets.get(targetDevice);
    if (targetSocket) {
      try {
        targetSocket.send(data);
        return;
      } catch {
        // Target socket is dead, cache instead
        this.sockets.delete(targetDevice);
      }
    }

    // Target not connected — cache the message
    const cached = this.messageCache.get(targetDevice) ?? [];
    cached.push({ data, timestamp: Date.now() });

    // Enforce max cache size
    while (cached.length > MAX_CACHED_MESSAGES) {
      cached.shift();
    }

    this.messageCache.set(targetDevice, cached);
    await this.state.storage.put("cache", this.messageCache);
  }

  async webSocketClose(
    ws: WebSocket,
    code: number,
    _reason: string,
    _wasClean: boolean,
  ): Promise<void> {
    const tags = this.state.getTags(ws);
    const device = tags[0] as DeviceRole;
    this.sockets.delete(device);

    // Notify the other side
    const otherDevice: DeviceRole = device === "bridge" ? "phone" : "bridge";
    const otherSocket = this.sockets.get(otherDevice);
    if (otherSocket) {
      try {
        otherSocket.send(
          JSON.stringify({ type: "relay_peer_disconnected", device }),
        );
      } catch {
        // Other socket may be dead
      }
    }
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    const tags = this.state.getTags(ws);
    const device = tags[0] as DeviceRole;
    this.sockets.delete(device);
  }
}
