import { createHash } from "node:crypto";
import { realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export interface SessionStorePathOptions {
  homeDir?: string;
}

export async function defaultSessionStoreRoot(
  workDir: string,
  options: SessionStorePathOptions = {},
): Promise<string> {
  const normalizedWorkDir = await normalizeWorkDir(workDir);
  const workDirHash = createHash("sha256")
    .update(normalizedWorkDir)
    .digest("hex")
    .slice(0, 16);

  return join(options.homeDir ?? homedir(), ".codepilot", "sessions", workDirHash);
}

export async function defaultSessionIndexPath(
  workDir: string,
  options: SessionStorePathOptions = {},
): Promise<string> {
  return join(await defaultSessionStoreRoot(workDir, options), "index.json");
}

export async function defaultSessionEventLogPath(
  workDir: string,
  sessionId: string,
  options: SessionStorePathOptions = {},
): Promise<string> {
  if (sessionId.includes("/") || sessionId.includes("\\")) {
    throw new Error(`Invalid session id for event log path: ${sessionId}`);
  }

  return join(await defaultSessionStoreRoot(workDir, options), "events", `${sessionId}.jsonl`);
}

async function normalizeWorkDir(workDir: string): Promise<string> {
  try {
    return await realpath(workDir);
  } catch {
    return workDir;
  }
}
