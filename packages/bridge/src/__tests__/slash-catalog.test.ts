import test from "node:test";
import assert from "node:assert/strict";
import { SLASH_CATALOG_CAPABILITY } from "@codepilot/protocol";
import { buildSlashCatalog } from "../slash/catalog.js";
import { detectAdapterVersion, parseCodexCliVersion } from "../slash/version.js";

test("buildSlashCatalog returns the codex command set for codex-cli 0.116.0", () => {
  const catalog = buildSlashCatalog({
    adapter: "codex",
    adapterVersion: "0.116.0",
  });

  assert.equal(catalog.type, "slash_catalog");
  assert.equal(catalog.capability, SLASH_CATALOG_CAPABILITY);
  assert.equal(catalog.adapter, "codex");
  assert.equal(catalog.adapterVersion, "0.116.0");
  assert.equal(catalog.catalogVersion, "codex-0.116.0");
  assert.deepEqual(catalog.commands.map((command) => command.id), [
    "model",
    "fast",
    "permissions",
    "experimental",
    "skills",
    "review",
    "rename",
    "new",
  ]);
});

test("buildSlashCatalog exposes a nested /model workflow with reasoning effort leaves", () => {
  const catalog = buildSlashCatalog({
    adapter: "codex",
    adapterVersion: "0.116.0",
  });

  const model = catalog.commands.find((command) => command.id === "model");
  assert.ok(model, "expected /model command");
  assert.equal(model.kind, "workflow");
  assert.equal(model.availability, "enabled");
  assert.equal(model.menu?.title, "Select Model and Effort");
  assert.match(
    model.menu?.helperText ?? "",
    /Access legacy models by running codex -m <model_name>/,
  );

  const gpt54 = model.menu?.options.find((option) => option.id === "gpt-5.4");
  assert.ok(gpt54, "expected gpt-5.4 model option");
  assert.ok(gpt54.next, "expected second-level reasoning menu");
  assert.equal(gpt54.next.title, "Select Reasoning Level for gpt-5.4");

  const xhigh = gpt54.next.options.find((option) => option.id === "xhigh");
  assert.ok(xhigh, "expected xhigh reasoning option");
  assert.deepEqual(xhigh.effects, [
    { type: "set_session_config", field: "model", value: "gpt-5.4" },
    { type: "set_session_config", field: "modelReasoningEffort", value: "xhigh" },
  ]);
});

test("buildSlashCatalog exposes /permissions as permission presets for codex-cli 0.116.0", () => {
  const catalog = buildSlashCatalog({
    adapter: "codex",
    adapterVersion: "0.116.0",
  });

  const permissions = catalog.commands.find((command) => command.id === "permissions");
  assert.ok(permissions, "expected /permissions command");
  assert.equal(permissions.kind, "workflow");
  assert.equal(permissions.availability, "enabled");
  assert.equal(permissions.menu?.title, "Update Model Permissions");
  assert.deepEqual(
    permissions.menu?.options.map((option) => option.id),
    ["default", "full-access"],
  );

  const defaultPreset = permissions.menu?.options.find((option) => option.id === "default");
  assert.ok(defaultPreset, "expected Default permission preset");
  assert.deepEqual(defaultPreset.effects, [
    { type: "set_session_config", field: "approvalPolicy", value: "on-request" },
    { type: "set_session_config", field: "sandboxMode", value: "workspace-write" },
  ]);

  const fullAccessPreset = permissions.menu?.options.find((option) => option.id === "full-access");
  assert.ok(fullAccessPreset, "expected Full Access permission preset");
  assert.deepEqual(fullAccessPreset.effects, [
    { type: "set_session_config", field: "approvalPolicy", value: "never" },
    { type: "set_session_config", field: "sandboxMode", value: "danger-full-access" },
  ]);
});

test("buildSlashCatalog marks unsupported bridge actions as disabled with reasons", () => {
  const catalog = buildSlashCatalog({
    adapter: "codex",
    adapterVersion: "0.116.0",
  });

  const fast = catalog.commands.find((command) => command.id === "fast");
  const experimental = catalog.commands.find((command) => command.id === "experimental");
  const skills = catalog.commands.find((command) => command.id === "skills");
  const review = catalog.commands.find((command) => command.id === "review");
  const rename = catalog.commands.find((command) => command.id === "rename");
  const newCommand = catalog.commands.find((command) => command.id === "new");

  assert.equal(fast?.availability, "disabled");
  assert.match(fast?.disabledReason ?? "", /not exposed/i);
  assert.equal(experimental?.availability, "disabled");
  assert.match(experimental?.disabledReason ?? "", /not implemented/i);
  assert.equal(skills?.availability, "disabled");
  assert.match(skills?.disabledReason ?? "", /not implemented/i);
  assert.equal(review?.availability, "disabled");
  assert.match(review?.disabledReason ?? "", /not implemented/i);
  assert.equal(rename?.availability, "disabled");
  assert.match(rename?.disabledReason ?? "", /not implemented/i);
  assert.equal(newCommand?.kind, "client_action");
  assert.equal(newCommand?.availability, "enabled");
});

test("parseCodexCliVersion extracts a semantic version from codex --version output", () => {
  assert.equal(parseCodexCliVersion("codex-cli 0.116.0"), "0.116.0");
  assert.equal(parseCodexCliVersion("Codex CLI version: 1.2.3"), "1.2.3");
  assert.equal(parseCodexCliVersion("something unexpected"), undefined);
});

test("detectAdapterVersion returns undefined when the version probe fails", async () => {
  const version = await detectAdapterVersion("codex", {
    runVersionCommand: async () => {
      throw new Error("codex unavailable");
    },
  });

  assert.equal(version, undefined);
});

test("detectAdapterVersion probes codex with a version command and normalizes the result", async () => {
  const calls: string[][] = [];
  const version = await detectAdapterVersion("codex", {
    runVersionCommand: async (command, args) => {
      calls.push([command, ...args]);
      return "codex-cli 0.116.0";
    },
  });

  assert.equal(version, "0.116.0");
  assert.deepEqual(calls, [["codex", "--version"]]);
});
