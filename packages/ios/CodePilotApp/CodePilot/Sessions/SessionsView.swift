import SwiftUI
import CodePilotProtocol

struct SessionsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showNewSession = false

    var body: some View {
        NavigationStack {
            Group {
                if appModel.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Tap + to send your first command and start a session.")
                    )
                } else {
                    List {
                        ForEach(appModel.sessions, id: \.id) { session in
                            NavigationLink {
                                SessionDetailView(sessionID: session.id)
                                    .onAppear {
                                        appModel.selectSession(id: session.id)
                                    }
                            } label: {
                                SessionCard(
                                    session: session,
                                    isActive: appModel.activeSessionID == session.id
                                )
                            }
                        }
                    }
                    .refreshable { appModel.refreshSessions() }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        appModel.refreshSessions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSession = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(!isConnected)
                }
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionSheet()
            }
        }
    }

    private var isConnected: Bool {
        appModel.currentConnectionSummary.lowercased().contains("connected")
    }
}

private struct SessionCard: View {
    let session: SessionInfo
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatar(agentType: session.agentType)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(CPTheme.shortPath(session.workDir))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if isActive {
                        PulsingDot(color: .green)
                    }
                }

                Text(CPTheme.agentLabel(session.agentType))
                    .font(.subheadline)
                    .foregroundStyle(CPTheme.agentColor(session.agentType))

                HStack(spacing: 8) {
                    StateBadge(state: session.state)

                    Text(CPTheme.relativeTime(from: session.lastActiveAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NewSessionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var command: String = ""
    @State private var selectedConnectionID: String?
    @State private var errorMessage: String?

    private var connectedSlots: [(id: String, name: String)] {
        appModel.savedConnections.compactMap { saved in
            let state = appModel.slotStates[saved.id] ?? "Disconnected"
            if state.lowercased().contains("connected") && !state.lowercased().contains("disconnected") {
                return (id: saved.id, name: saved.name)
            }
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "plus.message.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    Text("New Session")
                        .font(.title3.weight(.semibold))
                    Text("Send a command to create a new session with the AI agent.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Connection picker (only if multiple active connections)
                if connectedSlots.count > 1 {
                    Picker("Bridge", selection: $selectedConnectionID) {
                        ForEach(connectedSlots, id: \.id) { slot in
                            Text(slot.name).tag(Optional(slot.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                } else if connectedSlots.isEmpty {
                    Label("No active connections", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                TextField("e.g. \"Explain this codebase\" or \"Fix the login bug\"", text: $command, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .padding(12)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendCommand()
                    }
                    .fontWeight(.semibold)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium])
    }

    private func sendCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            try appModel.sendNewSessionCommand(text, connectionID: selectedConnectionID ?? connectedSlots.first?.id)
            dismiss()
        } catch {
            errorMessage = "Failed to send command: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
#Preview("Sessions") {
    SessionsView()
        .environmentObject(AppModel.previewFixture())
}
#endif
