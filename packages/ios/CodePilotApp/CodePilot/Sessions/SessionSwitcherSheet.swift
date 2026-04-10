import SwiftUI
import CodePilotProtocol

struct SessionSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sessions: [SessionInfo]
    let activeSessionID: String?
    let onSelect: (String) -> Void
    let onStartNewSession: () -> Void

    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            List {
                if filteredSessions.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No matching sessions")
                                .font(.headline)
                            Text("Start a new session from this project instead.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Start New Session") {
                                dismiss()
                                onStartNewSession()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    ForEach(filteredSessions, id: \.id) { session in
                        Button {
                            dismiss()
                            onSelect(session.id)
                        } label: {
                            HStack(spacing: 12) {
                                AgentAvatar(agentType: session.agentType, size: 34)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(CPTheme.shortPath(session.workDir))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(session.id)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if session.id == activeSessionID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(CPTheme.accent)
                                }

                                StateBadge(state: session.state)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search sessions")
        }
    }

    private var filteredSessions: [SessionInfo] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }
        }

        return sessions
            .filter { session in
                session.id.localizedCaseInsensitiveContains(trimmed)
                    || session.workDir.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }
}
