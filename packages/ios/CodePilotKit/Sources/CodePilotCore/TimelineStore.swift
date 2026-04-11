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
    private enum StreamingTextKind {
        case thinking
        case agentMessage

        func itemKind(text: String) -> TimelineItem.Kind {
            switch self {
            case .thinking:
                return .thinking(text: text)
            case .agentMessage:
                return .agentMessage(text: text)
            }
        }
    }

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

    public func appendBridgeEvent(sessionId: String, event: AgentEvent, timestamp: Int, eventId: Int? = nil) {
        switch event {
        case let .status(state, message):
            appendSessionItem(
                .init(eventId: eventId, timestamp: timestamp, kind: .status(state: state, message: message)),
                sessionId: sessionId
            )
        case let .thinking(text):
            upsertStreamingText(
                sessionId: sessionId,
                incomingText: text,
                timestamp: timestamp,
                eventId: eventId,
                kind: .thinking
            )
        case let .codeChange(changes):
            appendSessionItem(
                .init(eventId: eventId, timestamp: timestamp, kind: .codeChange(changes: changes)),
                sessionId: sessionId
            )
        case let .commandExec(command, output, exitCode, status):
            upsertCommandExec(
                sessionId: sessionId,
                command: command,
                output: output,
                exitCode: exitCode,
                status: status,
                timestamp: timestamp,
                eventId: eventId
            )
        case let .agentMessage(text):
            upsertStreamingText(
                sessionId: sessionId,
                incomingText: text,
                timestamp: timestamp,
                eventId: eventId,
                kind: .agentMessage
            )
        case let .error(message):
            appendSessionItem(
                .init(eventId: eventId, timestamp: timestamp, kind: .sessionError(message: message)),
                sessionId: sessionId
            )
        case let .turnCompleted(summary, filesChanged, usage):
            appendSessionItem(
                .init(
                    eventId: eventId,
                    timestamp: timestamp,
                    kind: .turnCompleted(summary: summary, filesChanged: filesChanged, usage: usage)
                ),
                sessionId: sessionId
            )
        }
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
        insertSessionItem(item, into: &items)
        sessionTimelines[sessionId] = items
    }

    private func upsertCommandExec(
        sessionId: String,
        command: String,
        output: String?,
        exitCode: Int?,
        status: CommandExecStatus,
        timestamp: Int,
        eventId: Int?
    ) {
        lock.lock()
        defer { lock.unlock() }

        var items = sessionTimelines[sessionId, default: []]

        // Bridge command events do not carry a command id, so we only collapse the
        // most recent in-flight copy of the same command.
        if let existingIndex = items.lastIndex(where: {
            guard case let .commandExec(existingCommand, _, _, existingStatus) = $0.kind else {
                return false
            }
            return existingCommand == command && existingStatus == .running
        }) {
            let previousPayload = commandExecPayload(from: items[existingIndex].kind)
            items[existingIndex] = .init(
                eventId: eventId ?? items[existingIndex].eventId,
                timestamp: items[existingIndex].timestamp,
                kind: .commandExec(
                    command: command,
                    output: mergeStreamingText(previous: previousPayload?.output, incoming: output),
                    exitCode: exitCode ?? previousPayload?.exitCode,
                    status: status
                )
            )
        } else {
            insertSessionItem(
                .init(
                    eventId: eventId,
                    timestamp: timestamp,
                    kind: .commandExec(command: command, output: output, exitCode: exitCode, status: status)
                ),
                into: &items
            )
        }

        sessionTimelines[sessionId] = items
    }

    private func upsertStreamingText(
        sessionId: String,
        incomingText: String,
        timestamp: Int,
        eventId: Int?,
        kind: StreamingTextKind
    ) {
        guard !incomingText.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        var items = sessionTimelines[sessionId, default: []]
        if let lastIndex = items.indices.last,
           items[lastIndex].timestamp <= timestamp,
           let previousText = streamingText(from: items[lastIndex].kind, matching: kind)
        {
            let mergedText = mergeStreamingText(previous: previousText, incoming: incomingText) ?? previousText
            items[lastIndex] = .init(
                eventId: eventId ?? items[lastIndex].eventId,
                timestamp: items[lastIndex].timestamp,
                kind: kind.itemKind(text: mergedText)
            )
        } else {
            insertSessionItem(
                .init(eventId: eventId, timestamp: timestamp, kind: kind.itemKind(text: incomingText)),
                into: &items
            )
        }

        sessionTimelines[sessionId] = items
    }

    private func insertSessionItem(_ item: TimelineItem, into items: inout [TimelineItem]) {
        if let insertIndex = items.firstIndex(where: { $0.timestamp > item.timestamp }) {
            items.insert(item, at: insertIndex)
        } else {
            items.append(item)
        }
    }

    private func commandExecPayload(
        from kind: TimelineItem.Kind
    ) -> (command: String, output: String?, exitCode: Int?, status: CommandExecStatus)? {
        guard case let .commandExec(command, output, exitCode, status) = kind else {
            return nil
        }
        return (command, output, exitCode, status)
    }

    private func streamingText(
        from kind: TimelineItem.Kind,
        matching expectedKind: StreamingTextKind
    ) -> String? {
        switch (kind, expectedKind) {
        case let (.agentMessage(text), .agentMessage):
            return text
        case let (.thinking(text), .thinking):
            return text
        default:
            return nil
        }
    }

    private func mergeStreamingText(previous: String?, incoming: String?) -> String? {
        guard let incoming else {
            return previous
        }
        guard let previous else {
            return incoming
        }
        guard !incoming.isEmpty else {
            return previous
        }
        if incoming == previous {
            return previous
        }
        if incoming.hasPrefix(previous) {
            return incoming
        }
        if previous.hasPrefix(incoming) {
            return previous
        }
        return previous + incoming
    }

    private static func nowMillis() -> Int {
        Int(Date().timeIntervalSince1970 * 1_000)
    }
}
