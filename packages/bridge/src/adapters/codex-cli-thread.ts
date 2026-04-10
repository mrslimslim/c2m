import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import type { ThreadEvent, ThreadOptions, TurnOptions } from "@openai/codex-sdk";

export interface CodexThreadLike {
  runStreamed(
    input: string,
    turnOptions?: TurnOptions,
  ): Promise<{ events: AsyncGenerator<ThreadEvent> }>;
}

export class CodexCliThread implements CodexThreadLike {
  private threadId: string | null;

  constructor(
    private readonly options: ThreadOptions,
    threadId: string | null,
    private readonly bypassApprovalsAndSandbox: boolean,
  ) {
    this.threadId = threadId;
  }

  async runStreamed(
    input: string,
    turnOptions: TurnOptions = {},
  ): Promise<{ events: AsyncGenerator<ThreadEvent> }> {
    if (turnOptions.outputSchema !== undefined) {
      throw new Error("CodexCliThread does not support outputSchema");
    }

    return {
      events: this.runStreamedInternal(input, turnOptions),
    };
  }

  private async *runStreamedInternal(
    input: string,
    turnOptions: TurnOptions,
  ): AsyncGenerator<ThreadEvent> {
    const commandArgs = ["exec", "--experimental-json"];

    if (this.bypassApprovalsAndSandbox) {
      commandArgs.push("--dangerously-bypass-approvals-and-sandbox");
    }

    if (this.options.model) {
      commandArgs.push("--model", this.options.model);
    }
    if (this.options.sandboxMode && !this.bypassApprovalsAndSandbox) {
      commandArgs.push("--sandbox", this.options.sandboxMode);
    }
    if (this.options.workingDirectory) {
      commandArgs.push("--cd", this.options.workingDirectory);
    }
    if (this.options.additionalDirectories?.length) {
      for (const dir of this.options.additionalDirectories) {
        commandArgs.push("--add-dir", dir);
      }
    }
    if (this.options.skipGitRepoCheck) {
      commandArgs.push("--skip-git-repo-check");
    }
    if (this.options.modelReasoningEffort) {
      commandArgs.push("--config", `model_reasoning_effort="${this.options.modelReasoningEffort}"`);
    }
    if (this.options.networkAccessEnabled !== undefined) {
      commandArgs.push(
        "--config",
        `sandbox_workspace_write.network_access=${this.options.networkAccessEnabled}`,
      );
    }
    if (this.options.webSearchMode) {
      commandArgs.push("--config", `web_search="${this.options.webSearchMode}"`);
    } else if (this.options.webSearchEnabled === true) {
      commandArgs.push("--config", 'web_search="live"');
    } else if (this.options.webSearchEnabled === false) {
      commandArgs.push("--config", 'web_search="disabled"');
    }
    if (this.options.approvalPolicy && !this.bypassApprovalsAndSandbox) {
      commandArgs.push("--config", `approval_policy="${this.options.approvalPolicy}"`);
    }
    if (this.threadId) {
      commandArgs.push("resume", this.threadId);
    }

    const child = spawn("codex", commandArgs, {
      env: {
        ...process.env,
        CODEX_INTERNAL_ORIGINATOR_OVERRIDE: "codepilot_bridge",
      },
      signal: turnOptions.signal,
    });

    let spawnError: unknown = null;
    child.once("error", (error) => {
      spawnError = error;
    });

    if (!child.stdin) {
      child.kill();
      throw new Error("Codex child process has no stdin");
    }
    child.stdin.write(input);
    child.stdin.end();

    if (!child.stdout) {
      child.kill();
      throw new Error("Codex child process has no stdout");
    }

    const stderrChunks: Buffer[] = [];
    child.stderr?.on("data", (chunk: Buffer) => {
      stderrChunks.push(chunk);
    });

    const exitPromise = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
      child.once("exit", (code, signal) => {
        resolve({ code, signal });
      });
    });

    const rl = createInterface({
      input: child.stdout,
      crlfDelay: Infinity,
    });

    try {
      for await (const line of rl) {
        let parsed: ThreadEvent;
        try {
          parsed = JSON.parse(line) as ThreadEvent;
        } catch (error) {
          throw new Error(`Failed to parse Codex event: ${line}`, { cause: error });
        }

        if (parsed.type === "thread.started") {
          this.threadId = parsed.thread_id;
        }

        yield parsed;
      }

      if (spawnError) {
        throw spawnError;
      }

      const { code, signal } = await exitPromise;
      if (code !== 0 || signal) {
        const detail = signal ? `signal ${signal}` : `code ${code ?? 1}`;
        const stderr = Buffer.concat(stderrChunks).toString("utf8");
        throw new Error(`Codex CLI exited with ${detail}: ${stderr}`);
      }
    } finally {
      rl.close();
      child.removeAllListeners();
      if (!child.killed) {
        try {
          child.kill();
        } catch {
          // Ignore cleanup failures.
        }
      }
    }
  }
}
