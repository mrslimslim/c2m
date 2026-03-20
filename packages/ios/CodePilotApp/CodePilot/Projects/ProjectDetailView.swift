import SwiftUI
import CodePilotCore
import CodePilotProtocol

/// Wrapper to avoid NavigationDestination type collisions
private struct SessionDestination: Hashable {
    let sessionID: String
}

/// Shows sessions for a single project (bridge connection).
/// Auto-connects when appearing if not already connected.
struct ProjectDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    let connectionID: String

    @State private var showNewSession = false
    @State private var navigateToSession: SessionDestination?

    private var saved: SavedConnection? {
        appModel.savedConnections.first { $0.id == connectionID }
    }

    private var slotState: String {
        appModel.slotStates[connectionID] ?? "Disconnected"
    }

    private var isConnected: Bool {
        slotState.lowercased().contains("connected") && !slotState.lowercased().contains("disconnected")
    }

    private var isConnecting: Bool {
        slotState.lowercased().contains("connecting") || slotState.lowercased().contains("reconnecting")
    }

    private var sessions: [SessionInfo] {
        appModel.sessionsForConnection(connectionID)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    CPTheme.accent.opacity(0.02),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Group {
                if isConnecting {
                    connectingView
                } else if !isConnected {
                    disconnectedView
                } else if sessions.isEmpty {
                    connectedEmptyView
                } else {
                    sessionsList
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(saved?.name ?? "Project")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(statusColor)
                    }
                }
            }

            if isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            appModel.refreshSessionsForConnection(connectionID)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            showNewSession = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(CPTheme.accent)
                        }
                    }
                }
            }
        }
        .onAppear {
            if !isConnected && !isConnecting {
                appModel.connectSavedConnection(id: connectionID)
            }
        }
        .onChange(of: sessions.count) { oldCount, newCount in
            // Auto-navigate to newly created session
            if newCount > oldCount, let newest = sessions.last {
                navigateToSession = SessionDestination(sessionID: newest.id)
            }
        }
        .navigationDestination(item: $navigateToSession) { dest in
            SessionDetailView(sessionID: dest.sessionID)
                .onAppear {
                    appModel.selectSession(id: dest.sessionID)
                }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(connectionID: connectionID)
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(CPTheme.accent.opacity(0.15), lineWidth: 4)
                    .frame(width: 80, height: 80)

                ProgressView()
                    .controlSize(.large)
                    .tint(CPTheme.accent)
            }

            VStack(spacing: 6) {
                Text("Connecting")
                    .font(.title3.weight(.semibold))

                Text("Establishing secure connection...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                appModel.disconnectSavedConnection(id: connectionID)
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(.systemGray5))
                    .frame(width: 80, height: 80)

                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                Text("Not Connected")
                    .font(.title3.weight(.semibold))

                if slotState.lowercased().contains("failed") {
                    Text(slotState)
                        .font(.caption)
                        .foregroundStyle(CPTheme.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            Button {
                appModel.connectSavedConnection(id: connectionID)
            } label: {
                Label("Reconnect", systemImage: "bolt.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CPTheme.accent)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Empty Sessions

    private var connectedEmptyView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(CPTheme.accentMuted)
                    .frame(width: 80, height: 80)

                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(CPTheme.accent)
            }

            VStack(spacing: 6) {
                Text("No Sessions Yet")
                    .font(.title3.weight(.semibold))

                Text("Send a command to create\nyour first session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showNewSession = true
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CPTheme.accent)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(sessions, id: \.id) { session in
                    Button {
                        navigateToSession = SessionDestination(sessionID: session.id)
                    } label: {
                        SessionCard(
                            session: session,
                            isActive: appModel.activeSessionID == session.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            appModel.refreshSessionsForConnection(connectionID)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if isConnected { return CPTheme.connectedColor }
        if isConnecting { return CPTheme.connectingColor }
        if slotState.lowercased().contains("failed") { return CPTheme.failedColor }
        return CPTheme.disconnectedColor
    }

    private var statusLabel: String {
        if isConnected { return "Connected" }
        if isConnecting { return "Connecting..." }
        if slotState.lowercased().contains("failed") { return "Failed" }
        return "Disconnected"
    }
}

// MARK: - Session Card

private struct SessionCard: View {
    let session: SessionInfo
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatar(agentType: session.agentType, size: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(CPTheme.shortPath(session.workDir))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isActive {
                        PulsingDot(color: CPTheme.connectedColor)
                    }
                }

                HStack(spacing: 8) {
                    StateBadge(state: session.state)

                    Text(CPTheme.relativeTime(from: session.lastActiveAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .glassCard()
    }
}

// MARK: - New Session Sheet

private struct NewSessionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let connectionID: String
    @State private var command: String = ""
    @State private var sessionConfig = SessionConfig()
    @State private var showSlashMenu = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Compact header
                VStack(spacing: 6) {
                    Image(systemName: "plus.message.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(CPTheme.accent)

                    Text("New Session")
                        .font(.headline)
                }
                .padding(.top, 24)
                .padding(.bottom, 16)

                // Config chips (visible when config is set)
                if !sessionConfig.isEmpty {
                    ConfigChips(config: $sessionConfig)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }

                // Input area
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("COMMAND")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.8)

                        Spacer()

                        // Slash hint
                        if !showSlashMenu {
                            Button {
                                command = "/"
                                isFocused = true
                            } label: {
                                HStack(spacing: 3) {
                                    Text("/")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    Text("config")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(.systemGray5), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    TextField("What would you like to do?", text: $command, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(3...8)
                        .focused($isFocused)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.systemGray6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isFocused ? CPTheme.accent.opacity(0.5) : CPTheme.divider, lineWidth: isFocused ? 1.5 : 0.5)
                        )
                        .onChange(of: command) { _, newValue in
                            withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                                showSlashMenu = newValue.hasPrefix("/")
                            }
                        }

                    // Slash menu below input
                    if showSlashMenu {
                        SlashCommandMenu(
                            config: $sessionConfig,
                            inputText: $command,
                            onDismiss: { showSlashMenu = false }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.96, anchor: .top)),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.horizontal, 20)

                // Quick suggestions (hidden when slash menu is open)
                if !showSlashMenu {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            suggestionChip("Explain this codebase")
                            suggestionChip("Find and fix bugs")
                            suggestionChip("Add unit tests")
                            suggestionChip("Refactor for readability")
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.top, 12)
                }

                Spacer()

                // Send button
                Button {
                    sendCommand()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 14, weight: .medium))
                        Text("Start Session")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        canSend
                            ? CPTheme.accent
                            : Color(.systemGray4),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .foregroundStyle(.white)
                }
                .disabled(!canSend)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                isFocused = true
            }
        }
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            command = text
        } label: {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(CPTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(CPTheme.accentMuted, in: Capsule())
                .overlay(
                    Capsule().stroke(CPTheme.accent.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func sendCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            let config = sessionConfig.isEmpty ? nil : sessionConfig
            try appModel.sendNewSessionCommand(text, connectionID: connectionID, config: config)
            dismiss()
        } catch {
            errorMessage = "Failed to send command: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
#Preview("Project Detail") {
    NavigationStack {
        ProjectDetailView(connectionID: "preview-lan")
    }
    .environmentObject(AppModel.previewFixture())
}
#endif
