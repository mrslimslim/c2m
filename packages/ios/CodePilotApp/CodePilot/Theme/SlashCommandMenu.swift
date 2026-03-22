import SwiftUI
import CodePilotFeatures
import CodePilotProtocol

struct SlashCommandMenu: View {
    @Binding var workflow: SlashWorkflowState
    @Binding var config: SessionConfig
    @Binding var inputText: String

    let sessionID: String?
    let onBridgeAction: (SlashActionMessage) -> Void
    let onClientAction: (String) -> Void
    let onDismiss: () -> Void

    private var projection: SlashWorkflowProjection? {
        workflow.projection(query: inputText, config: config)
    }

    @ViewBuilder
    var body: some View {
        if let projection {
            VStack(alignment: .leading, spacing: 0) {
                header(projection: projection)
                if let helperText = projection.helperText {
                    Text(helperText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                ScrollView(.vertical, showsIndicators: true) {
                    menuContent(projection: projection)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                .frame(maxHeight: 320)
                .scrollBounceBehavior(.basedOnSize)
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

    private func header(projection: SlashWorkflowProjection) -> some View {
        HStack(spacing: 8) {
            if projection.canGoBack {
                Button {
                    withAnimation(.spring(duration: 0.24, bounce: 0.15)) {
                        stepBack()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.systemGray5), in: Circle())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(projection.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(projection.canGoBack ? "Select an option" : "Commands")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            Spacer()

            Button {
                withAnimation(.spring(duration: 0.22, bounce: 0.12)) {
                    dismissMenu(clearInput: true)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.quaternary)
                    .padding(5)
                    .background(Color(.systemGray5), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func menuContent(projection: SlashWorkflowProjection) -> some View {
        switch projection.presentation {
        case .list:
            VStack(spacing: 8) {
                ForEach(projection.entries) { entry in
                    entryRow(entry)
                }
            }
        case .grid:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(projection.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: SlashWorkflowEntry) -> some View {
        Button {
            withAnimation(.spring(duration: 0.24, bounce: 0.16)) {
                activate(entry)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: entry))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(entry.isEnabled ? CPTheme.accent : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        (entry.isEnabled ? CPTheme.accentMuted : Color(.systemGray5)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(entry.label)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                            .multilineTextAlignment(.leading)

                        if entry.isCurrent {
                            stateBadge("Current", tint: CPTheme.accent)
                        }
                        if entry.isDefault && shouldShowDefaultBadge(for: entry) {
                            stateBadge("Default", tint: Color(.systemGray))
                        }
                        ForEach(entry.badges, id: \.self) { badge in
                            stateBadge(badgeTitle(for: badge), tint: badgeTint(for: badge))
                        }
                    }

                    if let description = entry.description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    if let disabledReason = entry.disabledReason, !entry.isEnabled {
                        Text(disabledReason)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    if entry.hasNext {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    } else if entry.isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CPTheme.accent)
                    }
                }
                .frame(minWidth: 18)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(entry.isEnabled ? Color(.systemBackground).opacity(0.72) : Color(.systemGray6).opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        entry.isCurrent ? CPTheme.accent.opacity(0.26) : Color(.separator).opacity(0.22),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!entry.isEnabled)
    }

    private func stateBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func shouldShowDefaultBadge(for entry: SlashWorkflowEntry) -> Bool {
        entry.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "default"
    }

    private func activate(_ entry: SlashWorkflowEntry) {
        var nextWorkflow = workflow
        let result: SlashWorkflowSelectionResult

        switch entry.kind {
        case .command:
            result = nextWorkflow.selectCommand(
                id: entry.id,
                sessionId: sessionID,
                config: &config,
                inputText: &inputText
            )
        case .option:
            result = nextWorkflow.selectOption(
                id: entry.id,
                sessionId: sessionID,
                config: &config,
                inputText: &inputText
            )
        }

        workflow = nextWorkflow
        handle(result)
    }

    private func handle(_ result: SlashWorkflowSelectionResult) {
        switch result {
        case .none, .enteredMenu:
            return
        case .completed:
            if inputText.hasPrefix("/") {
                inputText = ""
            }
            workflow.reset()
            onDismiss()
        case let .bridgeAction(message):
            if inputText.hasPrefix("/") {
                inputText = ""
            }
            workflow.reset()
            onBridgeAction(message)
            onDismiss()
        case let .clientAction(commandId):
            if inputText.hasPrefix("/") {
                inputText = ""
            }
            workflow.reset()
            onClientAction(commandId)
            onDismiss()
        }
    }

    private func stepBack() {
        var nextWorkflow = workflow
        nextWorkflow.goBack()
        workflow = nextWorkflow
        if !workflow.canGoBack {
            inputText = "/"
        }
    }

    private func dismissMenu(clearInput: Bool) {
        workflow.reset()
        if clearInput {
            inputText = ""
        }
        onDismiss()
    }

    private func symbol(for entry: SlashWorkflowEntry) -> String {
        switch entry.kind {
        case let .command(kind):
            switch kind {
            case .workflow:
                if entry.id == "model" { return "cpu" }
                if entry.id == "permissions" { return "slider.horizontal.3" }
                return "point.topleft.down.curvedto.point.bottomright.up"
            case .bridgeAction:
                return "bolt.badge.shieldcheckmark"
            case .clientAction:
                return "plus.bubble"
            case .insertText:
                return "text.insert"
            }
        case .option:
            return entry.hasNext ? "square.stack.3d.up" : "circle.fill"
        }
    }

    private func badgeTitle(for badge: SlashOptionBadge) -> String {
        switch badge {
        case .default:
            return "Default"
        case .recommended:
            return "Recommended"
        case .experimental:
            return "Experimental"
        }
    }

    private func badgeTint(for badge: SlashOptionBadge) -> Color {
        switch badge {
        case .default:
            return Color(.systemGray)
        case .recommended:
            return CPTheme.accent
        case .experimental:
            return Color.orange
        }
    }
}

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
        if let model = config.model {
            result.append(ConfigItem(key: "model", icon: "cpu", value: model, keyPath: \.model))
        }
        if let effort = config.modelReasoningEffort {
            result.append(
                ConfigItem(
                    key: "reasoning",
                    icon: "brain.head.profile",
                    value: effort,
                    keyPath: \.modelReasoningEffort
                )
            )
        }
        if let approval = config.approvalPolicy {
            result.append(
                ConfigItem(
                    key: "approval",
                    icon: "hand.raised",
                    value: approval,
                    keyPath: \.approvalPolicy
                )
            )
        }
        if let sandbox = config.sandboxMode {
            result.append(
                ConfigItem(
                    key: "sandbox",
                    icon: "lock.shield",
                    value: sandbox,
                    keyPath: \.sandboxMode
                )
            )
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
