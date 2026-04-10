import SwiftUI
import CodePilotCore
import CodePilotFeatures

struct ConnectionsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var mode: ConnectionMode = .lan
    @State private var host: String = "127.0.0.1"
    @State private var port: String = "19260"
    @State private var token: String = ""
    @State private var relay: String = ""
    @State private var channel: String = ""
    @State private var bridgePubkey: String = ""
    @State private var otp: String = ""
    @State private var payloadInput: String = ""
    @State private var isShowingScanner: Bool = false

    enum ConnectionMode: String, CaseIterable, Identifiable {
        case lan
        case relay

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Pairing Payload
                Section {
                    TextField("ctunnel://pair?... or JSON payload", text: $payloadInput, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        parseAndConnect(payloadInput)
                    } label: {
                        Label("Parse & Connect", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        isShowingScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "camera.viewfinder")
                    }
                } header: {
                    Text("Pairing Payload")
                }

                // MARK: - Saved Connections
                Section {
                    if appModel.savedConnections.isEmpty {
                        Text("No saved connections yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.savedConnections) { savedConnection in
                            SavedConnectionRow(
                                savedConnection: savedConnection,
                                slotState: appModel.slotStates[savedConnection.id] ?? "Disconnected",
                                onConnect: {
                                    appModel.connectSavedConnection(id: savedConnection.id)
                                },
                                onDisconnect: {
                                    appModel.disconnectSavedConnection(id: savedConnection.id)
                                },
                                onSelect: {
                                    if let selected = appModel.selectSavedConnection(id: savedConnection.id) {
                                        apply(config: selected)
                                    }
                                }
                            )
                        }
                    }
                } header: {
                    Text("Saved Connections")
                }

                // MARK: - Manual Entry
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(ConnectionMode.allCases) { mode in
                            Text(mode.rawValue.uppercased()).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .lan {
                        TextField("Host", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                        TextField("Token (optional with pairing)", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        TextField("Relay URL", text: $relay)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Channel", text: $channel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    TextField("Bridge Public Key", text: $bridgePubkey, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("OTP", text: $otp)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Manual Entry")
                }

                // MARK: - Connect
                Section {
                    Button {
                        parseAndConnectManualEntry()
                    } label: {
                        Label("Connect", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Connections")
            .sheet(isPresented: $isShowingScanner) {
                QRScannerView { scannedPayload in
                    payloadInput = scannedPayload
                    parseAndConnect(scannedPayload)
                    isShowingScanner = false
                }
            }
            .alert("Connection Error", isPresented: Binding(
                get: { appModel.latestErrorMessage != nil },
                set: { if !$0 { appModel.latestErrorMessage = nil } }
            )) {
                Button("OK") {
                    appModel.latestErrorMessage = nil
                }
            } message: {
                Text(appModel.latestErrorMessage ?? "")
            }
        }
    }

    // MARK: - Helpers

    private func parseAndConnect(_ payload: String) {
        do {
            let config = try appModel.parseConnectionPayload(payload)
            // Save as new connection and connect
            let id = "scanned-\(UUID().uuidString.prefix(8))"
            let name = connectionName(for: config)
            saveAndConnect(id: id, name: name, config: config)
            appModel.latestErrorMessage = nil
        } catch {
            appModel.latestErrorMessage = "Could not parse pairing payload."
        }
    }

    private func parseAndConnectManualEntry() {
        do {
            let payload = payloadFromManualEntry()
            let config = try appModel.parseConnectionPayload(payload)
            let id = "manual-\(UUID().uuidString.prefix(8))"
            let name = connectionName(for: config)
            saveAndConnect(id: id, name: name, config: config)
            appModel.latestErrorMessage = nil
        } catch {
            appModel.latestErrorMessage = "Connection details are incomplete or invalid."
        }
    }

    private func saveAndConnect(id: String, name: String, config: ConnectionConfig) {
        // Check if we already have a saved connection with same host/url
        let existingID = findExistingSavedConnection(for: config)

        if let existingID {
            // Update and reconnect existing
            appModel.connectSavedConnection(id: existingID)
        } else {
            // Add new saved connection then connect
            // For now, we use the connectionsViewModel indirectly through appModel
            // We need to add the connection to saved list first
            appModel.addAndConnectSavedConnection(id: id, name: name, config: config)
        }
    }

    private func findExistingSavedConnection(for config: ConnectionConfig) -> String? {
        for saved in appModel.savedConnections {
            switch (saved.config, config) {
            case let (.lan(h1, p1, _, _, _), .lan(h2, p2, _, _, _)):
                if h1 == h2 && p1 == p2 { return saved.id }
            case let (.relay(u1, c1, _, _), .relay(u2, c2, _, _)):
                if u1 == u2 && c1 == c2 { return saved.id }
            default:
                break
            }
        }
        return nil
    }

    private func connectionName(for config: ConnectionConfig) -> String {
        switch config {
        case let .lan(host, port, _, _, _):
            return "LAN \(host):\(port)"
        case let .relay(url, channel, _, _):
            let host = URL(string: url)?.host ?? url
            return "Relay \(host)/\(channel)"
        }
    }

    private func payloadFromManualEntry() -> String {
        if mode == .relay {
            return "relay=\(encode(relay))&channel=\(encode(channel))&bridge_pubkey=\(encode(bridgePubkey))&otp=\(encode(otp))"
        }
        return "host=\(encode(host))&port=\(encode(port))&token=\(encode(token))&bridge_pubkey=\(encode(bridgePubkey))&otp=\(encode(otp))"
    }

    private func apply(config: ConnectionConfig) {
        switch config {
        case let .lan(host, port, token, bridgePublicKey, otp):
            mode = .lan
            self.host = host
            self.port = String(port)
            self.token = token
            relay = ""
            channel = ""
            bridgePubkey = bridgePublicKey
            self.otp = otp
        case let .relay(url, channel, bridgePublicKey, otp):
            mode = .relay
            relay = url
            self.channel = channel
            bridgePubkey = bridgePublicKey
            self.otp = otp
            host = "127.0.0.1"
            port = "19260"
            token = ""
        }
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

// MARK: - Saved Connection Row

private struct SavedConnectionRow: View {
    let savedConnection: SavedConnection
    let slotState: String
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onSelect: () -> Void

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

    var body: some View {
        HStack(spacing: 12) {
            // Connection type icon
            Image(systemName: connectionIcon(for: savedConnection.config))
                .font(.title3)
                .foregroundStyle(isConnected ? CPTheme.accent : .secondary)
                .frame(width: 28)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(savedConnection.name)
                    .font(.body.weight(isConnected ? .semibold : .regular))
                    .foregroundStyle(isConnected ? CPTheme.accent : .primary)
                Text(slotState)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Spacer()

            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Connect/Disconnect button
            if isConnecting {
                Button {
                    onDisconnect()
                } label: {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if isConnected {
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CPTheme.error.opacity(0.7))
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    onConnect()
                } label: {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundStyle(CPTheme.accent)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    private func connectionIcon(for config: ConnectionConfig) -> String {
        switch config {
        case .lan: return "wifi"
        case .relay: return "globe"
        }
    }
}

#if DEBUG
#Preview("Connections") {
    ConnectionsView()
        .environmentObject(AppModel.previewFixture())
}
#endif
