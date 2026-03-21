/**
 * Bridge — the main orchestrator that connects adapters to transports.
 *
 * Responsibilities:
 * 1. Manage agent adapters (Codex / Claude)
 * 2. Manage transport (WebSocket)
 * 3. Route messages between phone and agent
 * 4. Display QR code for pairing
 */

import { resolve as resolvePath, relative } from "node:path";
import { readFile, realpath } from "node:fs/promises";
import { extname } from "node:path";
import type { AgentEvent, PhoneMessage, SessionConfig, SessionInfo } from "@codepilot/protocol";
import type { AgentAdapter, SessionOptions } from "./adapters/types.js";
import type { TransportClient, TransportServer } from "./transport/types.js";
import { CodexAdapter } from "./adapters/codex.js";
import { ClaudeAdapter } from "./adapters/claude.js";
import { LocalTransport } from "./transport/local.js";
import { displayQRCode } from "./pairing/qrcode.js";
import { loadOrCreatePairingMaterial } from "./pairing/state.js";
import { log } from "./utils/logger.js";

export interface BridgeOptions {
  agent: "codex" | "claude" | "auto";
  port: number;
  host?: string;
  advertisedHost?: string;
  workDir: string;
  tunnel?: boolean;
  relay?: boolean;
  relayUrl?: string;
}

/** Sensitive file patterns that should never be served */
export const SENSITIVE_PATTERNS = [
  /^\.env($|\.)/,       // .env, .env.local, etc.
  /^\.git\/config$/,
  /^\.git\/credentials$/,
  /^\.ssh\//,
  /^\.npmrc$/,
  /credentials\.json$/,
  /secrets?\.(json|ya?ml|toml)$/,
  /\.pem$/,
  /\.key$/,
];

export class Bridge {
  private adapter: AgentAdapter | null = null;
  private transport: TransportServer;
  private sessions = new Map<string, SessionInfo>();
  private options: BridgeOptions;
  private tunnelStop: (() => void) | null = null;

  constructor(options: BridgeOptions) {
    this.options = options;
    this.transport = null as unknown as TransportServer;
  }

  async start(): Promise<void> {
    const pairingMaterial = await loadOrCreatePairingMaterial({
      workDir: this.options.workDir,
    });
    log.info(`Pairing state: ${pairingMaterial.statePath}`);

    // 0. If relay mode, create RelayTransport
    if (this.options.relay) {
      const { RelayTransport } = await import("./transport/relay.js");
      this.transport = new RelayTransport(
        this.options.relayUrl ?? "wss://relay.codepilot.dev",
        { pairingMaterial },
      );
    } else {
      this.transport = new LocalTransport(
        this.options.port,
        this.options.host ?? "0.0.0.0",
        this.options.advertisedHost,
        pairingMaterial,
      );
    }

    // 1. Resolve adapter
    this.adapter = await this.resolveAdapter();
    log.success(`Agent: ${this.adapter.name}`);

    // 2. Start transport (interface-only, no cast)
    const { url, httpUrl, pairingData, listenUrl } = await this.transport.start();
    log.success(`WebSocket server listening on ${listenUrl ?? url}`);

    // 3. Display QR code
    if (this.options.tunnel) {
      // Launch Cloudflare Tunnel and use tunnel URL in QR code
      log.info("Starting Cloudflare Tunnel...");
      const { startTunnel } = await import("./utils/tunnel.js");
      const tunnel = await startTunnel(this.options.port);
      this.tunnelStop = tunnel.stop;
      log.success(`Tunnel URL: ${tunnel.url}`);

      // Override pairing data with tunnel info
      // Extract just the hostname from the tunnel URL for the host field
      const tunnelHostname = tunnel.url.replace("https://", "");
      const tunnelPairingData = {
        ...pairingData,
        host: tunnelHostname,
        port: 443,
        tunnel: true,         // signal to the phone to use wss://
      };
      log.info("Scan this QR code with your phone to connect:");
      displayQRCode(tunnelPairingData);
      log.info(`Or connect manually: ${tunnel.wsUrl}`);
    } else {
      log.info("Scan this QR code with your phone to connect:");
      displayQRCode(pairingData);
      log.info(`Or connect manually: ${url}`);
      if (pairingData.token) {
        log.info(`Token: ${pairingData.token}`);
      }
      if (httpUrl && pairingData.host) {
        log.info(`Open test client: ${httpUrl}?host=${pairingData.host}&port=${pairingData.port}&token=${pairingData.token ?? ""}&bridge_pubkey=${encodeURIComponent(String(pairingData.bridge_pubkey ?? ""))}&otp=${pairingData.otp ?? ""}`);
      }
    }

    // 4. Wire up event handlers
    this.transport.onConnect((client) => {
      log.connection(`Device connected: ${client.id}`);
      // Send current session list
      client.send({
        type: "session_list",
        sessions: Array.from(this.sessions.values()),
      });
    });

    this.transport.onDisconnect((client) => {
      log.connection(`Device disconnected: ${client.id}`);
    });

    this.transport.onMessage((client, message) => {
      this.handleMessage(client, message).catch((err) => {
        log.error(`Error handling message: ${err}`);
        client.send({ type: "error", message: String(err) });
      });
    });

    // 5. Graceful shutdown
    const shutdown = async () => {
      log.info("Shutting down...");
      this.adapter?.dispose();
      this.tunnelStop?.();
      await this.transport.stop();
      process.exit(0);
    };
    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);

    log.info("Waiting for phone connection...");
  }

  private async handleMessage(
    client: TransportClient,
    message: PhoneMessage,
  ): Promise<void> {
    switch (message.type) {
      case "command":
        await this.handleCommand(client, message.text, message.sessionId, message.config);
        break;

      case "cancel":
        this.adapter?.cancel(message.sessionId);
        client.send({
          type: "event",
          sessionId: message.sessionId,
          event: { type: "status", state: "idle", message: "Cancelled" },
          timestamp: Date.now(),
        });
        break;

      case "delete_session":
        this.handleDeleteSession(client, message.sessionId);
        break;

      case "list_sessions":
        client.send({
          type: "session_list",
          sessions: Array.from(this.sessions.values()),
        });
        break;

      case "ping":
        client.send({
          type: "pong",
          latencyMs: Date.now() - message.ts,
        });
        break;

      case "file_req":
        await this.handleFileRequest(client, message.path, message.sessionId);
        break;
    }
  }

  private async handleCommand(
    client: TransportClient,
    text: string,
    sessionId?: string,
    config?: SessionConfig,
  ): Promise<void> {
    if (!this.adapter) {
      client.send({ type: "error", message: "No agent adapter available" });
      return;
    }

    // Start or find session
    let sid = sessionId;
    if (!sid || !this.sessions.has(sid)) {
      const opts: SessionOptions = {
        workDir: this.options.workDir,
        model: config?.model,
        approvalPolicy: config?.approvalPolicy,
        sandboxMode: config?.sandboxMode,
      };
      const session = await this.adapter.startSession(opts);
      sid = session.id;
      this.sessions.set(sid, session);
      log.info(`New session: ${sid}`);

      // Notify phone of updated session list
      this.transport.broadcast({
        type: "session_list",
        sessions: Array.from(this.sessions.values()),
      });
    }

    log.info(`[${sid.slice(0, 12)}] Execute: ${text.slice(0, 80)}`);

    const onEvent = (event: AgentEvent) => {
      const currentSession = this.sessions.get(sid!);
      if (!currentSession) {
        return;
      }
      if (currentSession && currentSession.id !== sid) {
        const newId = currentSession.id;
        this.sessions.delete(sid!);
        sid = newId;
        this.sessions.set(sid, currentSession);
        this.transport.broadcast({
          type: "session_list",
          sessions: Array.from(this.sessions.values()),
        });
      }

      log.event(sid!, event.type, this.eventSummary(event));

      // Update session state
      const session = this.sessions.get(sid!);
      if (session) {
        if ("state" in event) {
          session.state = event.state;
        } else if (event.type === "turn_completed") {
          session.state = "idle";
        } else if (event.type === "error") {
          session.state = "error";
        }
        session.lastActiveAt = Date.now();
      }

      // Forward to phone
      client.send({
        type: "event",
        sessionId: sid!,
        event,
        timestamp: Date.now(),
      });
    };

    try {
      await this.adapter.execute(sid, text, onEvent);
    } catch (err) {
      if (!this.sessions.has(sid)) {
        return;
      }
      log.error(`Execution error: ${err}`);
      client.send({
        type: "event",
        sessionId: sid,
        event: {
          type: "error",
          message: err instanceof Error ? err.message : String(err),
        },
        timestamp: Date.now(),
      });
    }
  }

  private handleDeleteSession(client: TransportClient, sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) {
      client.send({
        type: "error",
        message: `Session not found: ${sessionId}`,
      });
      return;
    }

    if (session.state !== "idle" && session.state !== "error") {
      this.adapter?.cancel(sessionId);
    }

    this.adapter?.deleteSession(sessionId);
    this.sessions.delete(sessionId);
    this.transport.broadcast({
      type: "session_list",
      sessions: Array.from(this.sessions.values()),
    });
  }

  private async handleFileRequest(
    client: TransportClient,
    filePath: string,
    _sessionId: string,
  ): Promise<void> {
    try {
      // Security: resolve to absolute path and validate it's within workDir
      const absolutePath = resolvePath(this.options.workDir, filePath);
      const requestedWorkDir = resolvePath(this.options.workDir);

      // Reject path traversal attempts
      if (
        !absolutePath.startsWith(requestedWorkDir + "/") &&
        absolutePath !== requestedWorkDir
      ) {
        client.send({
          type: "error",
          message: "Access denied: path is outside the working directory",
        });
        return;
      }

      // Reject paths containing ..
      if (filePath.includes("..")) {
        client.send({
          type: "error",
          message: "Access denied: relative path traversal not allowed",
        });
        return;
      }

      const workDirReal = await realpath(this.options.workDir);
      const fileRealPath = await realpath(absolutePath);

      if (!fileRealPath.startsWith(workDirReal + "/") && fileRealPath !== workDirReal) {
        client.send({
          type: "error",
          message: "Access denied: path is outside the working directory",
        });
        return;
      }

      // Reject sensitive files
      const requestedRelativePath = relative(requestedWorkDir, absolutePath);
      const realRelativePath = relative(workDirReal, fileRealPath);
      if (
        SENSITIVE_PATTERNS.some((pattern) => pattern.test(requestedRelativePath)) ||
        SENSITIVE_PATTERNS.some((pattern) => pattern.test(realRelativePath))
      ) {
        client.send({
          type: "error",
          message: `Access denied: ${requestedRelativePath} is a sensitive file`,
        });
        return;
      }

      const content = await readFile(fileRealPath, "utf-8");
      const ext = extname(fileRealPath).slice(1);
      const langMap: Record<string, string> = {
        ts: "typescript",
        tsx: "typescript",
        js: "javascript",
        jsx: "javascript",
        py: "python",
        rs: "rust",
        go: "go",
        java: "java",
        swift: "swift",
        json: "json",
        yaml: "yaml",
        yml: "yaml",
        md: "markdown",
        css: "css",
        html: "html",
      };
      client.send({
        type: "file_content",
        path: requestedRelativePath,
        content,
        language: langMap[ext] ?? ext,
      });
    } catch (err) {
      client.send({
        type: "error",
        message: `Failed to read file: ${err}`,
      });
    }
  }

  private async resolveAdapter(): Promise<AgentAdapter> {
    const { agent } = this.options;
    if (agent === "codex") return new CodexAdapter();
    if (agent === "claude") return new ClaudeAdapter();

    // Auto-detect: try codex first, fall back to claude
    try {
      const { execSync } = await import("node:child_process");
      execSync("which codex", { stdio: "ignore" });
      log.info("Auto-detected: Codex CLI available");
      return new CodexAdapter();
    } catch {
      log.info("Codex not found, falling back to Claude Code");
      return new ClaudeAdapter();
    }
  }

  private eventSummary(event: AgentEvent): string {
    switch (event.type) {
      case "status":
        return `[${event.state}] ${event.message}`;
      case "thinking":
        return event.text.slice(0, 80);
      case "agent_message":
        return event.text.slice(0, 80);
      case "code_change":
        return event.changes.map((c) => `${c.kind}: ${c.path}`).join(", ");
      case "command_exec":
        return `${event.command} (${event.status})`;
      case "error":
        return event.message;
      case "turn_completed":
        return `Done. Files: ${event.filesChanged.length}`;
    }
  }
}
