import Foundation
import CodePilotProtocol

public final class SessionMessageRouter {
    private let sessionStore: SessionStore
    private let timelineStore: TimelineStore
    private let fileStore: FileStore
    private let diagnostics: DiagnosticsStore

    public init(
        sessionStore: SessionStore,
        timelineStore: TimelineStore,
        fileStore: FileStore,
        diagnostics: DiagnosticsStore
    ) {
        self.sessionStore = sessionStore
        self.timelineStore = timelineStore
        self.fileStore = fileStore
        self.diagnostics = diagnostics
    }

    public func handle(_ message: BridgeMessage) {
        switch message {
        case let .sessionList(sessions):
            let remaps = sessionStore.applySessionList(sessions)
            for remap in remaps {
                timelineStore.migrateSessionTimeline(from: remap.from, to: remap.to)
                fileStore.migrateSessionState(from: remap.from, to: remap.to)
                diagnostics.recordInfo("session_remap:\(remap.from)->\(remap.to)")
            }
            diagnostics.recordInfo("session_list:\(sessions.count)")

        case let .event(sessionId, event, timestamp):
            let targetSessionId = sessionStore.resolvedSessionId(for: sessionId) ?? sessionId
            timelineStore.appendBridgeEvent(sessionId: targetSessionId, event: event, timestamp: timestamp)
            applySessionState(event: event, sessionId: targetSessionId)
            diagnostics.recordInfo("event:\(targetSessionId):\(eventLabel(event))")

        case let .fileContent(path, content, language):
            fileStore.routeFileContent(
                path: path,
                content: content,
                language: language,
                fallbackSessionId: sessionStore.activeSessionId
            )
            diagnostics.recordInfo("file_content:\(path)")

        case let .pong(latencyMs):
            diagnostics.recordInfo("pong:\(latencyMs)ms")

        case let .error(message):
            timelineStore.appendTransportError(message)
            diagnostics.recordError(message)
        }
    }

    private func applySessionState(event: AgentEvent, sessionId: String) {
        switch event {
        case let .status(state, _):
            sessionStore.updateState(for: sessionId, state: state)
        case .thinking:
            sessionStore.updateState(for: sessionId, state: .thinking)
        case .codeChange:
            sessionStore.updateState(for: sessionId, state: .coding)
        case let .commandExec(_, _, _, status):
            switch status {
            case .running:
                sessionStore.updateState(for: sessionId, state: .runningCommand)
            case .done:
                sessionStore.updateState(for: sessionId, state: .idle)
            case .failed:
                sessionStore.updateState(for: sessionId, state: .error)
            }
        case .agentMessage:
            break
        case .turnCompleted:
            sessionStore.updateState(for: sessionId, state: .idle)
        case .error:
            sessionStore.updateState(for: sessionId, state: .error)
        }
    }

    private func eventLabel(_ event: AgentEvent) -> String {
        switch event {
        case .status: return "status"
        case .thinking: return "thinking"
        case .codeChange: return "code_change"
        case .commandExec: return "command_exec"
        case .agentMessage: return "agent_message"
        case .error: return "error"
        case .turnCompleted: return "turn_completed"
        }
    }
}
