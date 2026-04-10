import type {
  SlashActionMessage,
  SlashActionResultMessage,
  SlashCatalogMessage,
} from "@codepilot/protocol";

export function dispatchSlashAction(
  message: SlashActionMessage,
  catalog: SlashCatalogMessage,
): SlashActionResultMessage {
  const command = catalog.commands.find((candidate) => candidate.id === message.commandId);

  if (!command) {
    return {
      type: "slash_action_result",
      commandId: message.commandId,
      ok: false,
      message: `Unknown slash command: ${message.commandId}`,
    };
  }

  if (command.availability !== "enabled") {
    return {
      type: "slash_action_result",
      commandId: message.commandId,
      ok: false,
      message: command.disabledReason ?? `Command ${command.label} is unavailable.`,
    };
  }

  switch (command.kind) {
    case "client_action":
      return {
        type: "slash_action_result",
        commandId: message.commandId,
        ok: false,
        message: `${command.label} must be handled by the client.`,
      };
    case "workflow":
      return {
        type: "slash_action_result",
        commandId: message.commandId,
        ok: false,
        message: `${command.label} is a workflow and does not require bridge execution.`,
      };
    case "insert_text":
      return {
        type: "slash_action_result",
        commandId: message.commandId,
        ok: false,
        message: `${command.label} should be inserted by the client composer.`,
      };
    case "bridge_action":
      return {
        type: "slash_action_result",
        commandId: message.commandId,
        ok: false,
        message: `${command.label} is not implemented by the bridge yet.`,
      };
  }
}
