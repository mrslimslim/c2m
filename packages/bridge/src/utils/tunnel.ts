/**
 * Cloudflare Tunnel — launches `cloudflared` to expose a local port to the internet.
 *
 * Uses the free "quick tunnel" feature (no account required).
 * Parses the tunnel URL from cloudflared's stderr output.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { log } from "./logger.js";

export interface TunnelResult {
  /** Public tunnel URL, e.g. "https://xxx-xxx.trycloudflare.com" */
  url: string;
  /** The tunnel URL converted to wss:// for WebSocket */
  wsUrl: string;
  /** Kill the cloudflared process */
  stop: () => void;
}

/**
 * Start a Cloudflare quick tunnel pointing to a local port.
 * Returns the public URL once the tunnel is established.
 */
export function startTunnel(localPort: number): Promise<TunnelResult> {
  return new Promise((resolve, reject) => {
    let child: ChildProcess;
    let settled = false;

    try {
      child = spawn("cloudflared", [
        "tunnel",
        "--url", `http://localhost:${localPort}`,
        "--protocol", "http2",
      ], {
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (err) {
      reject(
        new Error(
          "Failed to spawn cloudflared. Is it installed? Run: brew install cloudflared",
        ),
      );
      return;
    }

    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true;
        child.kill();
        reject(new Error("Timed out waiting for cloudflared tunnel URL (30s)"));
      }
    }, 30000);

    // cloudflared prints the tunnel URL to stderr
    const urlRegex = /https:\/\/[a-zA-Z0-9-]+\.trycloudflare\.com/;
    let buffer = "";

    const handleData = (data: Buffer) => {
      const text = data.toString();
      buffer += text;

      // Log cloudflared output for debugging
      for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (trimmed) {
          log.info(`[cloudflared] ${trimmed}`);
        }
      }

      const match = buffer.match(urlRegex);
      if (match && !settled) {
        settled = true;
        clearTimeout(timeout);
        const httpsUrl = match[0];
        const wsUrl = httpsUrl.replace("https://", "wss://");
        resolve({
          url: httpsUrl,
          wsUrl,
          stop: () => {
            child.kill();
          },
        });
      }
    };

    child.stderr?.on("data", handleData);
    child.stdout?.on("data", handleData);

    child.on("error", (err) => {
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        reject(
          new Error(
            `cloudflared error: ${err.message}. Is it installed? Run: brew install cloudflared`,
          ),
        );
      }
    });

    child.on("exit", (code) => {
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        reject(new Error(`cloudflared exited with code ${code} before establishing tunnel`));
      }
    });
  });
}
