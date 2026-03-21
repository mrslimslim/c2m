/**
 * ClaudeAdapter — uses `claude` CLI in headless mode with stream-json output.
 *
 * Claude Code doesn't have an official SDK, so we spawn the CLI process
 * and parse its JSONL stream.
 */

import { spawn, execSync, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import type { AgentAdapter, SessionOptions } from "./types.js";
import type { AgentEvent, SessionInfo } from "@codepilot/protocol";

interface ActiveSession {
  info: SessionInfo;
  process: ChildProcess | null;
  lastSessionId: string | null;
}

export class ClaudeAdapter implements AgentAdapter {
  readonly name = "claude" as const;
  private sessions = new Map<string, ActiveSession>();

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    // Check that `claude` CLI is installed
    try {
      execSync("which claude", { stdio: "ignore" });
    } catch {
      throw new Error(
        "Claude Code CLI is not installed. Install it with: npm install -g @anthropic-ai/claude-code",
      );
    }

    const id = `claude-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const info: SessionInfo = {
      id,
      agentType: "claude",
      workDir: opts.workDir,
      state: "idle",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    };
    this.sessions.set(id, { info, process: null, lastSessionId: null });
    return info;
  }

  async execute(
    sessionId: string,
    input: string,
    onEvent: (event: AgentEvent) => void,
  ): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    session.info.state = "thinking";
    session.info.lastActiveAt = Date.now();
    onEvent({ type: "status", state: "thinking", message: "Starting Claude..." });

    const args = [
      "-p",
      "--output-format",
      "stream-json",
      "--permission-mode",
      "acceptEdits",
    ];

    // Continue previous session if available
    if (session.lastSessionId) {
      args.push("-r", session.lastSessionId);
    }

    args.push(input);

    return new Promise<void>((resolve, reject) => {
      const proc = spawn("claude", args, {
        cwd: session.info.workDir,
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env },
      });

      session.process = proc;

      const rl = createInterface({ input: proc.stdout! });
      let lastAssistantText = "";
      // Collect all changed file paths during this turn
      const changedFiles = new Set<string>();

      rl.on("line", (line) => {
        if (!line.trim()) return;

        try {
          const data = JSON.parse(line);
          session.info.lastActiveAt = Date.now();
          this.mapClaudeEvent(data, onEvent, session, changedFiles, (text) => {
            lastAssistantText = text;
          });
        } catch {
          // Non-JSON line, ignore
        }
      });

      let stderrBuf = "";
      proc.stderr?.on("data", (chunk: Buffer) => {
        stderrBuf += chunk.toString();
      });

      proc.on("close", (code) => {
        session.process = null;
        session.info.state = "idle";

        if (code === 0) {
          onEvent({
            type: "turn_completed",
            summary: lastAssistantText.slice(0, 200) || "Turn completed",
            filesChanged: Array.from(changedFiles),
            usage: null,
          });
          resolve();
        } else {
          const errorMsg = stderrBuf.trim() || `Claude exited with code ${code}`;
          onEvent({ type: "error", message: errorMsg });
          reject(new Error(errorMsg));
        }
      });

      proc.on("error", (err) => {
        session.process = null;
        session.info.state = "error";
        onEvent({ type: "error", message: err.message });
        reject(err);
      });
    });
  }

  /**
   * Map Claude stream-json events to unified AgentEvents.
   *
   * Claude stream-json format emits objects like:
   * - { type: "assistant", message: { role, content: [...] } }
   * - { type: "result", result: "..." , session_id: "..." }
   * - Content blocks: { type: "text", text: "..." }
   * - Tool use: { type: "tool_use", name: "Bash", input: { command: "..." } }
   * - Tool result: { type: "tool_result", ... }
   */
  private mapClaudeEvent(
    data: Record<string, unknown>,
    onEvent: (event: AgentEvent) => void,
    session: ActiveSession,
    changedFiles: Set<string>,
    setLastText: (text: string) => void,
  ): void {
    const type = data.type as string;

    if (type === "assistant") {
      // Assistant message with content blocks
      const message = data.message as Record<string, unknown> | undefined;
      if (message) {
        const content = message.content as Array<Record<string, unknown>> | undefined;
        if (content) {
          for (const block of content) {
            this.mapContentBlock(block, onEvent, session, changedFiles);
          }
        }
      }
    } else if (type === "result") {
      // Final result
      const result = data.result as string | undefined;
      if (result) {
        setLastText(result);
        onEvent({ type: "agent_message", text: result });
      }
      // Capture session ID for continuation
      const sid = data.session_id as string | undefined;
      if (sid) {
        session.lastSessionId = sid;
      }
    } else if (type === "tool_use" || type === "tool_result") {
      // Tool interactions at top level
      this.mapContentBlock(data, onEvent, session, changedFiles);
    }
  }

  private mapContentBlock(
    block: Record<string, unknown>,
    onEvent: (event: AgentEvent) => void,
    session: ActiveSession,
    changedFiles: Set<string>,
  ): void {
    const blockType = block.type as string;

    if (blockType === "text") {
      const text = block.text as string;
      if (text) {
        onEvent({ type: "agent_message", text });
      }
    } else if (blockType === "thinking") {
      session.info.state = "thinking";
      const thinking = block.thinking as string;
      if (thinking) {
        onEvent({ type: "thinking", text: thinking });
      }
    } else if (blockType === "tool_use") {
      const toolName = block.name as string;
      const input = block.input as Record<string, unknown>;

      if (toolName === "Bash" || toolName === "bash") {
        session.info.state = "running_command";
        onEvent({
          type: "command_exec",
          command: (input?.command as string) ?? "",
          status: "running",
        });
      } else if (
        toolName === "Write" ||
        toolName === "Edit" ||
        toolName === "write" ||
        toolName === "edit"
      ) {
        session.info.state = "coding";
        const filePath = (input?.file_path as string) ?? (input?.path as string) ?? "";
        if (filePath) {
          changedFiles.add(filePath);
        }
        onEvent({
          type: "code_change",
          changes: [
            {
              path: filePath,
              kind: toolName.toLowerCase() === "write" ? "add" : "update",
            },
          ],
        });
      } else {
        onEvent({
          type: "status",
          state: session.info.state,
          message: `Tool: ${toolName}`,
        });
      }
    } else if (blockType === "tool_result") {
      const content = block.content as string | undefined;
      if (content) {
        onEvent({
          type: "status",
          state: session.info.state,
          message: content.slice(0, 500),
        });
      }
    }
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    const session = this.sessions.get(sessionId);
    if (session) {
      session.info.state = "idle";
      return session.info;
    }
    // Create a new session entry with the given ID for resume
    const info: SessionInfo = {
      id: sessionId,
      agentType: "claude",
      workDir: ".",
      state: "idle",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    };
    this.sessions.set(sessionId, {
      info,
      process: null,
      lastSessionId: sessionId,
    });
    return info;
  }

  cancel(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (session?.process) {
      session.process.kill("SIGTERM");
      session.process = null;
      session.info.state = "idle";
    }
  }

  deleteSession(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return;
    }

    if (session.process) {
      session.process.kill("SIGTERM");
      session.process = null;
    }

    this.sessions.delete(sessionId);
  }

  dispose(): void {
    for (const session of this.sessions.values()) {
      if (session.process) {
        session.process.kill("SIGTERM");
      }
    }
    this.sessions.clear();
  }
}
