import type { AgentEvent } from "@codepilot/protocol";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  defaultSessionEventLogPath,
  defaultSessionIndexPath,
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

export class SessionEventLogStore {
  private readonly workDir: string;
  private readonly pathOptions: SessionStorePathOptions;

  constructor(options: SessionEventLogStoreOptions) {
    this.workDir = options.workDir;
    this.pathOptions = { homeDir: options.homeDir };
  }

  async appendEvent(input: {
    sessionId: string;
    timestamp: number;
    event: AgentEvent;
  }): Promise<PersistedSessionEvent> {
    const index = await this.loadIndexFile();
    const canonicalSessionId = this.resolveCanonicalSessionIdFromIndex(index, input.sessionId);
    const entry = await this.ensureSessionEntry(index, canonicalSessionId);
    const eventId = entry.latestEventId + 1;
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
  }

  async readEventsAfter(sessionId: string, afterEventId: number): Promise<PersistedSessionEvent[]> {
    const index = await this.loadIndexFile();
    const canonicalSessionId = this.resolveCanonicalSessionIdFromIndex(index, sessionId);
    const entry = index.sessions[canonicalSessionId];
    if (!entry) return [];

    let raw: string;
    try {
      raw = await readFile(entry.logPath, "utf-8");
    } catch (error) {
      if (isNotFoundError(error)) return [];
      throw error;
    }

    return raw
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .map((line) => JSON.parse(line) as PersistedSessionEvent)
      .filter((record) => record.eventId > afterEventId);
  }

  async remapSessionAlias(aliasSessionId: string, canonicalSessionId: string): Promise<void> {
    const index = await this.loadIndexFile();
    const resolvedAlias = this.resolveCanonicalSessionIdFromIndex(index, aliasSessionId);
    const resolvedCanonical = this.resolveCanonicalSessionIdFromIndex(index, canonicalSessionId);

    const finalCanonical = resolvedAlias === resolvedCanonical
      ? resolvedCanonical
      : resolvedCanonical;
    const canonicalEntry = await this.ensureSessionEntry(index, finalCanonical);

    if (resolvedAlias !== finalCanonical) {
      const aliasEntry = index.sessions[resolvedAlias];
      if (aliasEntry) {
        if (canonicalEntry.latestEventId === 0 && aliasEntry.latestEventId > 0) {
          await mkdir(dirname(canonicalEntry.logPath), { recursive: true });
          try {
            await rename(aliasEntry.logPath, canonicalEntry.logPath);
          } catch (error) {
            if (!isNotFoundError(error)) {
              throw error;
            }
          }
        }

        canonicalEntry.latestEventId = Math.max(canonicalEntry.latestEventId, aliasEntry.latestEventId);
        canonicalEntry.aliasSessionIds = dedupe([
          ...canonicalEntry.aliasSessionIds,
          ...aliasEntry.aliasSessionIds,
          resolvedAlias,
          aliasSessionId,
        ]);
        index.sessions[finalCanonical] = canonicalEntry;
        delete index.sessions[resolvedAlias];
      }
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
  }

  async resolveSessionId(sessionId: string): Promise<string> {
    const index = await this.loadIndexFile();
    return this.resolveCanonicalSessionIdFromIndex(index, sessionId);
  }

  async loadSessionIndex(sessionId: string): Promise<SessionIndexEntry | null> {
    const index = await this.loadIndexFile();
    const canonicalSessionId = this.resolveCanonicalSessionIdFromIndex(index, sessionId);
    return index.sessions[canonicalSessionId] ?? null;
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
    await mkdir(dirname(indexPath), { recursive: true });
    await writeFile(indexPath, `${JSON.stringify(index, null, 2)}\n`, "utf-8");
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
