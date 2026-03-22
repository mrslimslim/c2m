/**
 * CodexAdapter — uses the official @openai/codex-sdk to control Codex CLI.
 *
 * The SDK spawns `codex exec --experimental-json` under the hood and
 * exchanges structured JSONL events over stdin/stdout.
 */

import { Codex, type ThreadOptions } from "@openai/codex-sdk";
import type { AgentAdapter, SessionOptions } from "./types.js";
import type { AgentEvent, SessionInfo } from "@codepilot/protocol";
import { CodexCliThread, type CodexThreadLike } from "./codex-cli-thread.js";

const DEFAULT_MODEL = "gpt-5.4";
const DEFAULT_REASONING_EFFORT = "medium";
const DEFAULT_SANDBOX_MODE = "workspace-write";
const DEFAULT_APPROVAL_POLICY = "on-request";

interface ResolvedSessionOptions {
  model: string;
  modelReasoningEffort: NonNullable<SessionOptions["modelReasoningEffort"]>;
  workDir: string;
  approvalPolicy: NonNullable<SessionOptions["approvalPolicy"]>;
  sandboxMode: NonNullable<SessionOptions["sandboxMode"]>;
}

interface ActiveSession {
  info: SessionInfo;
  thread: CodexThreadLike;
  abortController: AbortController;
  options: ResolvedSessionOptions;
}

export class CodexAdapter implements AgentAdapter {
  readonly name = "codex" as const;
  private codex: Codex;
  private sessions = new Map<string, ActiveSession>();

  constructor() {
    this.codex = new Codex();
  }

  async startSession(opts: SessionOptions): Promise<SessionInfo> {
    const resolvedOptions = this.resolveSessionOptions(opts);
    const thread = this.createThread(resolvedOptions);

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
      options: resolvedOptions,
    });

    return info;
  }

  async execute(
    sessionId: string,
    input: string,
    onEvent: (event: AgentEvent) => void,
    opts?: SessionOptions,
  ): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    if (opts) {
      const nextOptions = this.mergeSessionOptions(session.options, opts);
      if (!this.sessionOptionsEqual(session.options, nextOptions)) {
        session.thread = this.createThread(nextOptions, session.info.id);
        session.options = nextOptions;
        session.info.workDir = nextOptions.workDir;
      }
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
          message: `[${itemType}] ${JSON.stringify(item)}`,
        });
    }
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    const options = this.resolveSessionOptions({ workDir: "." });
    const thread = this.createThread(options, sessionId);
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
      options,
    });
    return info;
  }

  private createThread(
    opts: ResolvedSessionOptions,
    sessionId?: string,
  ): CodexThreadLike {
    if (this.shouldBypassApprovalsAndSandbox(opts)) {
      return new CodexCliThread(this.toThreadOptions(opts), sessionId ?? null, true);
    }

    const threadOptions = this.toThreadOptions(opts);
    return sessionId
      ? this.codex.resumeThread(sessionId, threadOptions)
      : this.codex.startThread(threadOptions);
  }

  private resolveSessionOptions(opts: SessionOptions): ResolvedSessionOptions {
    return {
      model: opts.model ?? DEFAULT_MODEL,
      modelReasoningEffort: opts.modelReasoningEffort ?? DEFAULT_REASONING_EFFORT,
      workDir: opts.workDir,
      approvalPolicy: opts.approvalPolicy ?? DEFAULT_APPROVAL_POLICY,
      sandboxMode: opts.sandboxMode ?? DEFAULT_SANDBOX_MODE,
    };
  }

  private mergeSessionOptions(
    current: ResolvedSessionOptions,
    overrides: SessionOptions,
  ): ResolvedSessionOptions {
    return {
      model: overrides.model ?? current.model,
      modelReasoningEffort: overrides.modelReasoningEffort ?? current.modelReasoningEffort,
      workDir: overrides.workDir,
      approvalPolicy: overrides.approvalPolicy ?? current.approvalPolicy,
      sandboxMode: overrides.sandboxMode ?? current.sandboxMode,
    };
  }

  private sessionOptionsEqual(
    left: ResolvedSessionOptions,
    right: ResolvedSessionOptions,
  ): boolean {
    return left.model === right.model
      && left.modelReasoningEffort === right.modelReasoningEffort
      && left.workDir === right.workDir
      && left.approvalPolicy === right.approvalPolicy
      && left.sandboxMode === right.sandboxMode;
  }

  private shouldBypassApprovalsAndSandbox(opts: ResolvedSessionOptions): boolean {
    // Codex CLI still blocks dangerous shell commands like `rm` when using
    // approvalPolicy=never with danger-full-access. Treat that combination as
    // the user-facing "Full Access" preset and use the CLI bypass flag instead.
    return opts.approvalPolicy === "never" && opts.sandboxMode === "danger-full-access";
  }

  private toThreadOptions(opts: ResolvedSessionOptions): ThreadOptions {
    return {
      model: opts.model,
      workingDirectory: opts.workDir,
      skipGitRepoCheck: true,
      modelReasoningEffort: opts.modelReasoningEffort,
      sandboxMode: opts.sandboxMode,
      approvalPolicy: opts.approvalPolicy,
    };
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
