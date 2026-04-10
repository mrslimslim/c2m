import SwiftUI
import CodePilotCore
import CodePilotProtocol

/// Unified home screen — each saved connection is a "project".
/// Tapping a project auto-connects and shows its sessions.
struct ProjectsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showAddSheet = false
    @State private var showDiagnostics = false
    @State private var deleteTarget: SavedConnection?

    var body: some View {
        NavigationStack {
            ZStack {
                // Subtle gradient background
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        CPTheme.accent.opacity(0.03),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if appModel.savedConnections.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .navigationTitle("CTunnel")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CPTheme.accent)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddProjectSheet()
            }
            .sheet(isPresented: $showDiagnostics) {
                NavigationStack {
                    DiagnosticsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showDiagnostics = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(CPTheme.accentMuted)
                    .frame(width: 100, height: 100)

                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(CPTheme.accent)
            }

            VStack(spacing: 8) {
                Text("No Projects")
                    .font(.title2.weight(.semibold))

                Text("Scan the QR code from your bridge\nto get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showAddSheet = true
            } label: {
                Label("Add Project", systemImage: "qrcode.viewfinder")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CPTheme.accent)
            .padding(.top, 4)

            Spacer()
            Spacer()
        }
        .padding()
    }

    // MARK: - Project List

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(appModel.savedConnections) { saved in
                    NavigationLink {
                        ProjectDetailView(connectionID: saved.id)
                    } label: {
                        ProjectCard(
                            saved: saved,
                            slotState: appModel.slotStates[saved.id] ?? "Disconnected",
                            sessionCount: appModel.sessionsForConnection(saved.id).count
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            if appModel.slotStates[saved.id]?.lowercased().contains("connected") == true {
                                appModel.disconnectSavedConnection(id: saved.id)
                            } else {
                                appModel.connectSavedConnection(id: saved.id)
                            }
                        } label: {
                            let isConn = appModel.slotStates[saved.id]?.lowercased().contains("connected") == true
                            Label(isConn ? "Disconnect" : "Connect",
                                  systemImage: isConn ? "bolt.slash" : "bolt.fill")
                        }

                        Divider()

                        Button(role: .destructive) {
                            deleteTarget = saved
                        } label: {
                            Label("Delete Project", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .confirmationDialog(
            "Delete \(deleteTarget?.name ?? "project")?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appModel.disconnectSavedConnection(id: target.id)
                        appModel.deleteSavedConnection(id: target.id)
                    }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This will remove the project and its connection settings. You can re-add it by scanning the QR code again.")
        }
    }
}

// MARK: - Project Card

private struct ProjectCard: View {
    let saved: SavedConnection
    let slotState: String
    let sessionCount: Int

    private var isConnected: Bool {
        slotState.lowercased().contains("connected") && !slotState.lowercased().contains("disconnected")
    }

    private var isConnecting: Bool {
        slotState.lowercased().contains("connecting") || slotState.lowercased().contains("reconnecting")
    }

    private var statusColor: Color {
        if isConnected { return CPTheme.connectedColor }
        if isConnecting { return CPTheme.connectingColor }
        if slotState.lowercased().contains("failed") { return CPTheme.failedColor }
        return CPTheme.disconnectedColor
    }

    private var connectionIcon: String {
        switch saved.config {
        case .lan: return "network"
        case .relay: return "globe.americas.fill"
        }
    }

    private var hostInfo: String {
        switch saved.config {
        case let .lan(host, port, _, _, _):
            return "\(host):\(port)"
        case let .relay(url, channel, _, _):
            let host = URL(string: url)?.host ?? url
            return "\(host) / \(channel)"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isConnected
                            ? CPTheme.accent.opacity(0.12)
                            : Color(.systemGray5).opacity(0.8)
                    )
                    .frame(width: 48, height: 48)

                Image(systemName: connectionIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isConnected ? CPTheme.accent : .secondary)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(saved.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(hostInfo)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Status
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                    }

                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                }

                if isConnected && sessionCount > 0 {
                    Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .glassCard()
    }

    private var statusText: String {
        if isConnected { return "Live" }
        if isConnecting { return "Connecting" }
        if slotState.lowercased().contains("failed") { return "Failed" }
        return "Offline"
    }
}

// MARK: - Add Project Sheet (QR + Manual)

private struct AddProjectSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var payloadInput: String = ""
    @State private var isShowingScanner = false
    @State private var showManualEntry = false
    @State private var errorText: String?

    // Manual entry fields
    @State private var mode: ConnectionMode = .lan
    @State private var host: String = ""
    @State private var port: String = "19260"
    @State private var token: String = ""
    @State private var relay: String = ""
    @State private var channel: String = ""
    @State private var bridgePubkey: String = ""
    @State private var otp: String = ""

    enum ConnectionMode: String, CaseIterable, Identifiable {
        case lan, relay
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Hero
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(CPTheme.accentMuted)
                                .frame(width: 80, height: 80)

                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(CPTheme.accent)
                        }

                        Text("Add Project")
                            .font(.title3.weight(.bold))

                        Text("Scan the QR code from your bridge\nor paste the pairing payload.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)

                    // QR Scan button
                    Button {
                        isShowingScanner = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 18, weight: .medium))
                            Text("Scan QR Code")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CPTheme.accent)
                    .padding(.horizontal)

                    // Divider
                    HStack {
                        Rectangle().fill(CPTheme.divider).frame(height: 1)
                        Text("or paste payload")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Rectangle().fill(CPTheme.divider).frame(height: 1)
                    }
                    .padding(.horizontal)

                    // Paste payload
                    VStack(spacing: 10) {
                        TextField("ctunnel://pair?...", text: $payloadInput, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.subheadline, design: .monospaced))
                            .lineLimit(2...4)
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
                            parseAndAdd(payloadInput)
                        } label: {
                            Label("Connect", systemImage: "bolt.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(CPTheme.accent)
                        .disabled(payloadInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)

                    // Manual entry toggle
                    Button {
                        withAnimation(.spring(duration: 0.3)) { showManualEntry.toggle() }
                    } label: {
                        HStack {
                            Text("Manual Configuration")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: showManualEntry ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    }

                    if showManualEntry {
                        manualEntryForm
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.bottom, 40)
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
                    parseAndAdd(scannedPayload)
                    isShowingScanner = false
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var manualEntryForm: some View {
        VStack(spacing: 14) {
            Picker("Mode", selection: $mode) {
                ForEach(ConnectionMode.allCases) { m in
                    Text(m.rawValue.uppercased()).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if mode == .lan {
                formField("Host", text: $host, placeholder: "192.168.1.100")
                formField("Port", text: $port, placeholder: "19260", keyboard: .numberPad)
                formField("Token", text: $token, placeholder: "Optional")
            } else {
                formField("Relay URL", text: $relay, placeholder: "wss://relay.example.com")
                formField("Channel", text: $channel, placeholder: "my-channel")
            }

            formField("Bridge Public Key", text: $bridgePubkey, placeholder: "base64...")
            formField("OTP", text: $otp, placeholder: "6-digit code")

            Button {
                connectManualEntry()
            } label: {
                Label("Connect", systemImage: "bolt.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CPTheme.accent)
        }
        .padding(.horizontal)
    }

    private func formField(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .font(.subheadline)
                .padding(10)
                .background(CPTheme.inputBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func parseAndAdd(_ payload: String) {
        do {
            let config = try appModel.parseConnectionPayload(payload)
            let id = "scanned-\(UUID().uuidString.prefix(8))"
            let name = connectionName(for: config)

            if let existingID = appModel.findExistingSavedConnectionID(for: config) {
                appModel.connectSavedConnection(id: existingID)
            } else {
                appModel.addAndConnectSavedConnection(id: id, name: name, config: config)
            }
            errorText = nil
            appModel.latestErrorMessage = nil
            dismiss()
        } catch {
            errorText = "Could not parse pairing payload."
        }
    }

    private func connectManualEntry() {
        let payload: String
        if mode == .relay {
            payload = "relay=\(encode(relay))&channel=\(encode(channel))&bridge_pubkey=\(encode(bridgePubkey))&otp=\(encode(otp))"
        } else {
            payload = "host=\(encode(host))&port=\(encode(port))&token=\(encode(token))&bridge_pubkey=\(encode(bridgePubkey))&otp=\(encode(otp))"
        }
        parseAndAdd(payload)
    }

    private func connectionName(for config: ConnectionConfig) -> String {
        switch config {
        case let .lan(host, port, _, _, _):
            return "\(host):\(port)"
        case let .relay(url, channel, _, _):
            let host = URL(string: url)?.host ?? url
            return "\(host)/\(channel)"
        }
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

#if DEBUG
#Preview("Projects") {
    ProjectsView()
        .environmentObject(AppModel.previewFixture())
}
#endif
