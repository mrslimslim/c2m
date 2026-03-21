import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import {
  exportPrivateKeyBase64,
  generateKeyPair,
  restoreKeyPairFromPrivateKeyBase64,
  type E2EKeyPair,
} from "./crypto.js";

export interface PairingMaterial {
  keyPair: E2EKeyPair;
  otp: string;
  token: string;
  statePath: string;
}

interface PersistedPairingMaterial {
  version: 1;
  privateKeyBase64: string;
  otp: string;
  token: string;
}

export async function defaultPairingStatePath(workDir: string): Promise<string> {
  let normalizedWorkDir = workDir;
  try {
    normalizedWorkDir = await realpath(workDir);
  } catch {
    // Fall back to the provided path if the workDir does not resolve yet.
  }

  const workDirHash = createHash("sha256")
    .update(normalizedWorkDir)
    .digest("hex")
    .slice(0, 16);

  return join(homedir(), ".codepilot", "pairing", `${workDirHash}.json`);
}

export async function loadOrCreatePairingMaterial(
  options: { filePath?: string; workDir?: string } = {},
): Promise<PairingMaterial> {
  const statePath = options.filePath ?? await defaultPairingStatePath(options.workDir ?? process.cwd());
  const persisted = await loadPersistedPairingMaterial(statePath);

  if (persisted) {
    return {
      keyPair: restoreKeyPairFromPrivateKeyBase64(persisted.privateKeyBase64),
      otp: persisted.otp,
      token: persisted.token,
      statePath,
    };
  }

  const created: PairingMaterial = {
    keyPair: generateKeyPair(),
    otp: randomBytes(3).toString("hex"),
    token: randomBytes(16).toString("hex"),
    statePath,
  };
  await savePersistedPairingMaterial(created);
  return created;
}

async function loadPersistedPairingMaterial(
  statePath: string,
): Promise<PersistedPairingMaterial | null> {
  let raw: string;
  try {
    raw = await readFile(statePath, "utf-8");
  } catch (error) {
    if (isNotFoundError(error)) {
      return null;
    }
    throw error;
  }

  const parsed = JSON.parse(raw) as Partial<PersistedPairingMaterial>;
  if (
    parsed.version !== 1 ||
    typeof parsed.privateKeyBase64 !== "string" ||
    typeof parsed.otp !== "string" ||
    typeof parsed.token !== "string"
  ) {
    throw new Error(`Invalid pairing state file: ${statePath}`);
  }

  return {
    version: 1,
    privateKeyBase64: parsed.privateKeyBase64,
    otp: parsed.otp,
    token: parsed.token,
  };
}

async function savePersistedPairingMaterial(material: PairingMaterial): Promise<void> {
  const persisted: PersistedPairingMaterial = {
    version: 1,
    privateKeyBase64: exportPrivateKeyBase64(material.keyPair.privateKey),
    otp: material.otp,
    token: material.token,
  };

  await mkdir(dirname(material.statePath), { recursive: true });
  await writeFile(
    material.statePath,
    `${JSON.stringify(persisted, null, 2)}\n`,
    "utf-8",
  );
}

function isNotFoundError(error: unknown): error is NodeJS.ErrnoException {
  return typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT";
}
