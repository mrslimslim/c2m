import {
  SLASH_CATALOG_CAPABILITY,
  type SlashCatalogMessage,
} from "@codepilot/protocol";
import type { SessionInfo } from "@codepilot/protocol";
import { buildCodexSlashCatalog } from "./codex.js";

type AgentType = SessionInfo["agentType"];

export interface BuildSlashCatalogOptions {
  adapter: AgentType;
  adapterVersion?: string;
}

export function buildSlashCatalog(options: BuildSlashCatalogOptions): SlashCatalogMessage {
  switch (options.adapter) {
    case "codex":
      return buildCodexSlashCatalog(options.adapterVersion);
    case "claude":
      return {
        type: "slash_catalog",
        capability: SLASH_CATALOG_CAPABILITY,
        adapter: "claude",
        adapterVersion: options.adapterVersion,
        catalogVersion: `claude-${options.adapterVersion ?? "fallback"}`,
        defaults: {},
        commands: [],
      };
  }
}
