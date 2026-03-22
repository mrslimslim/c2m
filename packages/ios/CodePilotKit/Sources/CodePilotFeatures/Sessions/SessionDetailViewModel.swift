import Foundation
import CodePilotCore
import CodePilotProtocol

public final class SessionDetailViewModel {
    private let sender: PhoneMessageSending
    private let sessionStore: SessionStore
    private let timelineStore: TimelineStore
    private let fileStore: FileStore
    private let sessionIdOverride: String?
    private var detachedDraft: String = ""

    public init(
        sender: PhoneMessageSending,
        sessionStore: SessionStore,
        timelineStore: TimelineStore,
        fileStore: FileStore,
        sessionId: String? = nil
    ) {
        self.sender = sender
        self.sessionStore = sessionStore
        self.timelineStore = timelineStore
        self.fileStore = fileStore
        self.sessionIdOverride = sessionId
    }

    public var draft: String {
        get {
            guard let currentSessionId else {
                return detachedDraft
            }
            return sessionStore.draft(for: currentSessionId)
        }
        set {
            guard let currentSessionId else {
                detachedDraft = newValue
                return
            }
            sessionStore.setDraft(newValue, for: currentSessionId)
        }
    }

    public var timeline: [TimelineItem] {
        guard let currentSessionId else {
            return []
        }
        return timelineStore.timeline(for: currentSessionId)
    }

    public func sendDraft(config: SessionConfig? = nil) throws {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        let wireConfig = config?.isEmpty == true ? nil : config

        guard let currentSessionId else {
            try sender.send(.command(text: text, sessionId: nil, config: wireConfig))
            detachedDraft = ""
            return
        }

        try sender.send(.command(text: text, sessionId: currentSessionId, config: wireConfig))
        timelineStore.appendUserCommand(text, sessionId: currentSessionId)
        sessionStore.updateState(for: currentSessionId, state: .thinking)
        sessionStore.setDraft("", for: currentSessionId)
    }

    public func cancel() throws {
        guard let currentSessionId, isBusySession(currentSessionId) else {
            return
        }
        try sender.send(.cancel(sessionId: currentSessionId))
    }

    public func requestFile(path: String) throws {
        guard let currentSessionId else {
            return
        }
        fileStore.markRequested(path: path, sessionId: currentSessionId)
        do {
            try sender.send(.fileRequest(path: path, sessionId: currentSessionId))
        } catch {
            fileStore.cancelRequested(path: path, sessionId: currentSessionId)
            throw error
        }
    }

    public func sendSlashAction(
        commandId: String,
        arguments: [String: SlashActionArgumentValue]? = nil
    ) throws {
        try sender.send(
            .slashAction(
                .init(
                    commandId: commandId,
                    sessionId: currentSessionId,
                    arguments: arguments
                )
            )
        )
    }

    public func fileState(for path: String) -> FileState? {
        guard let currentSessionId else {
            return nil
        }
        return fileStore.fileState(for: path, sessionId: currentSessionId)
    }

    private var currentSessionId: String? {
        let seed = sessionIdOverride ?? sessionStore.activeSessionId
        return sessionStore.resolvedSessionId(for: seed)
    }

    private func isBusySession(_ sessionId: String) -> Bool {
        guard let state = sessionStore.session(for: sessionId)?.state else {
            return false
        }
        switch state {
        case .idle, .error:
            return false
        case .thinking, .coding, .runningCommand, .waitingApproval:
            return true
        }
    }
}
