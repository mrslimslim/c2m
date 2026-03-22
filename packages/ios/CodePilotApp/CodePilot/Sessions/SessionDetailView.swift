import SwiftUI
import CodePilotCore
import CodePilotFeatures
import CodePilotProtocol
#if canImport(UIKit)
import UIKit
#endif

struct SessionDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let sessionID: String

    @State private var draft: String = ""
    @State private var errorMessage: String?
    @State private var sessionConfig = SessionConfig()
    @State private var slashWorkflow = SlashWorkflowState()
    @State private var showSlashMenu = false
    @State private var startsNewSession = false
    @State private var showDeleteConfirmation = false
    @State private var showCopiedConversation = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    // Session header card
                    if let session = session {
                        sessionHeader(session)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }

                    // Timeline events
                    if timeline.isEmpty {
                        emptyTimeline
                            .padding(.top, 60)
                    } else {
                        ForEach(Array(timeline.enumerated()), id: \.offset) { index, item in
                            TimelineCellView(
                                sessionID: sessionID,
                                item: item,
                                agentType: session?.agentType,
                                previousItem: index > 0 ? timeline[index - 1] : nil,
                                onCopy: copyToPasteboard
                            )
                            .padding(.horizontal)
                            .id(index)
                        }
                    }

                    // Files section (inline)
                    if !files.isEmpty {
                        filesSection
                            .padding(.horizontal)
                    }

                    // Spacer for bottom composer
                    Color.clear.frame(height: 80)
                        .id("bottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: timeline.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(navigationTitle)
                        .font(.subheadline.weight(.semibold))
                    if let session = session {
                        HStack(spacing: 4) {
                            Text(CPTheme.agentLabel(session.agentType))
                            Text("·")
                            Text(CPTheme.stateLabel(session.state))
                                .foregroundStyle(CPTheme.stateColor(session.state))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        copyConversationTranscript()
                    } label: {
                        if showCopiedConversation {
                            Label("Copy Conversation", systemImage: "checkmark")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(CPTheme.success)
                        } else {
                            Label("Copy Conversation", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(conversationTranscript.isEmpty)

                    Button {
                        prepareForModalTransition {
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(CPTheme.error)
                    }
                    .disabled(session == nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // Typing indicator
                if let session = session, isBusy(session.state) {
                    TypingIndicator(state: session.state, agentType: session.agentType)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                commandComposer
            }
        }
        .onAppear {
            appModel.selectSession(id: sessionID)
            draft = viewModel.draft
            slashWorkflow.updateCatalog(slashCatalog)
        }
        .onChange(of: slashCatalog) { _, newCatalog in
            slashWorkflow.updateCatalog(newCatalog)
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Delete Session?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    // MARK: - Session Header

    private func sessionHeader(_ session: SessionInfo) -> some View {
        HStack(spacing: 12) {
            AgentAvatar(agentType: session.agentType, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(CPTheme.shortPath(session.workDir))
                    .font(.subheadline.weight(.semibold))
                Text(session.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            StateBadge(state: session.state)
        }
        .glassCard()
    }

    // MARK: - Empty State

    private var emptyTimeline: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No events yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Send a command to get started")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Files Section

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FILES")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(files, id: \.path) { file in
                        NavigationLink {
                            FileViewerView(file: file)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(CPTheme.accent)
                                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                if file.isLoading {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(
                                Capsule().stroke(CPTheme.divider, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Command Composer

    private var commandComposer: some View {
        VStack(spacing: 0) {
            // Slash menu (appears above composer)
            if showSlashMenu {
                SlashCommandMenu(
                    workflow: $slashWorkflow,
                    config: $sessionConfig,
                    inputText: $draft,
                    sessionID: sessionID,
                    onBridgeAction: handleSlashBridgeAction,
                    onClientAction: handleSlashClientAction,
                    onDismiss: { showSlashMenu = false }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.96, anchor: .bottom)),
                    removal: .opacity
                ))
            }

            // Config chips
            if !sessionConfig.isEmpty {
                ConfigChips(config: $sessionConfig)
                    .padding(.top, 6)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if startsNewSession {
                HStack(spacing: 8) {
                    Image(systemName: "plus.bubble.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CPTheme.accent)
                    Text("Next send starts a new session")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CPTheme.accent)
                    Spacer()
                    Button("Use Current") {
                        withAnimation(.spring(duration: 0.24, bounce: 0.14)) {
                            startsNewSession = false
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Input row
            HStack(alignment: .center, spacing: 8) {
                // Cancel button (only when agent is busy)
                if let session = session, isBusy(session.state) {
                    Button {
                        cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(CPTheme.error)
                    }
                    .frame(width: 40, height: 40)
                }

                // Slash hint (hidden when agent is busy or slash menu is open)
                if !showSlashMenu && draft.isEmpty && !(session.map { isBusy($0.state) } ?? false) {
                    SlashHintButton {
                        draft = "/"
                        isComposerFocused = true
                    }
                }

                // Text field
                HStack(spacing: 8) {
                    TextField("Send a command...", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .lineLimit(1...5)
                        .focused($isComposerFocused)
                        .layoutPriority(1)
                        .onChange(of: draft) { _, newValue in
                            withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                                showSlashMenu = newValue.hasPrefix("/") || slashWorkflow.canGoBack
                            }
                        }

                    if isComposerFocused {
                        Button {
                            dismissComposerKeyboard()
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(CPTheme.inputBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .animation(.easeOut(duration: 0.18), value: isComposerFocused)

                // Send button
                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color(.systemGray4)
                                : CPTheme.accent
                        )
                }
                .frame(width: 40, height: 40)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Computed Properties

    private var navigationTitle: String {
        if let session = session {
            return CPTheme.shortPath(session.workDir)
        }
        return "Session"
    }

    private var session: SessionInfo? {
        appModel.session(for: sessionID)
    }

    private var timeline: [TimelineItem] {
        appModel.timeline(for: sessionID)
    }

    private var conversationTranscript: String {
        TimelineCopyFormatter.transcript(for: timeline, agentType: session?.agentType)
    }

    private var files: [FileState] {
        appModel.files(for: sessionID)
    }

    private var slashCatalog: SlashCatalogMessage? {
        appModel.slashCatalog(forSessionID: sessionID)
    }

    private var connectionID: String? {
        appModel.connectionID(forSessionID: sessionID)
    }

    private var viewModel: SessionDetailViewModel {
        appModel.makeSessionDetailViewModel(sessionID: sessionID)
    }

    private func isBusy(_ state: AgentState) -> Bool {
        switch state {
        case .thinking, .coding, .runningCommand, .waitingApproval: return true
        case .idle, .error: return false
        }
    }

    // MARK: - Actions

    private func sendDraft() {
        do {
            let config = sessionConfig.isEmpty ? nil : sessionConfig
            if startsNewSession {
                try appModel.sendNewSessionCommand(
                    draft,
                    connectionID: connectionID,
                    config: config
                )
                draft = ""
                startsNewSession = false
                DispatchQueue.main.async {
                    dismiss()
                }
            } else {
                viewModel.draft = draft
                try viewModel.sendDraft(config: config)
                draft = viewModel.draft
            }
            isComposerFocused = false
            appModel.refreshPublishedState()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to send command."
        }
    }

    private func cancel() {
        do {
            try viewModel.cancel()
            appModel.refreshPublishedState()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to send cancel request."
        }
    }

    private func handleSlashBridgeAction(_ message: SlashActionMessage) {
        do {
            try viewModel.sendSlashAction(
                commandId: message.commandId,
                arguments: message.arguments
            )
            appModel.refreshPublishedState()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to run slash action."
        }
    }

    private func handleSlashClientAction(_ commandID: String) {
        switch commandID {
        case "new":
            withAnimation(.spring(duration: 0.24, bounce: 0.14)) {
                startsNewSession = true
                draft = ""
                showSlashMenu = false
            }
            isComposerFocused = true
        default:
            break
        }
    }

    private var deleteConfirmationMessage: String {
        guard let session else {
            return "This session will be deleted."
        }
        if isBusy(session.state) {
            return "This session is still running. It will be stopped first, then deleted."
        }
        return "This session will be deleted from the bridge."
    }

    private func deleteSession() {
        prepareForModalTransition()
        do {
            try appModel.deleteSession(id: sessionID)
            errorMessage = nil
            DispatchQueue.main.async {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dismissComposerKeyboard() {
        isComposerFocused = false
        resignActiveTextInput()
    }

    private func copyConversationTranscript() {
        guard !conversationTranscript.isEmpty else { return }
        copyToPasteboard(conversationTranscript)
        showCopiedConversation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopiedConversation = false
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    private func prepareForModalTransition(_ action: (() -> Void)? = nil) {
        isComposerFocused = false
        showSlashMenu = false
        resignActiveTextInput()
        if let action {
            DispatchQueue.main.async {
                action()
            }
        }
    }

    private func resignActiveTextInput() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

// MARK: - Timeline Cell Router

private struct TimelineCellView: View {
    let sessionID: String
    let item: TimelineItem
    let agentType: AgentType?
    let previousItem: TimelineItem?
    let onCopy: ((String) -> Void)?

    private var topSpacing: CGFloat {
        guard let prev = previousItem else { return 0 }
        // After turnCompleted → big gap (new conversation round)
        if case .turnCompleted = prev.kind { return 20 }
        // After userCommand → medium gap before agent response
        if case .userCommand = prev.kind { return 12 }
        // Agent message after agent message → tight
        if case .agentMessage = prev.kind, case .agentMessage = item.kind { return 2 }
        return 6
    }

    var body: some View {
        VStack(spacing: 0) {
            if topSpacing > 0 {
                Spacer().frame(height: topSpacing)
            }

            timelineContent
                .contentShape(Rectangle())
                .contextMenu {
                    if let copyPayload {
                        Button {
                            onCopy?(copyPayload.text)
                        } label: {
                            Label(copyPayload.title, systemImage: "doc.on.doc")
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        switch item.kind {
        case let .userCommand(text):
            UserCommandBubble(text: text)

        case let .agentMessage(text):
            AgentMessageBubble(text: text, agentType: agentType ?? .claude)

        case let .thinking(text):
            ThinkingCell(text: text)

        case let .codeChange(changes):
            CodeChangeCard(sessionID: sessionID, eventId: item.eventId, changes: changes)

        case let .commandExec(command, output, exitCode, status):
            CommandExecCard(command: command, output: output, exitCode: exitCode, status: status)

        case let .turnCompleted(summary, filesChanged, usage):
            TurnCompletedCard(summary: summary, filesChanged: filesChanged, usage: usage)

        case let .status(state, message):
            if let toolEvent = TimelineToolEventParser.parse(statusMessage: message) {
                ToolEventCard(presentation: toolEvent)
            } else {
                StatusBanner(state: state, message: message)
            }

        case let .sessionError(message):
            ErrorBanner(message: message, isTransport: false)

        case let .transportError(message):
            ErrorBanner(message: message, isTransport: true)

        case let .system(message):
            SystemMessage(message: message)
        }
    }

    private var copyPayload: (title: String, text: String)? {
        guard let payload = TimelineCopyFormatter.copyPayload(for: item, agentType: agentType) else {
            return nil
        }
        return (payload.title, payload.text)
    }
}

// MARK: - User Command Bubble (right-aligned)

private struct UserCommandBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    CPTheme.accent,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }
}

// MARK: - Agent Message (left-aligned, Markdown, no bubble)

private struct AgentMessageBubble: View {
    let text: String
    let agentType: AgentType

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Accent bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(CPTheme.agentColor(agentType))
                .frame(width: 3)

            // Content
            MarkdownText(text: text, font: .subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 24)
    }
}

// MARK: - Thinking Cell (inline, lightweight)

private struct ThinkingCell: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("✦")
                .font(.caption2)
                .foregroundStyle(CPTheme.agentColor(.claude).opacity(0.6))

            Text(text)
                .font(.caption)
                .italic()
                .foregroundStyle(.tertiary)
                .lineLimit(3)
        }
        .padding(.leading, 13)
        .padding(.trailing, 40)
    }
}

// MARK: - Code Change Card (compact, expandable)

private struct CodeChangeCard: View {
    let sessionID: String
    let eventId: Int?
    let changes: [FileChange]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CPTheme.info)

                    Text("\(changes.count) file\(changes.count == 1 ? "" : "s") changed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.quaternary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                            HStack(spacing: 6) {
                                Image(systemName: CPTheme.fileChangeIcon(change.kind))
                                    .font(.system(size: 10))
                                    .foregroundStyle(CPTheme.fileChangeColor(change.kind))

                                Text(URL(fileURLWithPath: change.path).lastPathComponent)
                                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                                    .lineLimit(1)

                                Spacer()

                                Text(CPTheme.fileChangeLabel(change.kind))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(CPTheme.fileChangeColor(change.kind))
                            }
                        }
                    }

                    if let eventId {
                        NavigationLink {
                            DiffViewerView(sessionID: sessionID, eventId: eventId, changes: changes)
                        } label: {
                            Text("View Diff")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CPTheme.accent)
                    } else {
                        Text("Diff unavailable for legacy timeline events")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .buttonStyle(.plain)
    }
}

// MARK: - Command Execution Card (terminal style, collapsed by default)

private struct CommandExecCard: View {
    let command: String
    let output: String?
    let exitCode: Int?
    let status: CommandExecStatus
    @State private var isExpanded = false

    private var hasOutput: Bool {
        guard let output else { return false }
        return !output.isEmpty
    }

    private var canExpand: Bool {
        hasOutput || exitCode != nil || command.count > 72 || command.contains("\n")
    }

    private var statusColor: Color {
        switch status {
        case .running: return CPTheme.warning
        case .done: return CPTheme.success
        case .failed: return CPTheme.error
        }
    }

    private var statusIcon: String {
        switch status {
        case .running: return "play.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            Button {
                if canExpand {
                    withAnimation(.spring(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text("$")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(CPTheme.terminalPrompt)
                        .padding(.top, 1)

                    Text(command)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(CPTheme.terminalText)
                        .lineLimit(isExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        if status == .running {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(CPTheme.warning)
                        } else {
                            Image(systemName: statusIcon)
                                .font(.system(size: 11))
                                .foregroundStyle(statusColor)
                        }

                        if canExpand {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isExpanded, (hasOutput || exitCode != nil) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    if let output, !output.isEmpty {
                        Text(output)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(30)
                    }

                    if let exitCode {
                        Text("exit code \(exitCode)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
                .padding(10)
            }
        }
        .background(CPTheme.terminalBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Turn Completed (compact divider)

private struct TurnCompletedCard: View {
    let summary: String
    let filesChanged: [String]
    let usage: TokenUsage?

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(CPTheme.success.opacity(0.3))
                .frame(height: 1)

            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(CPTheme.success)

                if let usage = usage {
                    Text(formatTokens(usage.inputTokens + usage.outputTokens))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .fixedSize()

            Rectangle()
                .fill(CPTheme.success.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

// MARK: - Tool Event Card

private struct ToolEventCard: View {
    let presentation: TimelineToolEventPresentation
    @State private var isExpanded = false

    private var canExpand: Bool {
        !presentation.detail.isEmpty && presentation.detail != presentation.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if canExpand {
                    withAnimation(.spring(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CPTheme.info)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(presentation.summary)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)

                        if let subtitle = presentation.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if canExpand {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if !presentation.todoItems.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(presentation.todoItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(item.isCompleted ? CPTheme.success : Color(.tertiaryLabel))
                                .padding(.top, 2)

                            Text(item.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .strikethrough(item.isCompleted, color: CPTheme.success.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }

            if !presentation.searchQueries.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Queries")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    ForEach(Array(presentation.searchQueries.enumerated()), id: \.offset) { _, query in
                        Text(query)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(CPTheme.info.opacity(0.10), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }

            if !presentation.metadataRows.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    ForEach(Array(presentation.metadataRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 8)

                            Text(row.value)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }

            if isExpanded {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)

                Text(presentation.detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CPTheme.divider.opacity(0.45), lineWidth: 0.5)
        )
    }
}

// MARK: - Status Banner (minimal inline text)

private struct StatusBanner: View {
    let state: AgentState
    let message: String

    var body: some View {
        // Skip noisy state transitions
        if state == .idle || message.isEmpty {
            EmptyView()
        } else {
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 2)
        }
    }
}

// MARK: - Error Banner

private struct ErrorBanner: View {
    let message: String
    let isTransport: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(CPTheme.error)

            VStack(alignment: .leading, spacing: 1) {
                Text(isTransport ? "Connection Error" : "Error")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CPTheme.error)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()
        }
        .padding(10)
        .background(CPTheme.errorBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CPTheme.error.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - System Message

private struct SystemMessage: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.quaternary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 2)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Session Detail") {
    NavigationStack {
        SessionDetailView(sessionID: AppPreviewFixtures.primarySessionID)
    }
    .environmentObject(AppModel.previewFixture())
}
#endif
