import CodePilotCore
import CodePilotProtocol

public final class SessionsViewModel {
    private let sender: PhoneMessageSending
    private let sessionStore: SessionStore

    public init(sender: PhoneMessageSending, sessionStore: SessionStore) {
        self.sender = sender
        self.sessionStore = sessionStore
    }

    public var sessions: [SessionInfo] {
        sessionStore.sessions
    }

    public var activeSessionId: String? {
        sessionStore.activeSessionId
    }

    public func selectSession(id: String?) {
        sessionStore.setActiveSession(id: id)
    }

    public func refreshSessions() throws {
        try sender.send(.listSessions)
    }
}
