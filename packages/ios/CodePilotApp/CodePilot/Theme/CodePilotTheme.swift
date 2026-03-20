import SwiftUI
import CodePilotProtocol

// MARK: - Design System

enum CPTheme {
    // MARK: - Brand Colors

    /// Deep indigo-violet brand color
    static let accent = Color(red: 0.38, green: 0.36, blue: 1.0)
    /// Lighter variant for highlights
    static let accentLight = Color(red: 0.55, green: 0.53, blue: 1.0)
    /// Subtle brand tint for backgrounds
    static let accentMuted = Color(red: 0.38, green: 0.36, blue: 1.0).opacity(0.12)

    // MARK: - Surface Colors

    /// Primary surface (cards, sheets)
    static let surface = Color(.secondarySystemGroupedBackground)
    /// Elevated surface
    static let surfaceElevated = Color(.tertiarySystemGroupedBackground)
    /// Input field background
    static let inputBg = Color(.systemGray6)
    /// Subtle divider
    static let divider = Color(.separator).opacity(0.5)

    // MARK: - Agent Branding

    static func agentColor(_ type: AgentType) -> Color {
        switch type {
        case .claude: return Color(red: 0.68, green: 0.52, blue: 1.0)  // Soft violet
        case .codex: return Color(red: 0.2, green: 0.84, blue: 0.65)   // Mint green
        }
    }

    static func agentGradient(_ type: AgentType) -> LinearGradient {
        switch type {
        case .claude:
            return LinearGradient(
                colors: [Color(red: 0.58, green: 0.36, blue: 1.0), Color(red: 0.82, green: 0.52, blue: 1.0)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .codex:
            return LinearGradient(
                colors: [Color(red: 0.1, green: 0.72, blue: 0.55), Color(red: 0.3, green: 0.92, blue: 0.7)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    static func agentIcon(_ type: AgentType) -> String {
        switch type {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        }
    }

    static func agentLabel(_ type: AgentType) -> String {
        switch type {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    // MARK: - State Colors & Icons

    static func stateColor(_ state: AgentState) -> Color {
        switch state {
        case .idle: return Color(red: 0.2, green: 0.84, blue: 0.65)
        case .thinking: return Color(red: 0.68, green: 0.52, blue: 1.0)
        case .coding: return accent
        case .runningCommand: return Color(red: 1.0, green: 0.72, blue: 0.26)
        case .waitingApproval: return Color(red: 1.0, green: 0.84, blue: 0.26)
        case .error: return Color(red: 1.0, green: 0.38, blue: 0.42)
        }
    }

    static func stateIcon(_ state: AgentState) -> String {
        switch state {
        case .idle: return "checkmark.circle.fill"
        case .thinking: return "brain"
        case .coding: return "curlybraces"
        case .runningCommand: return "play.circle.fill"
        case .waitingApproval: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    static func stateLabel(_ state: AgentState) -> String {
        switch state {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .coding: return "Coding"
        case .runningCommand: return "Running"
        case .waitingApproval: return "Approval"
        case .error: return "Error"
        }
    }

    // MARK: - Terminal Colors

    static let terminalBg = Color(red: 0.06, green: 0.06, blue: 0.09)
    static let terminalText = Color(red: 0.2, green: 0.92, blue: 0.55)
    static let terminalPrompt = Color(red: 0.45, green: 0.78, blue: 1.0)

    // MARK: - Semantic Colors

    static let success = Color(red: 0.2, green: 0.84, blue: 0.65)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.26)
    static let error = Color(red: 1.0, green: 0.38, blue: 0.42)
    static let info = Color(red: 0.45, green: 0.78, blue: 1.0)

    // MARK: - Connection Status

    static let connectedColor = success
    static let connectingColor = warning
    static let failedColor = error
    static let disconnectedColor = Color(.systemGray3)

    // MARK: - Bubble & Card

    static let userBubble = accent
    static let agentBubble = Color(.systemGray5)
    static let thinkingBg = Color(red: 0.68, green: 0.52, blue: 1.0).opacity(0.08)
    static let errorBg = error.opacity(0.10)
    static let codeBg = Color(.systemGray6)
    static let cardBg = Color(.secondarySystemGroupedBackground)
    static let summaryBg = Color(.systemGray6)

    // MARK: - Code Change Colors

    static func fileChangeColor(_ kind: FileChangeKind) -> Color {
        switch kind {
        case .add: return success
        case .delete: return error
        case .update: return info
        }
    }

    static func fileChangeIcon(_ kind: FileChangeKind) -> String {
        switch kind {
        case .add: return "plus.circle.fill"
        case .delete: return "minus.circle.fill"
        case .update: return "pencil.circle.fill"
        }
    }

    static func fileChangeLabel(_ kind: FileChangeKind) -> String {
        switch kind {
        case .add: return "Added"
        case .delete: return "Deleted"
        case .update: return "Modified"
        }
    }

    // MARK: - Layout Constants

    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 12
    static let bubbleCornerRadius: CGFloat = 20
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 20

    // MARK: - Relative Time Formatter

    static func relativeTime(from timestampMs: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }

    static func shortPath(_ fullPath: String) -> String {
        let components = fullPath.split(separator: "/")
        if components.count <= 2 {
            return fullPath
        }
        return components.suffix(2).joined(separator: "/")
    }
}

// MARK: - Reusable View Components

struct StateBadge: View {
    let state: AgentState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: CPTheme.stateIcon(state))
                .font(.system(size: 9, weight: .semibold))
            Text(CPTheme.stateLabel(state))
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(CPTheme.stateColor(state).opacity(0.15), in: Capsule())
        .foregroundStyle(CPTheme.stateColor(state))
    }
}

struct AgentAvatar: View {
    let agentType: AgentType
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: CPTheme.agentIcon(agentType))
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(CPTheme.agentGradient(agentType), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: CPTheme.agentColor(agentType).opacity(0.3), radius: 4, y: 2)
    }
}

struct ConnectionStatusPill: View {
    let summary: String
    let latencyMs: Int?

    private enum ConnectionStatus {
        case connected
        case disconnected
        case connecting
    }

    private var status: ConnectionStatus {
        let lower = summary.lowercased()
        if lower == "disconnected" { return .disconnected }
        if lower.hasPrefix("connected") || lower.contains("all connected") { return .connected }
        return .connecting
    }

    private var statusColor: Color {
        switch status {
        case .connected: return CPTheme.connectedColor
        case .disconnected: return CPTheme.disconnectedColor
        case .connecting: return CPTheme.connectingColor
        }
    }

    private var statusIcon: String {
        switch status {
        case .connected: return "wifi"
        case .disconnected: return "wifi.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
        }
    }

    private var statusLabel: String {
        switch status {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)

            Text(statusLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusColor)

            if status == .connected, let ms = latencyMs {
                Text("\(ms)ms")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Glass Card Modifier

struct GlassCard: ViewModifier {
    var padding: CGFloat = CPTheme.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CPTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CPTheme.cornerRadius, style: .continuous)
                    .stroke(CPTheme.divider, lineWidth: 0.5)
            )
    }
}

extension View {
    func glassCard(padding: CGFloat = CPTheme.cardPadding) -> some View {
        modifier(GlassCard(padding: padding))
    }
}

// MARK: - Markdown Text

struct MarkdownText: View {
    let text: String
    var font: Font = .subheadline

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(font)
                .tint(CPTheme.accent)
        } else {
            Text(text)
                .font(font)
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    let state: AgentState
    let agentType: AgentType

    @State private var phase: Int = 0

    private var label: String {
        switch state {
        case .thinking: return "Thinking"
        case .coding: return "Writing code"
        case .runningCommand: return "Running command"
        case .waitingApproval: return "Waiting for approval"
        default: return ""
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(CPTheme.agentColor(agentType))
                        .frame(width: 5, height: 5)
                        .scaleEffect(phase == i ? 1.4 : 0.8)
                        .opacity(phase == i ? 1.0 : 0.4)
                }
            }
            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: phase)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}
