import SwiftUI
import CodePilotCore

struct DiagnosticsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        List {
            // MARK: - Latency Dashboard

            Section {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let latencyMs = appModel.latestLatencyMs {
                        Text("\(latencyMs)")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundStyle(latencyColor(for: latencyMs))
                        Text("ms")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("--")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundStyle(.quaternary)
                        Text("ms")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("LATENCY")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.8)
                        Text(latencyLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(latencyLabelColor)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }

            // MARK: - Transport Timeline

            if !appModel.transportTimeline.isEmpty {
                Section {
                    ForEach(Array(appModel.transportTimeline.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            Image(systemName: timelineIcon(for: item.kind))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(timelineIconColor(for: item.kind))
                                .frame(width: 20, alignment: .center)
                            Text(DiagnosticsRedactor.redact(DiagnosticsFormatter.timelineText(for: item)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("TRANSPORT TIMELINE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                }
            }

            // MARK: - Diagnostics Log

            Section {
                if appModel.diagnosticsRedactedLines.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "text.magnifyingglass")
                                .font(.title3)
                                .foregroundStyle(.quaternary)
                            Text("No diagnostics yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    ForEach(Array(appModel.diagnosticsRedactedLines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, design: .monospaced).weight(.medium))
                                .foregroundStyle(.quaternary)
                                .frame(minWidth: 28, alignment: .trailing)
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .listRowBackground(
                            index.isMultiple(of: 2)
                                ? Color.clear
                                : CPTheme.codeBg.opacity(0.3)
                        )
                    }
                }
            } header: {
                Text("DIAGNOSTICS LOG")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let allText = appModel.diagnosticsRedactedLines.joined(separator: "\n")
                    UIPasteboard.general.string = allText
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .disabled(appModel.diagnosticsRedactedLines.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private var latencyLabel: String {
        guard let ms = appModel.latestLatencyMs else { return "No data" }
        if ms < 100 { return "Excellent" }
        if ms <= 300 { return "Good" }
        return "Slow"
    }

    private var latencyLabelColor: Color {
        guard let ms = appModel.latestLatencyMs else { return .secondary }
        return latencyColor(for: ms)
    }

    private func latencyColor(for ms: Int) -> Color {
        if ms < 100 { return CPTheme.success }
        if ms <= 300 { return CPTheme.warning }
        return CPTheme.error
    }

    private func timelineIcon(for kind: TimelineItem.Kind) -> String {
        switch kind {
        case .system:          return "gearshape"
        case .transportError:  return "exclamationmark.triangle"
        case .userCommand:     return "terminal"
        case .status:          return "info.circle"
        case .thinking:        return "brain"
        case .agentMessage:    return "bubble.left"
        case .codeChange:      return "doc.text"
        case .commandExec:     return "play.circle"
        case .turnCompleted:   return "checkmark.circle"
        case .sessionError:    return "xmark.octagon"
        }
    }

    private func timelineIconColor(for kind: TimelineItem.Kind) -> Color {
        switch kind {
        case .system:          return .secondary
        case .transportError:  return CPTheme.error
        case .userCommand:     return CPTheme.terminalPrompt
        case .status:          return CPTheme.info
        case .thinking:        return CPTheme.agentColor(.claude)
        case .agentMessage:    return .primary
        case .codeChange:      return CPTheme.info
        case .commandExec:     return CPTheme.warning
        case .turnCompleted:   return CPTheme.success
        case .sessionError:    return CPTheme.error
        }
    }
}

private enum DiagnosticsFormatter {
    static func timelineText(for item: TimelineItem) -> String {
        switch item.kind {
        case let .system(message):
            return "System: \(message)"
        case let .transportError(message):
            return "Transport Error: \(message)"
        case let .userCommand(text):
            return "Command: \(text)"
        case let .status(state, message):
            return "Status \(state.rawValue): \(message)"
        case let .thinking(text):
            return "Thinking: \(text)"
        case let .agentMessage(text):
            return "Agent: \(text)"
        case let .codeChange(changes):
            return "Code change (\(changes.count) files)"
        case let .commandExec(command, output, exitCode, status):
            return "Exec \(status.rawValue): \(command) \(output ?? "") \(exitCode.map(String.init) ?? "")"
        case let .turnCompleted(summary, filesChanged, _):
            return "Turn complete: \(summary) (\(filesChanged.count) files)"
        case let .sessionError(message):
            return "Session Error: \(message)"
        }
    }
}

#if DEBUG
#Preview("Diagnostics") {
    NavigationStack {
        DiagnosticsView()
    }
    .environmentObject(AppModel.previewFixture())
}
#endif
