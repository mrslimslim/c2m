import {
  SLASH_CATALOG_CAPABILITY,
  type ModelReasoningEffort,
  type SessionConfig,
  type SlashCatalogMessage,
  type SlashCommandMeta,
  type SlashEffect,
  type SlashMenuNode,
} from "@codepilot/protocol";

const defaultConfig: SessionConfig = {
  model: "gpt-5.4",
  modelReasoningEffort: "medium",
  approvalPolicy: "on-request",
  sandboxMode: "workspace-write",
};

const models: Array<{ id: string; description: string }> = [
  { id: "gpt-5.3-codex", description: "Latest frontier agentic coding model." },
  { id: "gpt-5.4", description: "Latest frontier agentic coding model." },
  { id: "gpt-5.2-codex", description: "Frontier agentic coding model." },
  { id: "gpt-5.1-codex-max", description: "Codex-optimized flagship for deep and fast reasoning." },
  { id: "gpt-5.2", description: "Latest frontier model with improvements across knowledge and reasoning." },
  { id: "gpt-5.1-codex-mini", description: "Faster Codex-optimized model for lighter tasks." },
];

const reasoningLevels: Array<{
  id: ModelReasoningEffort;
  label: string;
  description: string;
}> = [
  { id: "low", label: "Low", description: "Fast responses with lighter reasoning" },
  { id: "medium", label: "Medium", description: "Balances speed and reasoning depth for everyday tasks" },
  { id: "high", label: "High", description: "Greater reasoning depth for complex problems" },
  { id: "xhigh", label: "Extra high", description: "Extra high reasoning depth for complex problems" },
];

const permissionPresets: Array<{
  id: string;
  label: string;
  description: string;
  approvalPolicy: NonNullable<SessionConfig["approvalPolicy"]>;
  sandboxMode: NonNullable<SessionConfig["sandboxMode"]>;
}> = [
  {
    id: "default",
    label: "Default",
    description:
      "Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files.",
    approvalPolicy: "on-request",
    sandboxMode: "workspace-write",
  },
  {
    id: "full-access",
    label: "Full Access",
    description:
      "Codex can edit files outside this workspace and access the internet without asking for approval. Exercise caution when using.",
    approvalPolicy: "never",
    sandboxMode: "danger-full-access",
  },
];

export function buildCodexSlashCatalog(adapterVersion?: string): SlashCatalogMessage {
  return {
    type: "slash_catalog",
    capability: SLASH_CATALOG_CAPABILITY,
    adapter: "codex",
    adapterVersion,
    catalogVersion: `codex-${adapterVersion ?? "fallback"}`,
    defaults: { ...defaultConfig },
    commands: [
      buildModelCommand(),
      disabledBridgeAction(
        "fast",
        "/fast",
        "Toggle Fast mode to enable fastest inference at 2X plan usage",
        "Fast mode is not exposed through the current bridge and Codex SDK integration yet.",
      ),
      buildPermissionsCommand(),
      disabledBridgeAction(
        "experimental",
        "/experimental",
        "Toggle experimental features",
        "Experimental feature toggles are not implemented in the bridge yet.",
      ),
      disabledBridgeAction(
        "skills",
        "/skills",
        "Use skills to improve how Codex performs specific tasks",
        "Skill inspection and application are not implemented in the bridge yet.",
      ),
      disabledBridgeAction(
        "review",
        "/review",
        "Review my current changes and find issues",
        "Slash-triggered bridge reviews are not implemented yet.",
      ),
      disabledBridgeAction(
        "rename",
        "/rename",
        "Rename the current thread",
        "Bridge-side thread renaming is not implemented yet.",
      ),
      {
        id: "new",
        label: "/new",
        description: "Start a new chat during a conversation",
        kind: "client_action",
        availability: "enabled",
        searchTerms: ["session", "thread", "chat"],
      },
    ],
  };
}

function buildModelCommand(): SlashCommandMeta {
  return {
    id: "model",
    label: "/model",
    description: "Choose what model and reasoning effort to use",
    kind: "workflow",
    availability: "enabled",
    searchTerms: ["models", "reasoning", "effort"],
    menu: {
      title: "Select Model and Effort",
      helperText: "Access legacy models by running codex -m <model_name> or in your config.toml",
      presentation: "list",
      options: models.map((model) => ({
        id: model.id,
        label: model.id,
        description: model.description,
        next: buildReasoningMenu(model.id),
      })),
    },
  };
}

function buildReasoningMenu(modelId: string): SlashMenuNode {
  return {
    title: `Select Reasoning Level for ${modelId}`,
    presentation: "list",
    options: reasoningLevels.map((level) => ({
      id: level.id,
      label: level.label,
      description: level.description,
      effects: [
        setSessionConfig("model", modelId),
        setSessionConfig("modelReasoningEffort", level.id),
      ],
    })),
  };
}

function buildPermissionsCommand(): SlashCommandMeta {
  return {
    id: "permissions",
    label: "/permissions",
    description: "Choose what Codex is allowed to do",
    kind: "workflow",
    availability: "enabled",
    searchTerms: ["approval", "sandbox", "permissions", "full access"],
    menu: {
      title: "Update Model Permissions",
      presentation: "list",
      options: permissionPresets.map((preset) => ({
        id: preset.id,
        label: preset.label,
        description: preset.description,
        effects: [
          setSessionConfig("approvalPolicy", preset.approvalPolicy),
          setSessionConfig("sandboxMode", preset.sandboxMode),
        ],
      })),
    },
  };
}

function disabledBridgeAction(
  id: string,
  label: string,
  description: string,
  disabledReason: string,
): SlashCommandMeta {
  return {
    id,
    label,
    description,
    kind: "bridge_action",
    availability: "disabled",
    disabledReason,
    searchTerms: [id],
  };
}

function setSessionConfig(field: Parameters<typeof buildSessionConfigEffect>[0], value: string): SlashEffect {
  return buildSessionConfigEffect(field, value);
}

function buildSessionConfigEffect(
  field: "model" | "modelReasoningEffort" | "approvalPolicy" | "sandboxMode",
  value: string,
): SlashEffect {
  return {
    type: "set_session_config",
    field,
    value,
  };
}
