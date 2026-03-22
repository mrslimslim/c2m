#!/usr/bin/env node

/**
 * CodePilot Bridge CLI — mobile command center for AI coding agents.
 *
 * Usage:
 *   npx codepilot                     # auto-detect agent, LAN mode with auto port
 *   npx codepilot --agent codex       # use Codex
 *   npx codepilot --agent claude      # use Claude Code
 *   npx codepilot --port 19260        # custom port
 *   npx codepilot --port auto         # auto-select an available port
 *   npx codepilot --advertised-host codepilot.tailnet.ts.net  # stable pairing host
 *   npx codepilot --dir /path/to/proj # project directory
 *   npx codepilot --tunnel            # expose via Cloudflare Tunnel
 *   npx codepilot --relay             # use Relay (cross-network)
 *   npx codepilot --relay-url https://custom-relay.com  # custom Relay
 */

import { Command } from "commander";
import { resolve } from "node:path";
import { Bridge } from "../bridge.js";
import { log } from "../utils/logger.js";

function parsePort(value: string): number {
  if (value === "auto") {
    return 0;
  }

  const port = Number.parseInt(value, 10);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`Invalid port: ${value}. Expected a number between 0 and 65535, or "auto".`);
  }

  return port;
}

const program = new Command();

program
  .name("codepilot")
  .description("Mobile command center for AI coding agents")
  .version("0.1.0")
  .option("-a, --agent <type>", "Agent type: codex | claude | auto", "auto")
  .option("-p, --port <value>", "WebSocket port (default: auto)", "auto")
  .option("-H, --host <address>", "Bind address (use :: for IPv6 dual-stack)", "0.0.0.0")
  .option("--advertised-host <address>", "Override the host embedded in QR/pairing output")
  .option("-d, --dir <path>", "Working directory", ".")
  .option("--tunnel", "Expose via Cloudflare Tunnel (requires cloudflared)")
  .option("--relay", "Use Relay server for cross-network connections")
  .option("--relay-url <url>", "Custom Relay server URL")
  .action(
    async (opts: {
      agent: string;
      port: string;
      host: string;
      advertisedHost?: string;
      dir: string;
      tunnel?: boolean;
      relay?: boolean;
      relayUrl?: string;
    }) => {
      const agent = opts.agent as "codex" | "claude" | "auto";
      const port = parsePort(opts.port);
      const host = opts.host;
      const advertisedHost = opts.advertisedHost;
      const workDir = resolve(opts.dir);
      const relay = opts.relay || !!opts.relayUrl;

      console.log();
      console.log("  +======================================+");
      console.log("  |   CodePilot Bridge v0.1.0             |");
      console.log("  |   Mobile AI Coding Command Center     |");
      console.log("  +======================================+");
      console.log();

      log.info(`Working directory: ${workDir}`);
      log.info(`Agent: ${agent}`);
      if (relay) {
        log.info(`Mode: Relay (cross-network)`);
        if (opts.relayUrl) {
          log.info(`Relay URL: ${opts.relayUrl}`);
        }
      } else if (opts.tunnel) {
        log.info(`Mode: Tunnel (Cloudflare)`);
      } else {
        log.info(`Mode: LAN (${port === 0 ? "port auto" : `port ${port}`})`);
        if (advertisedHost) {
          log.info(`Advertised host: ${advertisedHost}`);
        }
      }
      console.log();

      try {
        const bridge = new Bridge({
          agent,
          port,
          host,
          advertisedHost,
          workDir,
          tunnel: opts.tunnel,
          relay,
          relayUrl: opts.relayUrl,
        });
        await bridge.start();
      } catch (err) {
        log.error(`Failed to start bridge: ${err}`);
        process.exit(1);
      }
    },
  );

program.parse();
