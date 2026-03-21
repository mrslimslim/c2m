import Foundation
import CodePilotProtocol

public struct TimelineStoreSnapshot: Codable, Equatable, Sendable {
    public let sessionTimelines: [String: [TimelineItem]]
    public let transportTimeline: [TimelineItem]

    public init(
        sessionTimelines: [String: [TimelineItem]],
        transportTimeline: [TimelineItem]
    ) {
        self.sessionTimelines = sessionTimelines
        self.transportTimeline = transportTimeline
    }
}

public final class TimelineStore {
    private let lock = NSLock()
    private var sessionTimelines: [String: [TimelineItem]] = [:]
    private var transportTimelineStorage: [TimelineItem] = []

    public init() {}

    public var transportTimeline: [TimelineItem] {
        lock.lock()
        defer { lock.unlock() }
        return transportTimelineStorage
    }

    public func timeline(for sessionId: String) -> [TimelineItem] {
        lock.lock()
        defer { lock.unlock() }
        return sessionTimelines[sessionId] ?? []
    }

    public func appendSystem(_ message: String, sessionId: String?, timestamp: Int? = nil) {
        let item = TimelineItem(timestamp: timestamp ?? TimelineStore.nowMillis(), kind: .system(message: message))
        lock.lock()
        defer { lock.unlock() }
        if let sessionId {
            sessionTimelines[sessionId, default: []].append(item)
        } else {
            transportTimelineStorage.append(item)
        }
    }

    public func appendUserCommand(_ text: String, sessionId: String, timestamp: Int? = nil) {
        appendSessionItem(
            .init(timestamp: timestamp ?? TimelineStore.nowMillis(), kind: .userCommand(text: text)),
            sessionId: sessionId
        )
    }

    public func appendBridgeEvent(sessionId: String, event: AgentEvent, timestamp: Int) {
        let kind: TimelineItem.Kind
        switch event {
        case let .status(state, message):
            kind = .status(state: state, message: message)
        case let .thinking(text):
            kind = .thinking(text: text)
        case let .codeChange(changes):
            kind = .codeChange(changes: changes)
        case let .commandExec(command, output, exitCode, status):
            kind = .commandExec(command: command, output: output, exitCode: exitCode, status: status)
        case let .agentMessage(text):
            kind = .agentMessage(text: text)
        case let .error(message):
            kind = .sessionError(message: message)
        case let .turnCompleted(summary, filesChanged, usage):
            kind = .turnCompleted(summary: summary, filesChanged: filesChanged, usage: usage)
        }

        appendSessionItem(.init(timestamp: timestamp, kind: kind), sessionId: sessionId)
    }

    public func appendTransportError(_ message: String, timestamp: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        transportTimelineStorage.append(
            .init(timestamp: timestamp ?? TimelineStore.nowMillis(), kind: .transportError(message: message))
        )
    }

    public func migrateSessionTimeline(from oldSessionId: String, to newSessionId: String) {
        guard oldSessionId != newSessionId else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let previous = sessionTimelines.removeValue(forKey: oldSessionId) ?? []
        guard !previous.isEmpty else {
            return
        }
        sessionTimelines[newSessionId, default: []].append(contentsOf: previous)
    }

    public func removeSessionTimeline(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        sessionTimelines[sessionId] = nil
    }

    public func resetSessionTimelines() {
        lock.lock()
        defer { lock.unlock() }
        sessionTimelines.removeAll()
    }

    public func snapshot() -> TimelineStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            sessionTimelines: sessionTimelines,
            transportTimeline: transportTimelineStorage
        )
    }

    public func restore(from snapshot: TimelineStoreSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        sessionTimelines = snapshot.sessionTimelines
        transportTimelineStorage = snapshot.transportTimeline
    }

    private func appendSessionItem(_ item: TimelineItem, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        var items = sessionTimelines[sessionId, default: []]
        if let insertIndex = items.firstIndex(where: { $0.timestamp > item.timestamp }) {
            items.insert(item, at: insertIndex)
        } else {
            items.append(item)
        }
        sessionTimelines[sessionId] = items
    }

    private static func nowMillis() -> Int {
        Int(Date().timeIntervalSince1970 * 1_000)
    }
}
