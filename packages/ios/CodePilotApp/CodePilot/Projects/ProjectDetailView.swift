import SwiftUI
import CodePilotCore
import CodePilotFeatures
import CodePilotProtocol
#if canImport(UIKit)
import UIKit
#endif

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
    @State private var showRepairSheet = false
    @State private var navigateToSession: SessionDestination?
    @State private var deleteTarget: SessionInfo?
    @State private var deleteErrorMessage: String?

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

    private var recoveryGuidance: ConnectionRecoveryGuidance? {
        guard let saved, slotState.lowercased().contains("failed") else {
            return nil
        }
        return ConnectionRecoveryAdvisor.guidance(
            for: saved.config,
            failureSummary: slotState
        )
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
            if let target = appModel.sessionNavigationTarget(for: connectionID) {
                navigateToSession = SessionDestination(sessionID: target)
                appModel.consumeSessionNavigationTarget(for: connectionID)
            }
        }
        .onChange(of: appModel.sessionNavigationTarget(for: connectionID)) { _, newTarget in
            guard let newTarget else {
                return
            }
            navigateToSession = SessionDestination(sessionID: newTarget)
            appModel.consumeSessionNavigationTarget(for: connectionID)
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
        .sheet(isPresented: $showRepairSheet) {
            if let saved {
                RepairConnectionSheet(
                    connectionID: connectionID,
                    projectName: saved.name
                )
            }
        }
        .alert(
            deleteTitle,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let deleteTarget {
                    deleteSession(deleteTarget)
                }
                self.deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .alert("Error", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK") {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "")
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

                if let recoveryGuidance {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recoveryGuidance.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(recoveryGuidance.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: 300, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(CPTheme.divider, lineWidth: 0.5)
                    )
                    .padding(.top, 6)
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

            if let recoveryGuidance {
                Button {
                    showRepairSheet = true
                } label: {
                    Label(recoveryGuidance.actionLabel, systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }

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
        List {
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
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = session
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
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

    private var deleteTitle: String {
        guard let deleteTarget else {
            return "Delete Session?"
        }
        return "Delete \(CPTheme.shortPath(deleteTarget.workDir))?"
    }

    private var deleteMessage: String {
        guard let deleteTarget else {
            return ""
        }
        if isBusy(deleteTarget.state) {
            return "This session is still running. It will be stopped first, then deleted."
        }
        return "This session will be deleted from the bridge and removed from this project."
    }

    private func isBusy(_ state: AgentState) -> Bool {
        switch state {
        case .thinking, .coding, .runningCommand, .waitingApproval:
            return true
        case .idle, .error:
            return false
        }
    }

    private func deleteSession(_ session: SessionInfo) {
        do {
            try appModel.deleteSession(id: session.id)
            deleteErrorMessage = nil
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
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
    @State private var slashWorkflow = SlashWorkflowState()
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
                                showSlashMenu = newValue.hasPrefix("/") || slashWorkflow.canGoBack
                            }
                        }

                    // Slash menu below input
                    if showSlashMenu {
                        SlashCommandMenu(
                            workflow: $slashWorkflow,
                            config: $sessionConfig,
                            inputText: $command,
                            sessionID: nil,
                            onBridgeAction: handleSlashBridgeAction,
                            onClientAction: handleSlashClientAction,
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
                            prepareForDismiss()
                            DispatchQueue.main.async {
                                dismiss()
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            slashWorkflow.updateCatalog(slashCatalog)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                isFocused = true
            }
        }
        .onChange(of: slashCatalog) { _, newCatalog in
            slashWorkflow.updateCatalog(newCatalog)
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

        prepareForDismiss()
        do {
            let config = sessionConfig.isEmpty ? nil : sessionConfig
            try appModel.sendNewSessionCommand(text, connectionID: connectionID, config: config)
            DispatchQueue.main.async {
                dismiss()
            }
        } catch {
            errorMessage = "Failed to send command: \(error.localizedDescription)"
        }
    }

    private var slashCatalog: SlashCatalogMessage? {
        appModel.slashCatalog(for: connectionID)
    }

    private func handleSlashBridgeAction(_ message: SlashActionMessage) {
        do {
            try appModel.sendSlashAction(message, connectionID: connectionID)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to run slash action: \(error.localizedDescription)"
        }
    }

    private func handleSlashClientAction(_ commandID: String) {
        switch commandID {
        case "new":
            command = ""
            sessionConfig = .init()
            showSlashMenu = false
            isFocused = true
        default:
            break
        }
    }

    private func prepareForDismiss() {
        isFocused = false
        showSlashMenu = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

// MARK: - Repair Connection Sheet

private struct RepairConnectionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let connectionID: String
    let projectName: String

    @State private var payloadInput: String = ""
    @State private var errorText: String?
    @State private var isShowingScanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(CPTheme.accentMuted)
                                .frame(width: 72, height: 72)

                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(CPTheme.accent)
                        }

                        Text("Update Pairing")
                            .font(.title3.weight(.bold))

                        Text("Refresh the saved connection for \(projectName) by scanning the latest QR code or pasting a new pairing payload.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 16)

                    Button {
                        isShowingScanner = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 18, weight: .medium))
                            Text("Scan New QR Code")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CPTheme.accent)

                    VStack(spacing: 10) {
                        TextField("ctunnel://pair?...", text: $payloadInput, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.subheadline, design: .monospaced))
                            .lineLimit(3...6)
                            .padding(12)
                            .background(CPTheme.inputBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        if let errorText {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                Text(errorText)
                                    .font(.caption)
                            }
                            .foregroundStyle(CPTheme.error)
                        }

                        Button {
                            updateConnection(from: payloadInput)
                        } label: {
                            Label("Apply New Pairing", systemImage: "bolt.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(CPTheme.accent)
                        .disabled(payloadInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $isShowingScanner) {
                QRScannerView { scannedPayload in
                    payloadInput = scannedPayload
                    updateConnection(from: scannedPayload)
                    isShowingScanner = false
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func updateConnection(from payload: String) {
        do {
            try appModel.updateSavedConnection(id: connectionID, payload: payload)
            errorText = nil
            dismiss()
        } catch {
            errorText = "Could not update saved pairing."
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
