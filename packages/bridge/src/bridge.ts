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
import type {
  AgentEvent,
  PhoneMessage,
  SessionConfig,
  SessionInfo,
  SlashCatalogMessage,
} from "@codepilot/protocol";
import type { AgentAdapter, SessionOptions } from "./adapters/types.js";
import type { TransportClient, TransportServer } from "./transport/types.js";
import { CodexAdapter } from "./adapters/codex.js";
import { ClaudeAdapter } from "./adapters/claude.js";
import { LocalTransport } from "./transport/local.js";
import { displayQRCode } from "./pairing/qrcode.js";
import { loadOrCreatePairingMaterial } from "./pairing/state.js";
import { SessionEventLogStore, type PersistedSessionEvent } from "./session-store/event-log.js";
import { DiffService } from "./diff/service.js";
import { dispatchSlashAction } from "./slash/actions.js";
import { buildSlashCatalog } from "./slash/catalog.js";
import { detectAdapterVersion } from "./slash/version.js";
import { log } from "./utils/logger.js";

export interface BridgeOptions {
  agent: "codex" | "claude" | "auto";
  port: number;
  host?: string;
  workDir: string;
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

interface ReplayState {
  clientId: string;
  requestedSessionId: string;
  canonicalResolutionPending: boolean;
  sessionKeys: Set<string>;
  queuedEvents: Array<{
    type: "event";
    sessionId: string;
    event: AgentEvent;
    eventId: number;
    timestamp: number;
  }>;
}

export class Bridge {
  private adapter: AgentAdapter | null = null;
  private transport: TransportServer;
  private sessions = new Map<string, SessionInfo>();
  private sessionAliases = new Map<string, string>();
  private options: BridgeOptions;
  private tunnelStop: (() => void) | null = null;
  private readonly connectedClients = new Map<string, TransportClient>();
  private readonly replayStates = new Map<string, ReplayState>();
  private readonly sessionEventStore: SessionEventLogStore;
  private readonly diffService: DiffService;
  private readonly deliveryQueueBySession = new Map<string, Promise<void>>();
  private adapterVersion?: string;
  private slashCatalog: SlashCatalogMessage | null = null;
  private slashCatalogKey: string | null = null;

  constructor(options: BridgeOptions) {
    this.options = options;
    this.transport = null as unknown as TransportServer;
    this.sessionEventStore = new SessionEventLogStore({
      workDir: this.options.workDir,
    });
    this.diffService = new DiffService({
      workDir: this.options.workDir,
      eventStore: this.sessionEventStore,
    });
  }

  async start(): Promise<void> {
    const pairingMaterial = await loadOrCreatePairingMaterial({
      workDir: this.options.workDir,
    });
    log.info(`Pairing state: ${pairingMaterial.statePath}`);

    this.transport = new LocalTransport(
      this.options.port,
      this.options.host ?? "127.0.0.1",
      pairingMaterial,
    );

    // 1. Resolve adapter
    this.adapter = await this.resolveAdapter();
    this.adapterVersion = await detectAdapterVersion(this.adapter.name);
    log.success(`Agent: ${this.adapter.name}`);

    // 2. Start transport (interface-only, no cast)
    const { pairingData, listenUrl } = await this.transport.start();
    log.success(`WebSocket server listening on ${listenUrl}`);

    // 3. Display QR code
    log.info("Starting Cloudflare Tunnel...");
    const { startTunnel } = await import("./utils/tunnel.js");
    const tunnel = await startTunnel(this.resolveLocalListenPort(pairingData));
    this.tunnelStop = tunnel.stop;
    log.success(`Tunnel URL: ${tunnel.url}`);

    // Override pairing data with tunnel info
    const tunnelHostname = tunnel.url.replace("https://", "");
    const tunnelPairingData = {
      ...pairingData,
      host: tunnelHostname,
      port: 443,
      tunnel: true,
    };
    log.info("Scan this QR code with your phone to connect:");
    displayQRCode(tunnelPairingData);
    log.info(`Or connect manually: ${tunnel.wsUrl}`);

    // 4. Wire up event handlers
    this.transport.onConnect((client) => {
      this.handleClientConnected(client);
    });

    this.transport.onDisconnect((client) => {
      this.connectedClients.delete(client.id);
      this.clearReplayStateForClient(client.id);
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
    this.rememberClient(client);

    switch (message.type) {
      case "command":
        await this.handleCommand(client, message.text, message.sessionId, message.config);
        break;

      case "cancel":
        {
          const sessionId = await this.resolveCanonicalSessionId(message.sessionId);
          this.adapter?.cancel(sessionId);
          await this.persistAndDispatchEvent(
            sessionId,
            { type: "status", state: "idle", message: "Cancelled" },
          );
        }
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

      case "sync_session":
        await this.handleSyncSession(client, message.sessionId, message.afterEventId);
        break;

      case "diff_req":
        client.send({
          type: "diff_content",
          ...(await this.diffService.loadDiff(message.sessionId, message.eventId)),
        });
        break;

      case "diff_hunks_req":
        client.send({
          type: "diff_hunks_content",
          ...(await this.diffService.loadMoreHunks(
            message.sessionId,
            message.eventId,
            message.path,
            message.afterHunkIndex,
          )),
        });
        break;

      case "slash_action":
        this.handleSlashAction(client, message);
        break;
    }
  }

  private resolveLocalListenPort(pairingData: Record<string, unknown>): number {
    const candidate = pairingData.port;
    if (typeof candidate === "number" && Number.isInteger(candidate) && candidate > 0) {
      return candidate;
    }
    if (typeof candidate === "string") {
      const parsed = Number.parseInt(candidate, 10);
      if (Number.isInteger(parsed) && parsed > 0) {
        return parsed;
      }
    }
    if (Number.isInteger(this.options.port) && this.options.port > 0) {
      return this.options.port;
    }
    throw new Error("Bridge transport did not expose a valid local listen port");
  }

  private handleClientConnected(client: TransportClient): void {
    this.rememberClient(client);
    log.connection(`Device connected: ${client.id}`);
    client.send({
      type: "session_list",
      sessions: Array.from(this.sessions.values()),
    });
    const slashCatalog = this.getSlashCatalog();
    if (slashCatalog) {
      client.send(slashCatalog);
    }
  }

  private async handleCommand(
    client: TransportClient,
    text: string,
    sessionId?: string,
    config?: SessionConfig,
  ): Promise<void> {
    this.rememberClient(client);

    if (!this.adapter) {
      client.send({ type: "error", message: "No agent adapter available" });
      return;
    }

    const sessionOptions = this.buildSessionOptions(config);

    // Start or find session
    let sid = sessionId ? await this.resolveCanonicalSessionId(sessionId) : undefined;
    if (!sid || !this.sessions.has(sid)) {
      const session = await this.adapter.startSession(sessionOptions);
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

    let eventChain = Promise.resolve();
    const onEvent = (event: AgentEvent) => {
      eventChain = eventChain.then(async () => {
        const remap = await this.prepareSessionAlias(sid!);
        sid = remap.canonicalSessionId;
        log.event(sid!, event.type, this.eventSummary(event));
        const persisted = await this.persistAndDispatchEvent(sid!, event, undefined, remap.finalizeAfterPersist);
        sid = persisted.sessionId;
      });
      void eventChain.catch(() => {});
    };

    let executionError: unknown = null;
    try {
      await this.adapter.execute(sid, text, onEvent, config ? sessionOptions : undefined);
    } catch (err) {
      executionError = err;
    }

    await eventChain;

    if (executionError) {
      log.error(`Execution error: ${executionError}`);
      const persisted = await this.persistAndDispatchEvent(sid, {
        type: "error",
        message: executionError instanceof Error ? executionError.message : String(executionError),
      });
      sid = persisted.sessionId;
    }
  }

  private buildSessionOptions(config?: SessionConfig): SessionOptions {
    const options: SessionOptions = {
      workDir: this.options.workDir,
    };
    if (config?.model !== undefined) {
      options.model = config.model;
    }
    if (config?.modelReasoningEffort !== undefined) {
      options.modelReasoningEffort = config.modelReasoningEffort;
    }
    if (config?.approvalPolicy !== undefined) {
      options.approvalPolicy = config.approvalPolicy;
    }
    if (config?.sandboxMode !== undefined) {
      options.sandboxMode = config.sandboxMode;
    }
    return options;
  }

  private rememberClient(client: TransportClient): void {
    this.connectedClients.set(client.id, client);
  }

  private handleSlashAction(
    client: TransportClient,
    message: Extract<PhoneMessage, { type: "slash_action" }>,
  ): void {
    const slashCatalog = this.getSlashCatalog();
    if (!slashCatalog) {
      client.send({
        type: "slash_action_result",
        commandId: message.commandId,
        ok: false,
        message: "No slash catalog is available for the current adapter.",
      });
      return;
    }

    client.send(dispatchSlashAction(message, slashCatalog));
  }

  private getSlashCatalog(): SlashCatalogMessage | null {
    if (!this.adapter) {
      return null;
    }

    const cacheKey = `${this.adapter.name}:${this.adapterVersion ?? "fallback"}`;
    if (!this.slashCatalog || this.slashCatalogKey !== cacheKey) {
      this.slashCatalog = buildSlashCatalog({
        adapter: this.adapter.name,
        adapterVersion: this.adapterVersion,
      });
      this.slashCatalogKey = cacheKey;
    }

    return this.slashCatalog;
  }

  private clearReplayStateForClient(clientId: string): void {
    for (const key of this.replayStates.keys()) {
      if (key.startsWith(`${clientId}:`)) {
        this.replayStates.delete(key);
      }
    }
  }

  private async remapSessionAlias(oldSessionId: string, newSessionId: string): Promise<void> {
    if (oldSessionId === newSessionId) return;
    this.sessionAliases.set(oldSessionId, newSessionId);
    this.propagateReplaySessionAlias(oldSessionId, newSessionId);
    await this.sessionEventStore.remapSessionAlias(oldSessionId, newSessionId);
  }

  private resolveCanonicalSessionIdLocally(sessionId: string): string {
    const visited = new Set<string>();
    let current = sessionId;
    while (true) {
      if (visited.has(current)) return current;
      visited.add(current);
      const next = this.sessionAliases.get(current);
      if (!next) return current;
      current = next;
    }
  }

  private async resolveCanonicalSessionId(sessionId: string): Promise<string> {
    const local = this.resolveCanonicalSessionIdLocally(sessionId);
    return this.sessionEventStore.resolveSessionId(local);
  }

  private async prepareSessionAlias(sessionId: string): Promise<{
    canonicalSessionId: string;
    finalizeAfterPersist?: () => void;
  }> {
    const currentSession = this.sessions.get(sessionId);
    if (!currentSession) {
      return { canonicalSessionId: await this.resolveCanonicalSessionId(sessionId) };
    }

    if (currentSession.id === sessionId) {
      return { canonicalSessionId: await this.resolveCanonicalSessionId(sessionId) };
    }

    const canonicalSessionId = currentSession.id;
    await this.remapSessionAlias(sessionId, canonicalSessionId);

    return {
      canonicalSessionId,
      finalizeAfterPersist: () => {
        this.sessions.delete(sessionId);
        this.sessions.set(canonicalSessionId, currentSession);
        this.transport.broadcast({
          type: "session_list",
          sessions: Array.from(this.sessions.values()),
        });
      },
    };
  }

  private async handleSyncSession(
    client: TransportClient,
    sessionId: string,
    afterEventId: number,
  ): Promise<void> {
    const replayState: ReplayState = {
      clientId: client.id,
      requestedSessionId: sessionId,
      canonicalResolutionPending: true,
      sessionKeys: new Set<string>(),
      queuedEvents: [],
    };
    const provisionalSessionId = this.resolveCanonicalSessionIdLocally(sessionId);
    this.registerReplayState(client.id, replayState, sessionId, provisionalSessionId);

    try {
      const resolvedSessionId = await this.resolveCanonicalSessionId(sessionId);
      this.registerReplayState(client.id, replayState, resolvedSessionId);
      replayState.canonicalResolutionPending = false;

      const replayedEvents = await this.sessionEventStore.readEventsAfter(
        resolvedSessionId,
        afterEventId,
      );
      const sessionIndex = await this.sessionEventStore.loadSessionIndex(resolvedSessionId);

      let latestEventId = afterEventId;
      if (replayedEvents.length > 0) {
        latestEventId = Math.max(
          latestEventId,
          replayedEvents[replayedEvents.length - 1]?.eventId ?? latestEventId,
        );
      } else if ((sessionIndex?.latestEventId ?? 0) < latestEventId) {
        latestEventId = sessionIndex?.latestEventId ?? 0;
      }
      for (const replayed of replayedEvents) {
        client.send(this.toEventMessage(replayed));
        latestEventId = Math.max(latestEventId, replayed.eventId);
      }

      latestEventId = this.flushQueuedReplayEvents(client, replayState, latestEventId);

      const finalResolvedSessionId = await this.resolveCanonicalSessionId(sessionId);
      this.registerReplayState(client.id, replayState, finalResolvedSessionId);

      const finalSessionIndex = finalResolvedSessionId === resolvedSessionId
        ? sessionIndex
        : await this.sessionEventStore.loadSessionIndex(finalResolvedSessionId);

      await this.enqueueDelivery(finalResolvedSessionId, async () => {
        latestEventId = this.flushQueuedReplayEvents(client, replayState, latestEventId);
        latestEventId = Math.max(latestEventId, finalSessionIndex?.latestEventId ?? 0);
        client.send({
          type: "session_sync_complete",
          sessionId: finalResolvedSessionId,
          latestEventId,
          resolvedSessionId: finalResolvedSessionId !== sessionId ? finalResolvedSessionId : undefined,
        });
        this.unregisterReplayState(client.id, replayState);
      });
    } finally {
      this.unregisterReplayState(client.id, replayState);
    }
  }

  private flushQueuedReplayEvents(
    client: TransportClient,
    replayState: ReplayState,
    initialLatestEventId: number,
  ): number {
    let latestEventId = initialLatestEventId;

    while (replayState.queuedEvents.length > 0) {
      const queuedEvents = replayState.queuedEvents
        .filter((message) => message.eventId > latestEventId)
        .sort((left, right) => left.eventId - right.eventId);
      replayState.queuedEvents = [];

      if (queuedEvents.length === 0) break;

      for (const queuedEvent of queuedEvents) {
        client.send(queuedEvent);
        latestEventId = queuedEvent.eventId;
      }
    }

    return latestEventId;
  }

  private async persistAndDispatchEvent(
    sessionId: string,
    event: AgentEvent,
    targetClients?: TransportClient[],
    afterPersist?: () => void,
  ): Promise<PersistedSessionEvent> {
    const canonicalSessionId = await this.resolveCanonicalSessionId(sessionId);
    const persisted = await this.sessionEventStore.appendEvent({
      sessionId: canonicalSessionId,
      timestamp: Date.now(),
      event,
    });

    await this.enqueueDelivery(persisted.sessionId, async () => {
      afterPersist?.();
      this.updateSessionState(persisted);
      await this.dispatchPersistedEvent(persisted, targetClients);
    });

    return persisted;
  }

  private updateSessionState(persisted: PersistedSessionEvent): void {
    const session = this.sessions.get(persisted.sessionId);
    if (!session) return;

    const event = persisted.event;
    if ("state" in event) {
      session.state = event.state;
    } else if (event.type === "turn_completed") {
      session.state = "idle";
    } else if (event.type === "error") {
      session.state = "error";
    }
    session.lastActiveAt = persisted.timestamp;
  }

  private async dispatchPersistedEvent(
    persisted: PersistedSessionEvent,
    targetClients?: TransportClient[],
  ): Promise<void> {
    const message = this.toEventMessage(persisted);
    const clients = targetClients ?? Array.from(this.connectedClients.values());

    for (const client of clients) {
      const replayState = await this.replayStateForPersistedSession(client.id, persisted.sessionId);
      if (replayState) {
        replayState.queuedEvents.push(message);
        continue;
      }
      client.send(message);
    }
  }

  private async replayStateForPersistedSession(
    clientId: string,
    sessionId: string,
  ): Promise<ReplayState | undefined> {
    const direct = this.replayStates.get(this.replayStateKey(clientId, sessionId));
    if (direct) {
      return direct;
    }

    const replayStates = new Set(
      Array.from(this.replayStates.values()).filter(
        (replayState) => replayState.clientId === clientId && replayState.canonicalResolutionPending,
      ),
    );

    for (const replayState of replayStates) {
      const resolvedSessionId = await this.resolveCanonicalSessionId(replayState.requestedSessionId);
      this.registerReplayState(clientId, replayState, resolvedSessionId);
      if (resolvedSessionId === sessionId) {
        return replayState;
      }
    }

    return undefined;
  }

  private toEventMessage(persisted: PersistedSessionEvent): {
    type: "event";
    sessionId: string;
    event: AgentEvent;
    eventId: number;
    timestamp: number;
  } {
    return {
      type: "event",
      sessionId: persisted.sessionId,
      event: persisted.event,
      eventId: persisted.eventId,
      timestamp: persisted.timestamp,
    };
  }

  private async enqueueDelivery<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.deliveryQueueBySession.get(sessionId) ?? Promise.resolve();
    const result = previous.then(operation, operation);
    const settled = result.then(
      () => undefined,
      () => undefined,
    );
    this.deliveryQueueBySession.set(sessionId, settled);
    try {
      return await result;
    } finally {
      if (this.deliveryQueueBySession.get(sessionId) === settled) {
        this.deliveryQueueBySession.delete(sessionId);
      }
    }
  }

  private propagateReplaySessionAlias(oldSessionId: string, newSessionId: string): void {
    const replayStates = new Set(this.replayStates.values());
    for (const replayState of replayStates) {
      if (!replayState.sessionKeys.has(oldSessionId)) continue;
      this.registerReplayState(replayState.clientId, replayState, newSessionId);
    }
  }

  private replayStateKey(clientId: string, sessionId: string): string {
    return `${clientId}:${sessionId}`;
  }

  private registerReplayState(
    clientId: string,
    replayState: ReplayState,
    ...sessionIds: string[]
  ): void {
    for (const sessionId of sessionIds) {
      if (!sessionId) continue;
      replayState.sessionKeys.add(sessionId);
      this.replayStates.set(this.replayStateKey(clientId, sessionId), replayState);
    }
  }

  private unregisterReplayState(clientId: string, replayState: ReplayState): void {
    for (const sessionId of replayState.sessionKeys) {
      const key = this.replayStateKey(clientId, sessionId);
      if (this.replayStates.get(key) === replayState) {
        this.replayStates.delete(key);
      }
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
