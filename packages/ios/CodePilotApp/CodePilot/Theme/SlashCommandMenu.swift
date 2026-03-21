import SwiftUI
import CodePilotProtocol

// MARK: - Slash Command Definitions

struct SlashCommand: Identifiable {
    let id: String
    let label: String
    let icon: String
    let description: String
    let options: [SlashOption]
    let keyPath: WritableKeyPath<SessionConfig, String?>
}

struct SlashOption: Identifiable {
    let id: String
    let label: String
    let subtitle: String?

    init(_ value: String, label: String? = nil, subtitle: String? = nil) {
        self.id = value
        self.label = label ?? value
        self.subtitle = subtitle
    }
}

enum SlashCommands {
    static let all: [SlashCommand] = [
        SlashCommand(
            id: "model",
            label: "Model",
            icon: "cpu",
            description: "Choose the AI model",
            options: [
                SlashOption("gpt-5.4", subtitle: "Latest"),
                SlashOption("gpt-4.1", subtitle: "Fast"),
                SlashOption("o4-mini", subtitle: "Reasoning"),
                SlashOption("o3", subtitle: "Deep"),
                SlashOption("codex-mini", subtitle: "Light"),
            ],
            keyPath: \.model
        ),
        SlashCommand(
            id: "approval",
            label: "Approval",
            icon: "hand.raised",
            description: "When to ask for permission",
            options: [
                SlashOption("never", subtitle: "Auto-approve all"),
                SlashOption("on-request", subtitle: "Ask before actions"),
                SlashOption("on-failure", subtitle: "Ask on errors"),
                SlashOption("untrusted", subtitle: "Ask for untrusted"),
            ],
            keyPath: \.approvalPolicy
        ),
        SlashCommand(
            id: "sandbox",
            label: "Sandbox",
            icon: "lock.shield",
            description: "File system access level",
            options: [
                SlashOption("read-only", label: "Read Only", subtitle: "Safe"),
                SlashOption("workspace-write", label: "Workspace", subtitle: "Default"),
                SlashOption("danger-full-access", label: "Full Access", subtitle: "Unrestricted"),
            ],
            keyPath: \.sandboxMode
        ),
    ]

    static func matching(_ query: String) -> [SlashCommand] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q == "/" { return all }
        let stripped = q.hasPrefix("/") ? String(q.dropFirst()) : q
        if stripped.isEmpty { return all }
        return all.filter { $0.id.hasPrefix(stripped) || $0.label.lowercased().hasPrefix(stripped) }
    }
}

// MARK: - Slash Command Menu

struct SlashCommandMenu: View {
    @Binding var config: SessionConfig
    @Binding var inputText: String
    let onDismiss: () -> Void

    private var matchingCommands: [SlashCommand] {
        SlashCommands.matching(inputText)
    }

    @ViewBuilder
    var body: some View {
        if !matchingCommands.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "slash.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("Commands")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Button {
                        inputText = ""
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.quaternary)
                            .padding(5)
                            .background(Color(.systemGray5), in: Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

                ForEach(matchingCommands) { cmd in
                    commandSection(cmd)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
                    .shadow(color: .black.opacity(0.03), radius: 4, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    private func commandSection(_ cmd: SlashCommand) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Command label
            HStack(spacing: 8) {
                Image(systemName: cmd.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPTheme.accent)
                    .frame(width: 22, height: 22)
                    .background(CPTheme.accentMuted, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("/\(cmd.id)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text(cmd.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)

            // Option pills — all visible, single tap to select
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cmd.options) { option in
                        let isSelected = config[keyPath: cmd.keyPath] == option.id
                        optionPill(option: option, isSelected: isSelected) {
                            withAnimation(.spring(duration: 0.25, bounce: 0.2)) {
                                config[keyPath: cmd.keyPath] = isSelected ? nil : option.id
                                inputText = ""
                                onDismiss()
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8)
    }

    private func optionPill(option: SlashOption, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(option.label)
                    .font(.system(size: 12, weight: .semibold))

                if let subtitle = option.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .opacity(isSelected ? 0.8 : 0.6)
                }
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(CPTheme.accent) : AnyShapeStyle(Color(.systemGray5)),
                         in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Config Chips

struct ConfigChips: View {
    @Binding var config: SessionConfig

    var body: some View {
        let items = activeItems
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.key) { item in
                        chip(item: item)
                    }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    private struct ConfigItem {
        let key: String
        let icon: String
        let value: String
        let keyPath: WritableKeyPath<SessionConfig, String?>
    }

    private var activeItems: [ConfigItem] {
        var result: [ConfigItem] = []
        if let m = config.model {
            result.append(ConfigItem(key: "model", icon: "cpu", value: m, keyPath: \.model))
        }
        if let a = config.approvalPolicy {
            result.append(ConfigItem(key: "approval", icon: "hand.raised", value: a, keyPath: \.approvalPolicy))
        }
        if let s = config.sandboxMode {
            result.append(ConfigItem(key: "sandbox", icon: "lock.shield", value: s, keyPath: \.sandboxMode))
        }
        return result
    }

    private func chip(item: ConfigItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(CPTheme.accent)

            Text(item.value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CPTheme.accent)

            Button {
                withAnimation(.spring(duration: 0.25, bounce: 0.2)) {
                    config[keyPath: item.keyPath] = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(CPTheme.accent.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .background(CPTheme.accent.opacity(0.1), in: Circle())
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(CPTheme.accentMuted, in: Capsule())
        .overlay(Capsule().stroke(CPTheme.accent.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - Slash Hint Button

/// Small "/" button placed near input field to hint at slash commands.
struct SlashHintButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("/")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .frame(width: 40, height: 40)
        .buttonStyle(.plain)
    }
}
