#!/usr/bin/env node

/**
 * CodePilot Bridge CLI — mobile command center for AI coding agents.
 *
 * Usage:
 *   npx codepilot                     # auto-detect agent, Tunnel mode by default
 *   npx codepilot --agent codex       # use Codex
 *   npx codepilot --agent claude      # use Claude Code
 *   npx codepilot --dir /path/to/proj # project directory
 *   npx codepilot --tunnel            # compatibility flag; Tunnel is already default
 */

import { Command } from "commander";
import { resolve } from "node:path";
import { Bridge } from "../bridge.js";
import { log } from "../utils/logger.js";

const program = new Command();

program
  .name("codepilot")
  .description("Mobile command center for AI coding agents via Cloudflare Tunnel")
  .version("0.1.0")
  .option("-a, --agent <type>", "Agent type: codex | claude | auto", "auto")
  .option("-d, --dir <path>", "Working directory", ".")
  .option("--tunnel", "Tunnel mode (default; kept for compatibility)")
  .action(
    async (opts: {
      agent: string;
      dir: string;
      tunnel?: boolean;
    }) => {
      const agent = opts.agent as "codex" | "claude" | "auto";
      const workDir = resolve(opts.dir);

      console.log();
      console.log("  +======================================+");
      console.log("  |   CodePilot Bridge v0.1.0             |");
      console.log("  |   Mobile AI Coding Command Center     |");
      console.log("  +======================================+");
      console.log();

      log.info(`Working directory: ${workDir}`);
      log.info(`Agent: ${agent}`);
      log.info(`Mode: Tunnel (Cloudflare, default)`);
      console.log();

      try {
        const bridge = new Bridge({
          agent,
          port: 0,
          host: "127.0.0.1",
          workDir,
        });
        await bridge.start();
      } catch (err) {
        log.error(`Failed to start bridge: ${err}`);
        process.exit(1);
      }
    },
  );

program.parse();
