import Foundation
import CodePilotProtocol

public struct SessionStoreSnapshot: Codable, Equatable, Sendable {
    public let sessions: [SessionInfo]
    public let activeSessionId: String?
    public let draftsBySessionId: [String: String]
    public let idAliases: [String: String]
    public let lastAppliedEventIdBySessionID: [String: Int]

    enum CodingKeys: String, CodingKey {
        case sessions
        case activeSessionId
        case draftsBySessionId
        case idAliases
        case lastAppliedEventIdBySessionID
    }

    public init(
        sessions: [SessionInfo],
        activeSessionId: String?,
        draftsBySessionId: [String: String],
        idAliases: [String: String],
        lastAppliedEventIdBySessionID: [String: Int] = [:]
    ) {
        self.sessions = sessions
        self.activeSessionId = activeSessionId
        self.draftsBySessionId = draftsBySessionId
        self.idAliases = idAliases
        self.lastAppliedEventIdBySessionID = lastAppliedEventIdBySessionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessions = try container.decode([SessionInfo].self, forKey: .sessions)
        self.activeSessionId = try container.decodeIfPresent(String.self, forKey: .activeSessionId)
        self.draftsBySessionId = try container.decode([String: String].self, forKey: .draftsBySessionId)
        self.idAliases = try container.decode([String: String].self, forKey: .idAliases)
        self.lastAppliedEventIdBySessionID = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .lastAppliedEventIdBySessionID
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(activeSessionId, forKey: .activeSessionId)
        try container.encode(draftsBySessionId, forKey: .draftsBySessionId)
        try container.encode(idAliases, forKey: .idAliases)
        try container.encode(lastAppliedEventIdBySessionID, forKey: .lastAppliedEventIdBySessionID)
    }
}

public struct SessionIDRemap: Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public final class SessionStore {
    private let lock = NSLock()
    private var storageById: [String: SessionInfo] = [:]
    private var idAliases: [String: String] = [:]
    private var activeSessionIdStorage: String?
    private var draftsBySessionId: [String: String] = [:]
    private var lastAppliedEventIdBySessionID: [String: Int] = [:]

    public init() {}

    public var sessions: [SessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return storageById.values.sorted(by: sortSessions)
    }

    public var activeSessionId: String? {
        lock.lock()
        defer { lock.unlock() }
        return activeSessionIdStorage
    }

    public func session(for sessionId: String) -> SessionInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let resolved = resolveAliasLocked(sessionId) else {
            return nil
        }
        return storageById[resolved]
    }

    @discardableResult
    public func applySessionList(_ sessions: [SessionInfo]) -> [SessionIDRemap] {
        lock.lock()
        defer { lock.unlock() }

        let previousById = storageById
        let incomingById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let remaps = detectRemaps(previousById: previousById, incomingById: incomingById)
        for remap in remaps {
            applyRemapLocked(from: remap.from, to: remap.to)
        }

        // Merge incoming sessions, preserving local state when it's more recent.
        // The bridge may send session_list snapshots with stale state (e.g. "thinking")
        // while the iOS client has already received a turn_completed event setting "idle".
        var merged = previousById
        for remap in remaps {
            merged.removeValue(forKey: remap.from)
        }
        for (id, incoming) in incomingById {
            if let existing = previousById[id] ?? previousById[remaps.first(where: { $0.to == id })?.from ?? ""] {
                // Prefer the more recent terminal/busy state during reconnect merges.
                // session_list can lag behind events, but restored local snapshots can also
                // lag behind a session that is still actively running on the bridge.
                let localIsTerminal = existing.state == .idle || existing.state == .error
                let incomingIsBusy = incoming.state == .thinking || incoming.state == .coding
                    || incoming.state == .runningCommand || incoming.state == .waitingApproval
                if localIsTerminal && incomingIsBusy && existing.lastActiveAt >= incoming.lastActiveAt {
                    merged[id] = SessionInfo(
                        id: incoming.id,
                        agentType: incoming.agentType,
                        workDir: incoming.workDir,
                        state: existing.state,
                        createdAt: incoming.createdAt,
                        lastActiveAt: max(existing.lastActiveAt, incoming.lastActiveAt)
                    )
                    continue
                }
            }
            merged[id] = incoming
        }

        storageById = merged
        refreshActiveSessionAfterListUpdateLocked(remaps: remaps)
        return remaps
    }

    public func setActiveSession(id: String?) {
        lock.lock()
        defer { lock.unlock() }
        activeSessionIdStorage = resolveAliasLocked(id)
    }

    public func resolvedSessionId(for sessionId: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return resolveAliasLocked(sessionId)
    }

    public func upsert(_ session: SessionInfo) {
        lock.lock()
        defer { lock.unlock() }
        storageById[session.id] = session
    }

    public func updateState(for sessionId: String, state: AgentState) {
        lock.lock()
        defer { lock.unlock() }

        let id = resolveAliasLocked(sessionId) ?? sessionId
        if let existing = storageById[id] {
            storageById[id] = SessionInfo(
                id: existing.id,
                agentType: existing.agentType,
                workDir: existing.workDir,
                state: state,
                createdAt: existing.createdAt,
                lastActiveAt: Int(Date().timeIntervalSince1970 * 1_000)
            )
            return
        }

        storageById[id] = placeholderSession(id: id, state: state)
    }

    public func lastAppliedEventID(for sessionId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let id = resolveAliasLocked(sessionId) ?? sessionId
        return lastAppliedEventIdBySessionID[id]
    }

    public func recordAppliedEventID(_ eventId: Int, for sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        let id = resolveAliasLocked(sessionId) ?? sessionId
        lastAppliedEventIdBySessionID[id] = max(lastAppliedEventIdBySessionID[id] ?? Int.min, eventId)
    }

    @discardableResult
    public func applySessionRemap(from oldId: String, to newId: String) -> SessionIDRemap {
        lock.lock()
        defer { lock.unlock() }

        let remap = SessionIDRemap(from: oldId, to: newId)
        applyRemapLocked(from: oldId, to: newId)
        return remap
    }

    public func draft(for sessionId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let id = resolveAliasLocked(sessionId) else {
            return ""
        }
        return draftsBySessionId[id] ?? ""
    }

    public func setDraft(_ draft: String, for sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let id = resolveAliasLocked(sessionId) else {
            return
        }
        draftsBySessionId[id] = draft
    }

    public func removeSession(id: String) {
        lock.lock()
        defer { lock.unlock() }

        let resolved = resolveAliasLocked(id) ?? id
        storageById[resolved] = nil
        draftsBySessionId[resolved] = nil
        idAliases = idAliases.filter { alias, target in
            alias != resolved && target != resolved
        }

        if let active = activeSessionIdStorage {
            let resolvedActive = resolveAliasLocked(active) ?? active
            if resolvedActive == resolved {
                activeSessionIdStorage = storageById.values.sorted(by: sortSessions).first?.id
            }
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storageById.removeAll()
        idAliases.removeAll()
        activeSessionIdStorage = nil
        draftsBySessionId.removeAll()
        lastAppliedEventIdBySessionID.removeAll()
    }

    public func snapshot() -> SessionStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            sessions: storageById.values.sorted(by: sortSessions),
            activeSessionId: activeSessionIdStorage,
            draftsBySessionId: draftsBySessionId,
            idAliases: idAliases,
            lastAppliedEventIdBySessionID: lastAppliedEventIdBySessionID
        )
    }

    public func restore(from snapshot: SessionStoreSnapshot) {
        lock.lock()
        defer { lock.unlock() }

        storageById = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        draftsBySessionId = snapshot.draftsBySessionId
        idAliases = snapshot.idAliases
        activeSessionIdStorage = snapshot.activeSessionId
        lastAppliedEventIdBySessionID = snapshot.lastAppliedEventIdBySessionID

        if let active = activeSessionIdStorage {
            let resolved = resolveAliasLocked(active)
            if let resolved, storageById[resolved] != nil {
                activeSessionIdStorage = resolved
            } else if storageById[active] == nil {
                activeSessionIdStorage = nil
            }
        }
    }

    private func detectRemaps(
        previousById: [String: SessionInfo],
        incomingById: [String: SessionInfo]
    ) -> [SessionIDRemap] {
        var remaps: [SessionIDRemap] = []
        let missingPreviousIds = Set(previousById.keys).subtracting(incomingById.keys)
        guard !missingPreviousIds.isEmpty else {
            return remaps
        }

        let candidateOldSessions = missingPreviousIds.compactMap { previousById[$0] }
        for newSession in incomingById.values where previousById[newSession.id] == nil {
            if let oldSession = candidateOldSessions.first(where: { sameIdentity($0, newSession) }) {
                remaps.append(.init(from: oldSession.id, to: newSession.id))
            }
        }

        return remaps
    }

    private func sameIdentity(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        lhs.agentType == rhs.agentType &&
            lhs.workDir == rhs.workDir &&
            lhs.createdAt == rhs.createdAt
    }

    private func applyRemapLocked(from oldId: String, to newId: String) {
        guard oldId != newId else {
            return
        }

        if let existing = storageById.removeValue(forKey: oldId) {
            storageById[newId] = SessionInfo(
                id: newId,
                agentType: existing.agentType,
                workDir: existing.workDir,
                state: existing.state,
                createdAt: existing.createdAt,
                lastActiveAt: existing.lastActiveAt
            )
        }

        idAliases[oldId] = newId
        for (alias, target) in idAliases where target == oldId {
            idAliases[alias] = newId
        }

        if let draft = draftsBySessionId.removeValue(forKey: oldId) {
            draftsBySessionId[newId] = draft
        }

        if let eventId = lastAppliedEventIdBySessionID.removeValue(forKey: oldId) {
            lastAppliedEventIdBySessionID[newId] = max(lastAppliedEventIdBySessionID[newId] ?? Int.min, eventId)
        }

        if activeSessionIdStorage == oldId {
            activeSessionIdStorage = newId
        }
    }

    private func refreshActiveSessionAfterListUpdateLocked(remaps: [SessionIDRemap]) {
        if let active = activeSessionIdStorage {
            if let resolved = resolveAliasLocked(active), storageById[resolved] != nil {
                activeSessionIdStorage = resolved
                return
            }
            if let remapped = remaps.first(where: { $0.from == active })?.to, storageById[remapped] != nil {
                activeSessionIdStorage = remapped
                return
            }
        }

        activeSessionIdStorage = storageById.values.sorted(by: sortSessions).first?.id
    }

    private func resolveAliasLocked(_ sessionId: String?) -> String? {
        guard var current = sessionId else {
            return nil
        }
        var visited: Set<String> = []
        while let next = idAliases[current], !visited.contains(current) {
            visited.insert(current)
            current = next
        }
        return current
    }

    private func sortSessions(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        if lhs.lastActiveAt != rhs.lastActiveAt {
            return lhs.lastActiveAt > rhs.lastActiveAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    private func placeholderSession(id: String, state: AgentState) -> SessionInfo {
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        return .init(
            id: id,
            agentType: .codex,
            workDir: "",
            state: state,
            createdAt: now,
            lastActiveAt: now
        )
    }
}
