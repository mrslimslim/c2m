import SwiftUI
import CodePilotCore
import CodePilotFeatures
import CodePilotProtocol

struct SessionDetailView: View {
    @EnvironmentObject private var appModel: AppModel

    let sessionID: String

    @State private var draft: String = ""
    @State private var requestedPath: String = ""
    @State private var errorMessage: String?
    @State private var showFileRequest: Bool = false
    @State private var sessionConfig = SessionConfig()
    @State private var showSlashMenu = false
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
                                item: item,
                                agentType: session?.agentType,
                                previousItem: index > 0 ? timeline[index - 1] : nil
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
                Button {
                    showFileRequest.toggle()
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // Typing indicator
                if let session = session, isBusy(session.state) {
                    TypingIndicator(state: session.state, agentType: session.agentType)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                commandComposer
            }
        }
        .onAppear {
            appModel.selectSession(id: sessionID)
            draft = viewModel.draft
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showFileRequest) {
            fileRequestSheet
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
                    config: $sessionConfig,
                    inputText: $draft,
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            // Input row
            HStack(alignment: .bottom, spacing: 8) {
                // Cancel button (only when agent is busy)
                if let session = session, isBusy(session.state) {
                    Button {
                        cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(CPTheme.error)
                    }
                }

                // Slash hint
                if !showSlashMenu && draft.isEmpty {
                    SlashHintButton {
                        draft = "/"
                        isComposerFocused = true
                    }
                }

                // Text field
                TextField("Send a command...", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(CPTheme.inputBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .onChange(of: draft) { _, newValue in
                        withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                            showSlashMenu = newValue.hasPrefix("/")
                        }
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button {
                                isComposerFocused = false
                            } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

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
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - File Request Sheet

    private var fileRequestSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(CPTheme.accentMuted)
                            .frame(width: 56, height: 56)
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(CPTheme.accent)
                    }

                    Text("Request File")
                        .font(.headline)
                }
                .padding(.top, 20)

                TextField("src/main.swift", text: $requestedPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(12)
                    .background(CPTheme.inputBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal)

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showFileRequest = false }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Request") {
                        requestFile()
                        showFileRequest = false
                    }
                    .fontWeight(.semibold)
                    .tint(CPTheme.accent)
                    .disabled(requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
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

    private var files: [FileState] {
        appModel.files(for: sessionID)
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
            viewModel.draft = draft
            let config = sessionConfig.isEmpty ? nil : sessionConfig
            try viewModel.sendDraft(config: config)
            draft = viewModel.draft
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

    private func requestFile() {
        let path = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        do {
            try viewModel.requestFile(path: path)
            appModel.refreshPublishedState()
            requestedPath = ""
            errorMessage = nil
        } catch {
            errorMessage = "Failed to request file."
        }
    }
}

// MARK: - Timeline Cell Router

private struct TimelineCellView: View {
    let item: TimelineItem
    let agentType: AgentType?
    let previousItem: TimelineItem?

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

            switch item.kind {
            case let .userCommand(text):
                UserCommandBubble(text: text)

            case let .agentMessage(text):
                AgentMessageBubble(text: text, agentType: agentType ?? .claude)

            case let .thinking(text):
                ThinkingCell(text: text)

            case let .codeChange(changes):
                CodeChangeCard(changes: changes)

            case let .commandExec(command, output, exitCode, status):
                CommandExecCard(command: command, output: output, exitCode: exitCode, status: status)

            case let .turnCompleted(summary, filesChanged, usage):
                TurnCompletedCard(summary: summary, filesChanged: filesChanged, usage: usage)

            case let .status(state, message):
                StatusBanner(state: state, message: message)

            case let .sessionError(message):
                ErrorBanner(message: message, isTransport: false)

            case let .transportError(message):
                ErrorBanner(message: message, isTransport: true)

            case let .system(message):
                SystemMessage(message: message)
            }
        }
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
    let changes: [FileChange]
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Summary line
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

                // Expanded file list
                if isExpanded {
                    Divider().opacity(0.3)

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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
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
                if output != nil && !output!.isEmpty {
                    withAnimation(.spring(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("$")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(CPTheme.terminalPrompt)

                    Text(command)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(CPTheme.terminalText)
                        .lineLimit(1)

                    Spacer()

                    if status == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(CPTheme.warning)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Output (collapsed by default)
            if isExpanded, let output = output, !output.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                Text(output)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .lineLimit(30)
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
