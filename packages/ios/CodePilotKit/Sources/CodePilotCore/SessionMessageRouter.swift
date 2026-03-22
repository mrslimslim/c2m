import Foundation
import CodePilotProtocol

public final class SessionMessageRouter {
    public var onReplayNeeded: ((String, Int) -> Void)?

    private let sessionStore: SessionStore
    private let timelineStore: TimelineStore
    private let fileStore: FileStore
    private let diagnostics: DiagnosticsStore
    private let slashCatalogStore: SlashCatalogStore?
    private let connectionID: String?

    public init(
        sessionStore: SessionStore,
        timelineStore: TimelineStore,
        fileStore: FileStore,
        diagnostics: DiagnosticsStore,
        slashCatalogStore: SlashCatalogStore? = nil,
        connectionID: String? = nil
    ) {
        self.sessionStore = sessionStore
        self.timelineStore = timelineStore
        self.fileStore = fileStore
        self.diagnostics = diagnostics
        self.slashCatalogStore = slashCatalogStore
        self.connectionID = connectionID
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

        case let .event(sessionId, event, eventId, timestamp):
            let targetSessionId = sessionStore.resolvedSessionId(for: sessionId) ?? sessionId
            if eventId <= 0 {
                timelineStore.appendBridgeEvent(sessionId: targetSessionId, event: event, timestamp: timestamp)
                applySessionState(event: event, sessionId: targetSessionId)
                diagnostics.recordInfo("legacy_event:\(targetSessionId):\(eventLabel(event))")
                return
            }
            let lastAppliedEventId = sessionStore.lastAppliedEventID(for: targetSessionId) ?? 0
            if eventId <= lastAppliedEventId {
                diagnostics.recordInfo("event_duplicate:\(targetSessionId):\(eventId)")
                return
            }
            if eventId > lastAppliedEventId + 1 {
                diagnostics.recordInfo("event_gap:\(targetSessionId):\(lastAppliedEventId)->\(eventId)")
                onReplayNeeded?(targetSessionId, lastAppliedEventId)
                return
            }
            timelineStore.appendBridgeEvent(sessionId: targetSessionId, event: event, timestamp: timestamp)
            applySessionState(event: event, sessionId: targetSessionId)
            sessionStore.recordAppliedEventID(eventId, for: targetSessionId)
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

        case let .sessionSyncComplete(sessionId, latestEventId, resolvedSessionId):
            let targetSessionId = resolvedSessionId ?? sessionId
            if let resolvedSessionId, resolvedSessionId != sessionId {
                let remap = sessionStore.applySessionRemap(from: sessionId, to: resolvedSessionId)
                timelineStore.migrateSessionTimeline(from: remap.from, to: remap.to)
                fileStore.migrateSessionState(from: remap.from, to: remap.to)
                diagnostics.recordInfo("session_sync_remap:\(remap.from)->\(remap.to)")
            }
            sessionStore.recordAppliedEventID(latestEventId, for: targetSessionId)
            diagnostics.recordInfo("session_sync_complete:\(targetSessionId):\(latestEventId)")

        case let .slashCatalog(message):
            if let slashCatalogStore, let connectionID {
                slashCatalogStore.replaceCatalog(message, for: connectionID)
            }
            diagnostics.recordInfo("slash_catalog:\(message.adapter.rawValue):\(message.commands.count)")

        case let .slashActionResult(message):
            if let slashCatalogStore, let connectionID {
                slashCatalogStore.recordActionResult(message, for: connectionID)
            }
            diagnostics.recordInfo("slash_action_result:\(message.commandId):\(message.ok)")
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
