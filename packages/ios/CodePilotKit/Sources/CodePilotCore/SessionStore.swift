import Foundation
import CodePilotProtocol

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
        var merged: [String: SessionInfo] = [:]
        for (id, incoming) in incomingById {
            if let existing = previousById[id] ?? previousById[remaps.first(where: { $0.to == id })?.from ?? ""] {
                // If we locally know the session is idle/error but server says busy, keep local state
                let localIsTerminal = existing.state == .idle || existing.state == .error
                let incomingIsBusy = incoming.state == .thinking || incoming.state == .coding
                    || incoming.state == .runningCommand || incoming.state == .waitingApproval
                if localIsTerminal && incomingIsBusy {
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

        idAliases[oldId] = newId
        for (alias, target) in idAliases where target == oldId {
            idAliases[alias] = newId
        }

        if let draft = draftsBySessionId.removeValue(forKey: oldId) {
            draftsBySessionId[newId] = draft
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
