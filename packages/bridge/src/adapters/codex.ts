/**
 * CodexAdapter — uses the official @openai/codex-sdk to control Codex CLI.
 *
 * The SDK spawns `codex exec --experimental-json` under the hood and
 * exchanges structured JSONL events over stdin/stdout.
 */

import { Codex } from "@openai/codex-sdk";
import type { AgentAdapter, SessionOptions } from "./types.js";
import type { AgentEvent, SessionInfo } from "@codepilot/protocol";

interface ActiveSession {
  info: SessionInfo;
  thread: ReturnType<Codex["startThread"]>;
  abortController: AbortController;
}

export class CodexAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  private codex: Codex;
  private sessions = new Map<string, ActiveSession>();

  constructor() {
    this.codex = new Codex();
  }

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    const thread = this.codex.startThread({
      model: opts.model ?? "gpt-5.4",
      workingDirectory: opts.workDir,
      skipGitRepoCheck: true,
      sandboxMode: (opts.sandboxMode as "read-only" | "workspace-write" | "danger-full-access") ?? "workspace-write",
      approvalPolicy: (opts.approvalPolicy as "never" | "on-request" | "on-failure" | "untrusted") ?? "on-request",
    });

    // Thread ID is null until first turn; we'll use a temp ID
    const tempId = `codex-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

    const info: SessionInfo = {
      id: tempId,
      agentType: "codex",
      workDir: opts.workDir,
      state: "idle",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    };

    this.sessions.set(tempId, {
      info,
      thread,
      abortController: new AbortController(),
    });

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

    session.abortController = new AbortController();
    session.info.state = "thinking";
    session.info.lastActiveAt = Date.now();

    onEvent({ type: "status", state: "thinking", message: "Processing..." });

    try {
      const { events } = await session.thread.runStreamed(input, {
        signal: session.abortController.signal,
      });

      for await (const event of events) {
        session.info.lastActiveAt = Date.now();

        switch (event.type) {
          case "thread.started": {
            // Update session ID to the real thread ID
            const realId = event.thread_id;
            if (realId && realId !== sessionId) {
              this.sessions.set(realId, session);
              // Keep old ID as alias pointing to the same session
              // (don't delete — phone may still reference the temp ID)
              session.info.id = realId;
            }
            break;
          }

          case "turn.started":
            session.info.state = "thinking";
            onEvent({ type: "status", state: "thinking", message: "Turn started" });
            break;

          case "item.started":
          case "item.updated":
            this.mapItemEvent(event.item, onEvent, session);
            break;

          case "item.completed":
            this.mapItemEvent(event.item, onEvent, session);
            break;

          case "turn.completed":
            session.info.state = "idle";
            onEvent({
              type: "turn_completed",
              summary: "Turn completed",
              filesChanged: [],
              usage: event.usage
                ? {
                    inputTokens: event.usage.input_tokens ?? 0,
                    outputTokens: event.usage.output_tokens ?? 0,
                    cachedInputTokens: event.usage.cached_input_tokens,
                  }
                : null,
            });
            break;

          case "turn.failed":
            session.info.state = "error";
            onEvent({
              type: "error",
              message: event.error?.message ?? "Turn failed",
            });
            break;

          case "error":
            session.info.state = "error";
            onEvent({
              type: "error",
              message: event.message ?? "Unknown error",
            });
            break;
        }
      }
    } catch (err: unknown) {
      if (session.abortController.signal.aborted) {
        onEvent({ type: "status", state: "idle", message: "Cancelled" });
      } else {
        const msg = err instanceof Error ? err.message : String(err);
        session.info.state = "error";
        onEvent({ type: "error", message: msg });
      }
    }
  }

  /**
   * Map a Codex ThreadItem to one or more unified AgentEvents.
   */
  private mapItemEvent(
    item: Record<string, unknown>,
    onEvent: (event: AgentEvent) => void,
    session: ActiveSession,
  ): void {
    const itemType = item.type as string;

    switch (itemType) {
      case "agent_message":
        onEvent({
          type: "agent_message",
          text: (item.text as string) ?? "",
        });
        break;

      case "reasoning":
        session.info.state = "thinking";
        onEvent({
          type: "thinking",
          text: (item.text as string) ?? "",
        });
        break;

      case "command_execution":
        session.info.state = "running_command";
        onEvent({
          type: "command_exec",
          command: (item.command as string) ?? "",
          output: item.aggregated_output as string | undefined,
          exitCode: item.exit_code as number | undefined,
          status:
            item.status === "completed"
              ? "done"
              : item.status === "failed"
                ? "failed"
                : "running",
        });
        break;

      case "file_change": {
        session.info.state = "coding";
        const changes = (item.changes as Array<{ path: string; kind: string }>) ?? [];
        onEvent({
          type: "code_change",
          changes: changes.map((c) => ({
            path: c.path,
            kind: c.kind as "add" | "delete" | "update",
          })),
        });
        break;
      }

      case "error":
        session.info.state = "error";
        onEvent({
          type: "error",
          message: (item.message as string) ?? "Unknown error",
        });
        break;

      // web_search, mcp_tool_call, todo_list — forward as status
      default:
        onEvent({
          type: "status",
          state: session.info.state,
          message: `[${itemType}] ${JSON.stringify(item).slice(0, 200)}`,
        });
    }
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    const thread = this.codex.resumeThread(sessionId);
    const info: SessionInfo = {
      id: sessionId,
      agentType: "codex",
      workDir: ".",
      state: "idle",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    };
    this.sessions.set(sessionId, {
      info,
      thread,
      abortController: new AbortController(),
    });
    return info;
  }

  cancel(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (session) {
      session.abortController.abort();
      session.info.state = "idle";
    }
  }

  deleteSession(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return;
    }

    session.abortController.abort();
    for (const [id, candidate] of this.sessions.entries()) {
      if (candidate === session) {
        this.sessions.delete(id);
      }
    }
  }

  dispose(): void {
    for (const session of this.sessions.values()) {
      session.abortController.abort();
    }
    this.sessions.clear();
  }
}
