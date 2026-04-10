import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { SessionInfo } from "@codepilot/protocol";

const execFileAsync = promisify(execFile);

type AgentType = SessionInfo["agentType"];

export interface DetectAdapterVersionOptions {
  runVersionCommand?: (command: string, args: string[]) => Promise<string>;
}

export async function detectAdapterVersion(
  adapter: AgentType,
  options: DetectAdapterVersionOptions = {},
): Promise<string | undefined> {
  const runVersionCommand = options.runVersionCommand ?? defaultRunVersionCommand;
  const command = adapter === "codex" ? "codex" : "claude";

  try {
    const output = await runVersionCommand(command, ["--version"]);
    return parseAdapterVersion(adapter, output);
  } catch {
    return undefined;
  }
}

export function parseCodexCliVersion(output: string): string | undefined {
  return parseSemanticVersion(output);
}

function parseAdapterVersion(adapter: AgentType, output: string): string | undefined {
  switch (adapter) {
    case "codex":
      return parseCodexCliVersion(output);
    case "claude":
      return parseSemanticVersion(output);
  }
}

async function defaultRunVersionCommand(command: string, args: string[]): Promise<string> {
  const result = await execFileAsync(command, args, { encoding: "utf8" });
  return `${result.stdout}${result.stderr}`.trim();
}

function parseSemanticVersion(output: string): string | undefined {
  const match = output.match(/\b(\d+\.\d+\.\d+)\b/);
  return match?.[1];
}
