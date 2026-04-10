import type { AgentEvent } from "@codepilot/protocol";
import { randomUUID } from "node:crypto";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  defaultSessionEventLogPath,
  defaultSessionIndexPath,
  defaultSessionStoreRoot,
  type SessionStorePathOptions,
} from "./path.js";

export interface PersistedSessionEvent {
  eventId: number;
  sessionId: string;
  timestamp: number;
  event: AgentEvent;
}

export interface SessionIndexEntry {
  canonicalSessionId: string;
  latestEventId: number;
  aliasSessionIds: string[];
  logPath: string;
}

interface SessionIndexFile {
  version: 1;
  sessions: Record<string, SessionIndexEntry>;
  aliases: Record<string, string>;
}

export interface SessionEventLogStoreOptions extends SessionStorePathOptions {
  workDir: string;
}

const mutationQueueByStorageRoot = new Map<string, Promise<void>>();

export class SessionEventLogStore {
  private readonly workDir: string;
  private readonly pathOptions: SessionStorePathOptions;
  private readonly storageRootKeyPromise: Promise<string>;

  constructor(options: SessionEventLogStoreOptions) {
    this.workDir = options.workDir;
    this.pathOptions = { homeDir: options.homeDir };
    this.storageRootKeyPromise = defaultSessionStoreRoot(this.workDir, this.pathOptions);
  }

  async appendEvent(input: {
    sessionId: string;
    timestamp: number;
    event: AgentEvent;
  }): Promise<PersistedSessionEvent> {
    return this.runSerializedMutation(async () => {
      const index = await this.loadIndexFile();
      const canonicalSessionId = this.resolveCanonicalSessionIdFromIndex(index, input.sessionId);
      const entry = await this.ensureSessionEntry(index, canonicalSessionId);
      const latestFromLog = await this.readLatestEventId(entry.logPath);
      const eventId = Math.max(entry.latestEventId, latestFromLog) + 1;
      const persisted: PersistedSessionEvent = {
        eventId,
        sessionId: canonicalSessionId,
        timestamp: input.timestamp,
        event: input.event,
      };

      await mkdir(dirname(entry.logPath), { recursive: true });
      await appendFile(entry.logPath, `${JSON.stringify(persisted)}\n`, "utf-8");

      entry.latestEventId = eventId;
      index.sessions[canonicalSessionId] = entry;
      await this.saveIndexFile(index);

      return persisted;
    });
  }

  async readEventsAfter(sessionId: string, afterEventId: number): Promise<PersistedSessionEvent[]> {
    const index = await this.loadIndexFile();
    const canonicalSessionId = this.resolveCanonicalSessionIdFromIndex(index, sessionId);
    const entry = index.sessions[canonicalSessionId];
    if (!entry) return [];

    const records = await this.readLogRecords(entry.logPath);
    return records.filter((record) => record.eventId > afterEventId);
  }

  async remapSessionAlias(aliasSessionId: string, canonicalSessionId: string): Promise<void> {
    await this.runSerializedMutation(async () => {
      const index = await this.loadIndexFile();
      const resolvedAlias = this.resolveCanonicalSessionIdFromIndex(index, aliasSessionId);
      const resolvedCanonical = this.resolveCanonicalSessionIdFromIndex(index, canonicalSessionId);
      const finalCanonical = resolvedCanonical;
      const canonicalEntry = await this.ensureSessionEntry(index, finalCanonical);

      if (resolvedAlias !== finalCanonical) {
        const aliasEntry = index.sessions[resolvedAlias];
        const aliasRecords = aliasEntry ? await this.readLogRecords(aliasEntry.logPath) : [];
        const canonicalRecords = await this.readLogRecords(canonicalEntry.logPath);

        if (aliasRecords.length > 0 && canonicalRecords.length > 0) {
          throw new Error(
            "Cannot remap alias with existing history into canonical session with existing history",
          );
        }

        if (aliasRecords.length > 0 && canonicalRecords.length === 0) {
          const migratedAliasRecords = aliasRecords.map((record): PersistedSessionEvent => ({
            ...record,
            sessionId: finalCanonical,
          }));
          await this.writeLogRecords(canonicalEntry.logPath, migratedAliasRecords);
        }

        const latestFromLog = await this.readLatestEventId(canonicalEntry.logPath);
        canonicalEntry.latestEventId = Math.max(canonicalEntry.latestEventId, latestFromLog);
        canonicalEntry.aliasSessionIds = dedupe([
          ...canonicalEntry.aliasSessionIds,
          ...(aliasEntry?.aliasSessionIds ?? []),
          resolvedAlias,
          aliasSessionId,
        ]);
        index.sessions[finalCanonical] = canonicalEntry;
        delete index.sessions[resolvedAlias];
      } else {
        const latestFromLog = await this.readLatestEventId(canonicalEntry.logPath);
        canonicalEntry.latestEventId = Math.max(canonicalEntry.latestEventId, latestFromLog);
      }

      canonicalEntry.aliasSessionIds = dedupe([
        ...canonicalEntry.aliasSessionIds,
        aliasSessionId,
        resolvedAlias,
      ]);
      index.sessions[finalCanonical] = canonicalEntry;

      index.aliases[aliasSessionId] = finalCanonical;
      index.aliases[resolvedAlias] = finalCanonical;

      for (const [alias, target] of Object.entries(index.aliases)) {
        if (target === resolvedAlias) {
          index.aliases[alias] = finalCanonical;
        }
      }

      await this.saveIndexFile(index);
    });
  }

  async resolveSessionId(sessionId: string): Promise<string> {
    const index = await this.loadIndexFile();
    return this.resolveCanonicalSessionIdFromIndex(index, sessionId);
  }

  async loadSessionIndex(sessionId: string): Promise<SessionIndexEntry | null> {
    const index = await this.loadIndexFile();
    const canonicalSessionId = this.resolveCanonicalSessionIdFromIndex(index, sessionId);
    const entry = index.sessions[canonicalSessionId];
    if (!entry) return null;

    const latestFromLog = await this.readLatestEventId(entry.logPath);
    return {
      ...entry,
      latestEventId: Math.max(entry.latestEventId, latestFromLog),
    };
  }

  private async loadIndexFile(): Promise<SessionIndexFile> {
    const indexPath = await defaultSessionIndexPath(this.workDir, this.pathOptions);

    let raw: string;
    try {
      raw = await readFile(indexPath, "utf-8");
    } catch (error) {
      if (isNotFoundError(error)) return emptyIndexFile();
      throw error;
    }

    const parsed = JSON.parse(raw) as Partial<SessionIndexFile>;
    if (parsed.version !== 1 || typeof parsed.sessions !== "object" || parsed.sessions === null) {
      throw new Error(`Invalid session index file: ${indexPath}`);
    }

    return {
      version: 1,
      sessions: parsed.sessions as Record<string, SessionIndexEntry>,
      aliases: typeof parsed.aliases === "object" && parsed.aliases !== null
        ? parsed.aliases as Record<string, string>
        : {},
    };
  }

  private async saveIndexFile(index: SessionIndexFile): Promise<void> {
    const indexPath = await defaultSessionIndexPath(this.workDir, this.pathOptions);
    const indexDir = dirname(indexPath);
    await mkdir(indexDir, { recursive: true });
    const tempPath = `${indexPath}.${process.pid}.${Date.now()}.${randomUUID()}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(index, null, 2)}\n`, "utf-8");
    await rename(tempPath, indexPath);
  }

  private async ensureSessionEntry(
    index: SessionIndexFile,
    canonicalSessionId: string,
  ): Promise<SessionIndexEntry> {
    const existing = index.sessions[canonicalSessionId];
    if (existing) {
      return existing;
    }

    return {
      canonicalSessionId,
      latestEventId: 0,
      aliasSessionIds: [],
      logPath: await defaultSessionEventLogPath(this.workDir, canonicalSessionId, this.pathOptions),
    };
  }

  private resolveCanonicalSessionIdFromIndex(index: SessionIndexFile, sessionId: string): string {
    const visited = new Set<string>();
    let current = sessionId;

    while (true) {
      if (visited.has(current)) return current;
      visited.add(current);
      const next = index.aliases[current];
      if (!next) return current;
      current = next;
    }
  }

  private async runSerializedMutation<T>(operation: () => Promise<T>): Promise<T> {
    const storageRootKey = await this.storageRootKeyPromise;
    const previous = mutationQueueByStorageRoot.get(storageRootKey) ?? Promise.resolve();
    const result = previous.then(operation, operation);
    const settled = result.then(
      () => undefined,
      () => undefined,
    );
    mutationQueueByStorageRoot.set(storageRootKey, settled);
    try {
      return await result;
    } finally {
      if (mutationQueueByStorageRoot.get(storageRootKey) === settled) {
        mutationQueueByStorageRoot.delete(storageRootKey);
      }
    }
  }

  private async readLatestEventId(logPath: string): Promise<number> {
    const records = await this.readLogRecords(logPath);
    return records[records.length - 1]?.eventId ?? 0;
  }

  private async readLogRecords(logPath: string): Promise<PersistedSessionEvent[]> {
    let raw: string;
    try {
      raw = await readFile(logPath, "utf-8");
    } catch (error) {
      if (isNotFoundError(error)) return [];
      throw error;
    }

    const trailingNewline = raw.endsWith("\n");
    const lines = raw.split("\n");
    if (trailingNewline) {
      lines.pop();
    }

    const records: PersistedSessionEvent[] = [];
    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i];
      if (!line || line.trim().length === 0) continue;

      const isLastLine = i === lines.length - 1;
      const allowTornTail = isLastLine && !trailingNewline;
      try {
        records.push(parsePersistedSessionEventLine(line));
      } catch (error) {
        if (allowTornTail) {
          break;
        }
        throw new Error(`Corrupt session event log at ${logPath}:${i + 1}`, { cause: error });
      }
    }

    return records;
  }

  private async writeLogRecords(logPath: string, records: PersistedSessionEvent[]): Promise<void> {
    await mkdir(dirname(logPath), { recursive: true });
    const raw = records.map((record) => JSON.stringify(record)).join("\n");
    await writeFile(logPath, `${raw}\n`, "utf-8");
  }
}

function emptyIndexFile(): SessionIndexFile {
  return {
    version: 1,
    sessions: {},
    aliases: {},
  };
}

function dedupe(values: string[]): string[] {
  return Array.from(new Set(values));
}

function isNotFoundError(error: unknown): error is NodeJS.ErrnoException {
  return typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT";
}

function parsePersistedSessionEventLine(line: string): PersistedSessionEvent {
  const parsed = JSON.parse(line) as Partial<PersistedSessionEvent>;
  if (
    typeof parsed.eventId !== "number" ||
    typeof parsed.sessionId !== "string" ||
    typeof parsed.timestamp !== "number" ||
    typeof parsed.event !== "object" ||
    parsed.event === null
  ) {
    throw new Error("Invalid persisted session event");
  }
  return {
    eventId: parsed.eventId,
    sessionId: parsed.sessionId,
    timestamp: parsed.timestamp,
    event: parsed.event as AgentEvent,
  };
}
