import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";
import { resolve as resolvePath } from "node:path";
import type { DiffFile, DiffHunk, FileChange } from "@codepilot/protocol";
import type { SessionEventLogStore } from "../session-store/event-log.js";
import { parseUnifiedDiff, type ParsedDiffFile } from "./parser.js";

const execFile = promisify(execFileCallback);

const DEFAULT_CACHE_TTL_MS = 15_000;
const DEFAULT_HUNK_PAGE_SIZE = 1;
const MAX_HUNKS_PER_FILE = 50;
const MAX_LINES_PER_HUNK = 400;

export class DiffServiceError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DiffServiceError";
  }
}

interface DiffServiceOptions {
  workDir: string;
  eventStore: SessionEventLogStore;
  cacheTtlMs?: number;
  hunkPageSize?: number;
  loadDiffText?: (change: FileChange) => Promise<string>;
  now?: () => number;
}

interface CachedDiffEntry {
  expiresAt: number;
  files: ParsedDiffFile[];
}

interface CodeChangeRecord {
  sessionId: string;
  eventId: number;
  changes: FileChange[];
}

export class DiffService {
  private readonly workDir: string;
  private readonly eventStore: SessionEventLogStore;
  private readonly cacheTtlMs: number;
  private readonly hunkPageSize: number;
  private readonly now: () => number;
  private readonly loadDiffText: (change: FileChange) => Promise<string>;
  private readonly cache = new Map<string, CachedDiffEntry>();

  constructor(options: DiffServiceOptions) {
    this.workDir = options.workDir;
    this.eventStore = options.eventStore;
    this.cacheTtlMs = options.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS;
    this.hunkPageSize = options.hunkPageSize ?? DEFAULT_HUNK_PAGE_SIZE;
    this.now = options.now ?? (() => Date.now());
    this.loadDiffText = options.loadDiffText ?? ((change) => this.defaultLoadDiffText(change));
  }

  async loadDiff(sessionId: string, eventId: number): Promise<{
    sessionId: string;
    eventId: number;
    files: DiffFile[];
  }> {
    const files = await this.filesForEvent(sessionId, eventId);
    return {
      sessionId,
      eventId,
      files: files.map((file) => this.toInitialDiffFile(file)),
    };
  }

  async loadMoreHunks(
    sessionId: string,
    eventId: number,
    path: string,
    afterHunkIndex: number,
  ): Promise<{
    sessionId: string;
    eventId: number;
    path: string;
    hunks: DiffHunk[];
    nextHunkIndex?: number;
  }> {
    const files = await this.filesForEvent(sessionId, eventId);
    const file = files.find((entry) => entry.path === path);
    if (!file) {
      throw new DiffServiceError(`No diff file found for path ${path}`);
    }

    const hunks = file.hunks.slice(afterHunkIndex, afterHunkIndex + this.hunkPageSize);
    const nextIndex = afterHunkIndex + hunks.length;

    return {
      sessionId,
      eventId,
      path,
      hunks,
      nextHunkIndex: nextIndex < file.hunks.length ? nextIndex : undefined,
    };
  }

  private async filesForEvent(sessionId: string, eventId: number): Promise<ParsedDiffFile[]> {
    const cacheKey = `${sessionId}:${eventId}`;
    const cached = this.cache.get(cacheKey);
    if (cached && cached.expiresAt > this.now()) {
      return cached.files;
    }

    const codeChange = await this.lookupCodeChange(sessionId, eventId);
    const files = await Promise.all(
      codeChange.changes.map(async (change) => {
        const diffText = await this.loadDiffText(change);
        const parsed = parseUnifiedDiff(diffText, [change])[0];
        return this.applyLimits(
          parsed ?? {
            path: change.path,
            kind: change.kind,
            addedLines: 0,
            deletedLines: 0,
            isTruncated: true,
            truncationReason: "Diff unavailable for current workspace state.",
            totalHunkCount: 0,
            hunks: [],
          },
        );
      }),
    );

    this.cache.set(cacheKey, {
      expiresAt: this.now() + this.cacheTtlMs,
      files,
    });

    return files;
  }

  private async lookupCodeChange(sessionId: string, eventId: number): Promise<CodeChangeRecord> {
    const events = await this.eventStore.readEventsAfter(sessionId, Math.max(eventId - 1, 0));
    const target = events.find((record) => record.eventId === eventId);
    if (!target) {
      throw new DiffServiceError(`No event found for session ${sessionId} and eventId ${eventId}`);
    }
    if (target.event.type !== "code_change") {
      throw new DiffServiceError(`Event ${eventId} is not a code_change event`);
    }

    return {
      sessionId: target.sessionId,
      eventId: target.eventId,
      changes: target.event.changes,
    };
  }

  private toInitialDiffFile(file: ParsedDiffFile): DiffFile {
    const loadedHunks = file.hunks.slice(0, this.hunkPageSize);
    const nextIndex = loadedHunks.length < file.hunks.length ? loadedHunks.length : undefined;
    return {
      path: file.path,
      kind: file.kind,
      addedLines: file.addedLines,
      deletedLines: file.deletedLines,
      isTruncated: file.isTruncated,
      truncationReason: file.truncationReason,
      totalHunkCount: file.totalHunkCount,
      loadedHunks,
      nextHunkIndex: nextIndex,
    };
  }

  private applyLimits(file: ParsedDiffFile): ParsedDiffFile {
    let isTruncated = file.isTruncated;
    let truncationReason = file.truncationReason;

    const hunks = file.hunks.slice(0, MAX_HUNKS_PER_FILE).map((hunk) => {
      if (hunk.lines.length <= MAX_LINES_PER_HUNK) {
        return hunk;
      }
      isTruncated = true;
      truncationReason ??= "Diff truncated to keep the mobile viewer responsive.";
      return {
        ...hunk,
        lines: hunk.lines.slice(0, MAX_LINES_PER_HUNK),
      };
    });

    if (file.hunks.length > MAX_HUNKS_PER_FILE) {
      isTruncated = true;
      truncationReason ??= "Diff truncated to keep the mobile viewer responsive.";
    }

    return {
      ...file,
      isTruncated,
      truncationReason,
      totalHunkCount: file.hunks.length,
      hunks,
    };
  }

  private async defaultLoadDiffText(change: FileChange): Promise<string> {
    const absolutePath = resolvePath(this.workDir, change.path);
    if (change.kind === "add") {
      try {
        await access(absolutePath, constants.F_OK);
      } catch {
        return "";
      }
      return this.runGit([
        "diff",
        "--no-index",
        "--no-ext-diff",
        "--no-color",
        "--",
        "/dev/null",
        absolutePath,
      ]);
    }

    return this.runGit([
      "diff",
      "--no-ext-diff",
      "--no-color",
      "--relative",
      "--",
      change.path,
    ]);
  }

  private async runGit(args: string[]): Promise<string> {
    try {
      const { stdout } = await execFile("git", args, {
        cwd: this.workDir,
        maxBuffer: 8 * 1024 * 1024,
      });
      return stdout;
    } catch (error) {
      const exitCode = typeof error === "object" && error !== null && "code" in error
        ? (error as { code?: number | string }).code
        : undefined;
      const stdout = typeof error === "object" && error !== null && "stdout" in error
        ? String((error as { stdout?: string }).stdout ?? "")
        : "";
      if (exitCode === 1) {
        return stdout;
      }
      return "";
    }
  }
}
