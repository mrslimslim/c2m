/**
 * CodePilot Relay — Cloudflare Worker entry point.
 *
 * Routes:
 * - GET /ws?device=bridge|phone&channel=xxx  → WebSocket connection to channel DO
 * - GET /health                              → Health check
 *
 * No user accounts. No registration. Just ephemeral relay channels.
 */

export { Channel } from "./channel.js";

interface Env {
  CHANNEL: DurableObjectNamespace;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ status: "ok", service: "codepilot-relay" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // WebSocket relay
    if (url.pathname === "/ws") {
      const channel = url.searchParams.get("channel");
      const device = url.searchParams.get("device");

      if (!channel || !device) {
        return new Response(
          JSON.stringify({ error: "Missing 'channel' and/or 'device' query parameters" }),
          { status: 400, headers: { "Content-Type": "application/json" } },
        );
      }

      if (device !== "bridge" && device !== "phone") {
        return new Response(
          JSON.stringify({ error: "device must be 'bridge' or 'phone'" }),
          { status: 400, headers: { "Content-Type": "application/json" } },
        );
      }

      // Route to the Durable Object for this channel
      const channelId = env.CHANNEL.idFromName(channel);
      const stub = env.CHANNEL.get(channelId);
      return stub.fetch(request);
    }

    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
