import SwiftUI
import CodePilotCore
import CodePilotFeatures
import CodePilotProtocol

struct RootView: View {
    @StateObject private var appModel: AppModel

    @MainActor
    init() {
        _appModel = StateObject(wrappedValue: AppModel())
    }

    @MainActor
    init(appModel: AppModel) {
        _appModel = StateObject(wrappedValue: appModel)
    }

    var body: some View {
        ProjectsView()
            .environmentObject(appModel)
    }
}

// MARK: - ConnectionSlot

private struct ConnectionSlot {
    let savedConnectionID: String
    let config: ConnectionConfig
    let controller: BridgeConnectionController
    let router: SessionMessageRouter
    var summary: String = "Disconnected"
    var shouldBootstrapReplay: Bool = false
    var supportsSessionReplay: Bool = false
    var reconnectBootstrapSeedSessionIDs: [String] = []
    var confirmedSessionIDs: Set<String> = []
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var activeSessionID: String?
    @Published private(set) var diagnosticsRedactedLines: [String] = []
    @Published private(set) var latestLatencyMs: Int?
    @Published private(set) var transportTimeline: [TimelineItem] = []
    @Published private(set) var savedConnections: [SavedConnection] = []
    @Published private(set) var selectedSavedConnectionID: String?
    @Published private(set) var currentConnectionSummary: String = "Disconnected"
    @Published private(set) var slotStates: [String: String] = [:]
    @Published private(set) var sessionNavigationTargets: [String: String] = [:]
    @Published private(set) var slashCatalogsByConnectionID: [String: SlashCatalogMessage] = [:]
    @Published private(set) var latestSlashActionResultsByConnectionID: [String: SlashActionResultMessage] = [:]
    @Published var latestErrorMessage: String?

    private let sessionStore: SessionStore
    private let timelineStore: TimelineStore
    private let fileStore: FileStore
    private let fileSearchStore: FileSearchStore
    private let diffStore: DiffStore
    private let diagnosticsStore: DiagnosticsStore
    private let slashCatalogStore: SlashCatalogStore
    private let diagnosticsViewModel: DiagnosticsViewModel
    private let savedConnectionStore: SavedConnectionStore
    private let conversationSnapshotStore: ConversationSnapshotStore
    private let connectionsViewModel: ConnectionsViewModel
    private let pendingSessionCoordinator: PendingSessionCoordinator
    private let sessionReplayCoordinator: SessionReplayCoordinator
    private let persistsSavedConnections: Bool
    private let persistsConversationState: Bool

    // Runtime connection state.
    // We keep multiple saved configurations, but only allow one live bridge
    // connection at a time so session and file routing stay unambiguous.
    private var slots: [String: ConnectionSlot] = [:]
    private var sessionToSlotID: [String: String] = [:]
    private var pingTimer: Timer?
    private let conversationPersistenceQueue = DispatchQueue(
        label: "ctunnel.conversation-persistence",
        qos: .utility
    )
    private var pendingConversationPersistenceWorkItem: DispatchWorkItem?
    #if DEBUG
    private var uiTestHarness: AnyObject?
    #endif

    // Fallback stub sender for preview / offline use
    private var stubSender: InMemoryPhoneMessageSender?

    private var activeSlotID: String? {
        slots.keys.first
    }

    convenience init() {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let fileSearchStore = FileSearchStore()
        let diffStore = DiffStore()
        let diagnosticsStore = DiagnosticsStore()
        let slashCatalogStore = SlashCatalogStore()
        let diagnosticsViewModel = DiagnosticsViewModel(diagnosticsStore: diagnosticsStore)
        let savedConnectionStore = SavedConnectionStore()
        let conversationSnapshotStore = ConversationSnapshotStore()
        let restoredConversationSnapshot = conversationSnapshotStore.loadSnapshot()
        let stubSender = InMemoryPhoneMessageSender()
        let restoredSnapshot = savedConnectionStore.loadSnapshot()
        let initialSnapshot: SavedConnectionsSnapshot
        if restoredSnapshot.connections.isEmpty {
            initialSnapshot = .init(
                connections: Self.defaultSavedConnections(),
                selectedConnectionID: nil
            )
        } else {
            initialSnapshot = restoredSnapshot
        }
        let connectionsViewModel = ConnectionsViewModel(savedConnections: initialSnapshot.connections)
        _ = connectionsViewModel.selectSavedConnection(id: initialSnapshot.selectedConnectionID)
        let pendingSessionCoordinator = PendingSessionCoordinator()
        let sessionReplayCoordinator = SessionReplayCoordinator()

        if let restoredConversationSnapshot {
            sessionStore.restore(from: restoredConversationSnapshot.sessionStore)
            timelineStore.restore(from: restoredConversationSnapshot.timelineStore)
            fileStore.restore(from: restoredConversationSnapshot.fileStore)
        }

        self.init(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            fileSearchStore: fileSearchStore,
            diffStore: diffStore,
            diagnosticsStore: diagnosticsStore,
            slashCatalogStore: slashCatalogStore,
            diagnosticsViewModel: diagnosticsViewModel,
            savedConnectionStore: savedConnectionStore,
            conversationSnapshotStore: conversationSnapshotStore,
            stubSender: stubSender,
            connectionsViewModel: connectionsViewModel,
            pendingSessionCoordinator: pendingSessionCoordinator,
            sessionReplayCoordinator: sessionReplayCoordinator,
            currentConnectionSummary: "Disconnected",
            latestErrorMessage: nil,
            persistsSavedConnections: true,
            persistsConversationState: true
        )

        if let restoredConversationSnapshot {
            sessionToSlotID = restoredConversationSnapshot.sessionToConnectionID
            diagnosticsStore.recordInfo(
                "restored_snapshot sessions=\(Self.describeSessionIDs(restoredConversationSnapshot.sessionStore.sessions.map(\.id))) active=\(restoredConversationSnapshot.sessionStore.activeSessionId ?? "nil") mappings=\(Self.describeSessionMapping(restoredConversationSnapshot.sessionToConnectionID))"
            )
            refreshPublishedState()
        }

        if restoredSnapshot.connections.isEmpty {
            do {
                try savedConnectionStore.saveSnapshot(
                    .init(
                        connections: initialSnapshot.connections,
                        selectedConnectionID: connectionsViewModel.selectedSavedConnectionID
                    )
                )
            } catch {
                diagnosticsStore.recordError("save defaults failed: \(error.localizedDescription)")
                refreshPublishedState()
            }
        }
    }

    private init(
        sessionStore: SessionStore,
        timelineStore: TimelineStore,
        fileStore: FileStore,
        fileSearchStore: FileSearchStore,
        diffStore: DiffStore,
        diagnosticsStore: DiagnosticsStore,
        slashCatalogStore: SlashCatalogStore,
        diagnosticsViewModel: DiagnosticsViewModel,
        savedConnectionStore: SavedConnectionStore,
        conversationSnapshotStore: ConversationSnapshotStore,
        stubSender: InMemoryPhoneMessageSender?,
        connectionsViewModel: ConnectionsViewModel,
        pendingSessionCoordinator: PendingSessionCoordinator,
        sessionReplayCoordinator: SessionReplayCoordinator,
        currentConnectionSummary: String,
        latestErrorMessage: String?,
        persistsSavedConnections: Bool,
        persistsConversationState: Bool
    ) {
        self.sessionStore = sessionStore
        self.timelineStore = timelineStore
        self.fileStore = fileStore
        self.fileSearchStore = fileSearchStore
        self.diffStore = diffStore
        self.diagnosticsStore = diagnosticsStore
        self.slashCatalogStore = slashCatalogStore
        self.diagnosticsViewModel = diagnosticsViewModel
        self.savedConnectionStore = savedConnectionStore
        self.conversationSnapshotStore = conversationSnapshotStore
        self.stubSender = stubSender
        self.connectionsViewModel = connectionsViewModel
        self.pendingSessionCoordinator = pendingSessionCoordinator
        self.sessionReplayCoordinator = sessionReplayCoordinator
        self.currentConnectionSummary = currentConnectionSummary
        self.latestErrorMessage = latestErrorMessage
        self.persistsSavedConnections = persistsSavedConnections
        self.persistsConversationState = persistsConversationState

        refreshPublishedState()
    }

    // MARK: - Connection Management (public API)

    func parseConnectionPayload(_ payload: String) throws -> ConnectionConfig {
        try connectionsViewModel.parsePayload(payload)
    }

    @discardableResult
    func selectSavedConnection(id: String?) -> ConnectionConfig? {
        let selected = connectionsViewModel.selectSavedConnection(id: id)
        persistSavedConnections()
        latestErrorMessage = nil
        refreshPublishedState()
        return selected
    }

    /// Connect a saved connection by its ID.
    /// Self-use mode keeps only one live connection at a time.
    func connectSavedConnection(id: String) {
        guard let saved = connectionsViewModel.savedConnections.first(where: { $0.id == id }) else {
            latestErrorMessage = "Connection not found."
            refreshPublishedState()
            return
        }

        _ = selectSavedConnection(id: id)
        let restoredSessionIDs = knownSessionIDs(for: id)
        disconnectAllRuntimeConnections()

        let config = saved.config
        let socketURL = socketURLString(for: config)
        guard let url = URL(string: socketURL) else {
            latestErrorMessage = "Invalid connection URL."
            diagnosticsStore.recordError("invalid URL: \(socketURL)")
            refreshPublishedState()
            return
        }

        diagnosticsStore.recordInfo("[\(saved.name)] connecting: \(socketURL)")
        diagnosticsStore.recordInfo("[\(saved.name)] connection_id: \(id)")
        diagnosticsStore.recordInfo("[\(saved.name)] config: \(Self.describeConnectionConfig(config))")
        diagnosticsStore.recordInfo("[\(saved.name)] bridge_pubkey: \(config.bridgePublicKey.prefix(12))...")
        diagnosticsStore.recordInfo("[\(saved.name)] otp: \(config.otp)")
        timelineStore.appendSystem("connecting: \(socketURL)", sessionId: nil)
        latestErrorMessage = nil

        // Create transport & controller
        let transport = NWBridgeTransport(url: url)
        let controller = BridgeConnectionController(
            config: config,
            transport: transport,
            diagnostics: diagnosticsStore
        )

        // Create message router (shared stores)
        let router = SessionMessageRouter(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            fileSearchStore: fileSearchStore,
            diffStore: diffStore,
            diagnostics: diagnosticsStore,
            slashCatalogStore: slashCatalogStore,
            connectionID: id
        )

        var slot = ConnectionSlot(
            savedConnectionID: id,
            config: config,
            controller: controller,
            router: router,
            summary: "Connecting..."
        )
        slot.reconnectBootstrapSeedSessionIDs = restoredSessionIDs

        let slotID = id

        router.onReplayNeeded = { [weak self] sessionID, afterEventId in
            Task { @MainActor [weak self] in
                self?.handleReplayNeeded(
                    slotID: slotID,
                    sessionID: sessionID,
                    afterEventId: afterEventId
                )
            }
        }

        // Wire up callbacks
        controller.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleSlotStateChange(slotID: slotID, state: state)
            }
        }

        controller.onBridgeMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleSlotBridgeMessage(slotID: slotID, message: message)
            }
        }

        // Connect
        do {
            try controller.connect()
            diagnosticsStore.recordInfo("[\(saved.name)] connect() returned successfully")
        } catch {
            diagnosticsStore.recordError("[\(saved.name)] connect() threw: \(error)")
            latestErrorMessage = "Connection failed: \(error.localizedDescription)"
            slot.summary = "Disconnected"
        }

        slots[id] = slot
        ensurePingTimer()
        refreshPublishedState()
    }

    /// Legacy connect API — finds or creates a saved connection, then connects it.
    func connect(using config: ConnectionConfig) {
        // Find matching saved connection or use selected
        if let selectedID = connectionsViewModel.selectedSavedConnectionID {
            connectSavedConnection(id: selectedID)
        } else if let first = connectionsViewModel.savedConnections.first {
            connectSavedConnection(id: first.id)
        }
    }

    /// Add a new saved connection and immediately connect it.
    func addAndConnectSavedConnection(id: String, name: String, config: ConnectionConfig) {
        let newConnection = SavedConnection(id: id, name: name, config: config)
        var connections = connectionsViewModel.savedConnections
        connections.append(newConnection)
        connectionsViewModel.replaceSavedConnections(connections, selectedConnectionID: id)
        persistSavedConnections()
        refreshPublishedState()
        connectSavedConnection(id: id)
    }

    func updateSavedConnection(id: String, payload: String) throws {
        let config = try connectionsViewModel.parsePayload(payload)
        try updateSavedConnection(id: id, config: config)
    }

    func updateSavedConnection(id: String, config: ConnectionConfig) throws {
        guard let index = connectionsViewModel.savedConnections.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.connectionNotFound
        }

        let existing = connectionsViewModel.savedConnections[index]
        var connections = connectionsViewModel.savedConnections
        connections[index] = SavedConnection(
            id: existing.id,
            name: existing.name,
            config: config
        )
        connectionsViewModel.replaceSavedConnections(connections, selectedConnectionID: id)
        persistSavedConnections()
        latestErrorMessage = nil
        refreshPublishedState()
        connectSavedConnection(id: id)
    }

    func disconnectSavedConnection(id: String) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.controller.disconnect()
        pendingSessionCoordinator.clearPendingCommand(for: id)
        sessionReplayCoordinator.reset(for: id)
        clearSessionNavigationTarget(for: id)
        if slots.isEmpty {
            stopPingTimer()
        }
        refreshPublishedState()
    }

    func disconnectAll() {
        disconnectAllRuntimeConnections()
        refreshPublishedState()
    }

    func disconnect() {
        disconnectAll()
    }

    func isSlotConnected(_ savedConnectionID: String) -> Bool {
        guard let slot = slots[savedConnectionID] else { return false }
        if case .connected = slot.controller.state { return true }
        return false
    }

    func slotSummary(for savedConnectionID: String) -> String {
        slots[savedConnectionID]?.summary ?? "Disconnected"
    }

    /// Returns IDs of all currently connected slots.
    var connectedSlotIDs: [String] {
        guard let activeSlotID, let slot = slots[activeSlotID] else {
            return []
        }
        if case .connected = slot.controller.state {
            return [activeSlotID]
        }
        return []
    }

    // MARK: - Session Management

    func refreshSessions() {
        guard let activeSlotID, let slot = slots[activeSlotID], case .connected = slot.controller.state else {
            if !slots.isEmpty {
                latestErrorMessage = "Unable to refresh sessions."
                refreshPublishedState()
            }
            return
        }

        do {
            try slot.controller.send(.listSessions)
            latestErrorMessage = nil
        } catch {
            latestErrorMessage = "Unable to refresh sessions."
            diagnosticsStore.recordError("refresh sessions failed: \(error.localizedDescription)")
        }
        refreshPublishedState()
    }

    /// Refresh sessions for a specific connection.
    func refreshSessionsForConnection(_ connectionID: String) {
        guard let slot = slots[connectionID], case .connected = slot.controller.state else {
            return
        }
        do {
            try slot.controller.send(.listSessions)
        } catch {
            diagnosticsStore.recordError("[\(connectionID)] refresh sessions failed: \(error.localizedDescription)")
        }
        refreshPublishedState()
    }

    /// Return sessions that belong to a specific connection.
    func sessionsForConnection(_ connectionID: String) -> [SessionInfo] {
        return sessions.filter { session in
            if sessionToSlotID[session.id] == connectionID {
                return true
            }
            return false
        }
    }

    /// Find an existing saved connection that matches the given config.
    func findExistingSavedConnectionID(for config: ConnectionConfig) -> String? {
        for saved in savedConnections {
            switch (saved.config, config) {
            case let (.lan(h1, p1, _, _, _), .lan(h2, p2, _, _, _)):
                if h1 == h2 && p1 == p2 { return saved.id }
            case let (.relay(u1, c1, _, _), .relay(u2, c2, _, _)):
                if u1 == u2 && c1 == c2 { return saved.id }
            default:
                break
            }
        }
        return nil
    }

    /// Delete saved connections at given offsets.
    func deleteSavedConnections(at offsets: IndexSet) {
        var connections = connectionsViewModel.savedConnections
        for offset in offsets {
            let id = connections[offset].id
            disconnectSavedConnection(id: id)
            slashCatalogStore.removeConnection(id: id)
        }
        connections.remove(atOffsets: offsets)
        connectionsViewModel.replaceSavedConnections(connections, selectedConnectionID: connectionsViewModel.selectedSavedConnectionID)
        persistSavedConnections()
        refreshPublishedState()
    }

    func deleteSavedConnection(id: String) {
        disconnectSavedConnection(id: id)
        slashCatalogStore.removeConnection(id: id)
        var connections = connectionsViewModel.savedConnections
        connections.removeAll { $0.id == id }
        connectionsViewModel.replaceSavedConnections(connections, selectedConnectionID: connectionsViewModel.selectedSavedConnectionID)
        persistSavedConnections()
        refreshPublishedState()
    }

    func selectSession(id: String?) {
        sessionStore.setActiveSession(id: id)
        refreshPublishedState()
    }

    func session(for sessionID: String) -> SessionInfo? {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        return sessions.first(where: { $0.id == resolvedSessionID })
    }

    /// Send a command without a sessionId — Bridge will create a new session.
    func sendNewSessionCommand(_ text: String, connectionID: String? = nil, config: SessionConfig? = nil) throws {
        let targetID = connectionID ?? connectedSlotIDs.first
        guard let slotID = targetID, let slot = slots[slotID] else {
            throw AppModelError.noActiveConnection
        }
        let wireConfig = config?.isEmpty == true ? nil : config
        try slot.controller.send(.command(text: text, sessionId: nil, config: wireConfig))
        pendingSessionCoordinator.registerPendingCommand(text, for: slotID)
        clearSessionNavigationTarget(for: slotID)
        diagnosticsStore.recordInfo("new session command sent to \(slotID): \(text.prefix(40))")
        refreshPublishedState()
    }

    func timeline(for sessionID: String) -> [TimelineItem] {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        return timelineStore.timeline(for: resolvedSessionID)
    }

    func files(for sessionID: String) -> [FileState] {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        return fileStore.files(for: resolvedSessionID)
    }

    func fileState(for sessionID: String, path: String) -> FileState? {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        return fileStore.fileState(for: path, sessionId: resolvedSessionID)
    }

    func fileSearchState(for sessionID: String) -> FileSearchState? {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        return fileSearchStore.state(for: resolvedSessionID)
    }

    func makeSessionDetailViewModel(sessionID: String) -> SessionDetailViewModel {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        // Find the controller for this session's connection
        let sender: PhoneMessageSending
        if let slotID = sessionToSlotID[resolvedSessionID] ?? sessionToSlotID[sessionID], let slot = slots[slotID] {
            sender = slot.controller
        } else if let firstConnected = slots.values.first(where: {
            if case .connected = $0.controller.state { return true }
            return false
        }) {
            sender = firstConnected.controller
        } else {
            sender = stubSender ?? InMemoryPhoneMessageSender()
        }

        return .init(
            sender: sender,
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            fileSearchStore: fileSearchStore,
            diffStore: diffStore,
            sessionId: resolvedSessionID
        )
    }

    func diffState(for sessionID: String, eventID: Int) -> DiffState? {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        return diffStore.state(for: resolvedSessionID, eventId: eventID)
    }

    func deleteSession(id: String) throws {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: id) ?? id
        let targetSlotID = sessionToSlotID[resolvedSessionID] ?? sessionToSlotID[id]

        guard
            let targetSlotID,
            let slot = slots[targetSlotID],
            case .connected = slot.controller.state
        else {
            throw AppModelError.sessionConnectionUnavailable
        }

        try slot.controller.send(.deleteSession(sessionId: resolvedSessionID))
        removeSessionLocally(resolvedSessionID, connectionID: targetSlotID)
        latestErrorMessage = nil
        refreshPublishedState()
    }

    func sessionNavigationTarget(for connectionID: String) -> String? {
        sessionNavigationTargets[connectionID]
    }

    func slashCatalog(for connectionID: String) -> SlashCatalogMessage? {
        slashCatalogsByConnectionID[connectionID]
    }

    func slashCatalog(forSessionID sessionID: String?) -> SlashCatalogMessage? {
        guard let sessionID else {
            guard let activeSlotID else { return nil }
            return slashCatalog(for: activeSlotID)
        }

        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        if let connectionID = sessionToSlotID[resolvedSessionID] ?? sessionToSlotID[sessionID] {
            return slashCatalog(for: connectionID)
        }

        guard let activeSlotID else { return nil }
        return slashCatalog(for: activeSlotID)
    }

    func connectionID(forSessionID sessionID: String) -> String? {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        return sessionToSlotID[resolvedSessionID] ?? sessionToSlotID[sessionID] ?? activeSlotID
    }

    func latestSlashActionResult(for connectionID: String) -> SlashActionResultMessage? {
        latestSlashActionResultsByConnectionID[connectionID]
    }

    func sendSlashAction(_ message: SlashActionMessage, connectionID: String) throws {
        guard
            let slot = slots[connectionID],
            case .connected = slot.controller.state
        else {
            throw AppModelError.noActiveConnection
        }

        try slot.controller.send(.slashAction(message))
        latestErrorMessage = nil
        refreshPublishedState()
    }

    func consumeSessionNavigationTarget(for connectionID: String) {
        clearSessionNavigationTarget(for: connectionID)
    }

    func refreshPublishedState() {
        sessions = sessionStore.sessions
        activeSessionID = sessionStore.activeSessionId
        diagnosticsViewModel.refresh()
        diagnosticsRedactedLines = diagnosticsViewModel.redactedLines
        latestLatencyMs = diagnosticsViewModel.latestLatencyMs
        transportTimeline = timelineStore.transportTimeline
        savedConnections = connectionsViewModel.savedConnections
        selectedSavedConnectionID = connectionsViewModel.selectedSavedConnectionID

        // Aggregate connection summaries
        var states: [String: String] = [:]
        for saved in connectionsViewModel.savedConnections {
            states[saved.id] = slots[saved.id]?.summary ?? "Disconnected"
        }
        slotStates = states
        slashCatalogsByConnectionID = slashCatalogStore.catalogsByConnectionID
        latestSlashActionResultsByConnectionID = slashCatalogStore.latestActionResultsByConnectionID

        if let activeSlotID, let slot = slots[activeSlotID] {
            currentConnectionSummary = slot.summary
        } else {
            currentConnectionSummary = "Disconnected"
        }

        persistConversationState()
    }

    // MARK: - Slot State Handling

    private func handleSlotStateChange(slotID: String, state: ConnectionState) {
        guard slots[slotID] != nil else { return }

        diagnosticsStore.recordInfo("[\(slotID)] state → \(state)")

        switch state {
        case .disconnected:
            slots[slotID]?.summary = "Disconnected"
            slots[slotID]?.shouldBootstrapReplay = false
            slots[slotID]?.supportsSessionReplay = false
            slots[slotID]?.confirmedSessionIDs = []
            sessionReplayCoordinator.reset(for: slotID)
        case .connecting:
            slots[slotID]?.summary = "Connecting..."
            slots[slotID]?.shouldBootstrapReplay = false
            slots[slotID]?.supportsSessionReplay = false
            slots[slotID]?.confirmedSessionIDs = []
        case .reconnecting:
            slots[slotID]?.summary = "Reconnecting..."
            slots[slotID]?.shouldBootstrapReplay = false
            slots[slotID]?.supportsSessionReplay = false
            slots[slotID]?.confirmedSessionIDs = []
            sessionReplayCoordinator.reset(for: slotID)
        case let .connected(encrypted, clientId):
            let mode = encrypted ? "encrypted" : "plaintext"
            let replaySupported = slots[slotID]?.controller.supportsSessionReplay ?? false
            slots[slotID]?.summary = "Connected (\(mode))"
            slots[slotID]?.supportsSessionReplay = replaySupported
            slots[slotID]?.shouldBootstrapReplay = replaySupported
            diagnosticsStore.recordInfo("[\(slotID)] connected clientId=\(clientId ?? "nil") encrypted=\(encrypted)")
            if !replaySupported {
                diagnosticsStore.recordInfo("[\(slotID)] session replay unavailable; reconnect recovery disabled")
            }
            // Auto-request session list
            if let slot = slots[slotID] {
                do {
                    try slot.controller.send(.listSessions)
                } catch {
                    diagnosticsStore.recordError("[\(slotID)] list_sessions failed: \(error)")
                }
            }
        case let .failed(reason):
            slots[slotID]?.summary = "Failed: \(reason)"
            latestErrorMessage = reason
        }
        refreshPublishedState()
    }

    private func handleSlotBridgeMessage(slotID: String, message: BridgeMessage) {
        guard let slot = slots[slotID] else { return }
        normalizeSessionToSlotMappings(for: slotID)
        let confirmedSessionIDs = slots[slotID]?.confirmedSessionIDs ?? []
        let previouslyMappedSessionIDs = Array(confirmedSessionIDs).sorted()
        let restoredSessionIDs = slots[slotID]?.reconnectBootstrapSeedSessionIDs ?? sessionStore.sessions.map(\.id)

        switch message {
        case let .sessionList(sessions):
            slot.router.handle(message)
            diagnosticsStore.recordInfo(
                "[\(slotID)] session_list incoming=\(Self.describeSessions(sessions)) prevMapped=\(Self.describeSessionIDs(previouslyMappedSessionIDs)) restored=\(Self.describeSessionIDs(restoredSessionIDs))"
            )
            for session in sessions {
                sessionToSlotID[session.id] = slotID
            }
            slots[slotID]?.confirmedSessionIDs = Set(sessions.map(\.id))
            normalizeSessionToSlotMappings(for: slotID)
            if let resolution = pendingSessionCoordinator.resolvePendingCommand(
                for: slotID,
                knownSessionIDs: previouslyMappedSessionIDs,
                incomingSessions: sessions
            ) {
                applyPendingSessionResolution(resolution)
            }
            if slots[slotID]?.shouldBootstrapReplay == true {
                let replaySessionIDs = SessionReplayBootstrapPlanner.sessionIDsForReconnect(
                    restoredSessionIDs: restoredSessionIDs,
                    previouslyMappedSessionIDs: previouslyMappedSessionIDs,
                    currentMappedSessionIDs: knownSessionIDs(for: slotID)
                ) { sessionID in
                    sessionStore.resolvedSessionId(for: sessionID)
                }
                diagnosticsStore.recordInfo(
                    "[\(slotID)] replay_bootstrap planned=\(Self.describeSessionIDs(replaySessionIDs)) currentMapped=\(Self.describeSessionIDs(knownSessionIDs(for: slotID)))"
                )
                requestReplayBootstrap(
                    for: slotID,
                    sessionIDs: replaySessionIDs
                )
                slots[slotID]?.reconnectBootstrapSeedSessionIDs = []
                slots[slotID]?.shouldBootstrapReplay = false
            }

        case let .event(sessionId, _, _, _):
            let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionId) ?? sessionId
            let resolution = pendingSessionCoordinator.resolvePendingCommand(
                for: slotID,
                knownSessionIDs: previouslyMappedSessionIDs,
                incomingEventSessionID: resolvedSessionID
            )
            if let resolution {
                applyPendingSessionResolution(resolution)
            }
            let isConfirmedSession = confirmedSessionIDs.contains(resolvedSessionID)
                || confirmedSessionIDs.contains(sessionId)
            let isExpectedReplaySession = sessionReplayCoordinator.hasInFlightSync(for: slotID, sessionID: resolvedSessionID)
                || sessionReplayCoordinator.hasInFlightSync(for: slotID, sessionID: sessionId)
            let shouldBindEventSession = resolution != nil
                || isConfirmedSession
                || isExpectedReplaySession
            if shouldBindEventSession {
                slot.router.handle(message)
                sessionToSlotID[resolvedSessionID] = slotID
                diagnosticsStore.recordInfo("[\(slotID)] event mapped_session=\(resolvedSessionID)")
            } else {
                diagnosticsStore.recordInfo("[\(slotID)] ignored_unmapped_session=\(resolvedSessionID)")
            }

        case let .sessionSyncComplete(sessionId, _, resolvedSessionId):
            let resolvedSessionID = resolvedSessionId ?? sessionId
            let isConfirmedSession = confirmedSessionIDs.contains(resolvedSessionID)
                || confirmedSessionIDs.contains(sessionId)
            let isExpectedReplaySession = sessionReplayCoordinator.hasInFlightSync(for: slotID, sessionID: resolvedSessionID)
                || sessionReplayCoordinator.hasInFlightSync(for: slotID, sessionID: sessionId)
            let shouldBindSyncedSession = isConfirmedSession
                || isExpectedReplaySession
            if shouldBindSyncedSession {
                slot.router.handle(message)
                sessionToSlotID[resolvedSessionID] = slotID
                if resolvedSessionID != sessionId {
                    sessionToSlotID[sessionId] = nil
                }
                slots[slotID]?.confirmedSessionIDs.insert(resolvedSessionID)
                normalizeSessionToSlotMappings(for: slotID)
                sessionReplayCoordinator.markSyncCompleted(
                    for: slotID,
                    sessionID: sessionId,
                    resolvedSessionID: resolvedSessionId
                )
                diagnosticsStore.recordInfo(
                    "[\(slotID)] session_sync_complete mapped original=\(sessionId) resolved=\(resolvedSessionID)"
                )
            } else {
                diagnosticsStore.recordInfo("[\(slotID)] ignored_unmapped_sync_session=\(resolvedSessionID)")
            }

        case let .error(errorMessage):
            slot.router.handle(message)
            handleReplayProtocolErrorIfNeeded(slotID: slotID, message: errorMessage)

        case .fileContent, .fileError, .fileSearchResults, .diffContent, .diffHunksContent, .diffError, .pong, .slashCatalog, .slashActionResult:
            slot.router.handle(message)
            break
        }

        refreshPublishedState()
    }

    private func disconnectAllRuntimeConnections() {
        let activeSlots = Array(slots.values)
        for slot in activeSlots {
            slot.controller.disconnect()
            pendingSessionCoordinator.clearPendingCommand(for: slot.savedConnectionID)
            sessionReplayCoordinator.reset(for: slot.savedConnectionID)
            clearSessionNavigationTarget(for: slot.savedConnectionID)
        }
        slots.removeAll()
        stopPingTimer()
    }

    // MARK: - Ping Keep-alive

    private func ensurePingTimer() {
        guard pingTimer == nil else { return }
        startPingTimer()
    }

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendPingToAllSlots()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPingToAllSlots() {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let activeSlotID, let slot = slots[activeSlotID], case .connected = slot.controller.state else {
            refreshPublishedState()
            return
        }
        do {
            try slot.controller.send(.ping(ts: ts))
        } catch {
            diagnosticsStore.recordError("[\(activeSlotID)] ping failed: \(error.localizedDescription)")
        }
        refreshPublishedState()
    }

    // MARK: - Persistence

    private func persistSavedConnections() {
        guard persistsSavedConnections else { return }

        do {
            try savedConnectionStore.saveSnapshot(
                .init(
                    connections: connectionsViewModel.savedConnections,
                    selectedConnectionID: connectionsViewModel.selectedSavedConnectionID
                )
            )
        } catch {
            diagnosticsStore.recordError("save connections failed: \(error.localizedDescription)")
        }
    }

    private func persistConversationState() {
        guard persistsConversationState else { return }

        let snapshot = ConversationSnapshot(
            sessionStore: sessionStore.snapshot(),
            timelineStore: timelineStore.snapshot(),
            fileStore: fileStore.snapshot(),
            sessionToConnectionID: sessionToSlotID
        )
        let store = conversationSnapshotStore
        let diagnostics = diagnosticsStore

        pendingConversationPersistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            do {
                try store.saveSnapshot(snapshot)
            } catch {
                Task { @MainActor in
                    diagnostics.recordError("save conversation snapshot failed: \(error.localizedDescription)")
                }
            }
        }
        pendingConversationPersistenceWorkItem = workItem
        conversationPersistenceQueue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func knownSessionIDs(for connectionID: String) -> [String] {
        Array(sessionToSlotID.compactMap { sessionID, slotID in
            slotID == connectionID ? sessionID : nil
        })
    }

    private func normalizeSessionToSlotMappings(for connectionID: String) {
        let currentMappings = sessionToSlotID
        for (sessionID, slotID) in currentMappings where slotID == connectionID {
            guard let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) else {
                continue
            }
            guard resolvedSessionID != sessionID else {
                continue
            }
            sessionToSlotID[resolvedSessionID] = connectionID
            sessionToSlotID[sessionID] = nil
        }
    }

    private func requestReplayBootstrap(for slotID: String, sessionIDs: [String]) {
        guard slots[slotID]?.supportsSessionReplay == true else {
            slots[slotID]?.shouldBootstrapReplay = false
            return
        }

        diagnosticsStore.recordInfo("[\(slotID)] request_replay_bootstrap sessions=\(Self.describeSessionIDs(sessionIDs))")
        let requests = sessionReplayCoordinator.enqueueReconnectSyncs(
            for: slotID,
            sessionIDs: sessionIDs
        ) { [sessionStore] sessionID in
            sessionStore.lastAppliedEventID(for: sessionID)
        }
        sendReplayRequests(requests, through: slotID)
    }

    private func handleReplayNeeded(slotID: String, sessionID: String, afterEventId: Int) {
        guard slots[slotID]?.supportsSessionReplay == true else {
            return
        }

        guard let request = sessionReplayCoordinator.enqueueGapSync(
            for: slotID,
            sessionID: sessionID,
            afterEventId: afterEventId
        ) else {
            return
        }
        sendReplayRequests([request], through: slotID)
    }

    private func handleReplayProtocolErrorIfNeeded(slotID: String, message: String) {
        guard message == "Invalid message format" else {
            return
        }
        guard sessionReplayCoordinator.hasInFlightSyncs(for: slotID) else {
            return
        }

        slots[slotID]?.supportsSessionReplay = false
        slots[slotID]?.shouldBootstrapReplay = false
        sessionReplayCoordinator.reset(for: slotID)
        diagnosticsStore.recordError("[\(slotID)] session replay disabled after bridge rejected sync_session")
    }

    private func sendReplayRequests(_ requests: [SessionReplayRequest], through slotID: String) {
        guard let slot = slots[slotID], case .connected = slot.controller.state else {
            return
        }

        for request in requests {
            do {
                try slot.controller.send(
                    .syncSession(sessionId: request.sessionID, afterEventId: request.afterEventId)
                )
                diagnosticsStore.recordInfo(
                    "[\(slotID)] sync_session:\(request.sessionID):after=\(request.afterEventId)"
                )
            } catch {
                sessionReplayCoordinator.markSyncCompleted(
                    for: slotID,
                    sessionID: request.sessionID,
                    resolvedSessionID: nil
                )
                diagnosticsStore.recordError(
                    "[\(slotID)] sync_session failed for \(request.sessionID): \(error.localizedDescription)"
                )
            }
        }
    }

    private func applyPendingSessionResolution(_ resolution: PendingSessionResolution) {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: resolution.sessionID) ?? resolution.sessionID
        sessionToSlotID[resolvedSessionID] = resolution.connectionID
        diagnosticsStore.recordInfo(
            "[\(resolution.connectionID)] pending_resolution session=\(resolution.sessionID) resolved=\(resolvedSessionID) command=\(resolution.command.prefix(40))"
        )

        let hasMatchingStarter = timelineStore.timeline(for: resolvedSessionID).contains { item in
            if case let .userCommand(text) = item.kind {
                return text == resolution.command
            }
            return false
        }
        if !hasMatchingStarter {
            timelineStore.appendUserCommand(
                resolution.command,
                sessionId: resolvedSessionID,
                timestamp: resolution.timestamp
            )
        }

        if let state = sessionStore.session(for: resolvedSessionID)?.state {
            if state == .idle {
                sessionStore.updateState(for: resolvedSessionID, state: .thinking)
            }
        } else {
            sessionStore.updateState(for: resolvedSessionID, state: .thinking)
        }

        sessionStore.setActiveSession(id: resolvedSessionID)
        diagnosticsStore.recordInfo("[\(resolution.connectionID)] active_session=\(resolvedSessionID)")
        setSessionNavigationTarget(sessionID: resolvedSessionID, for: resolution.connectionID)
    }

    private func setSessionNavigationTarget(sessionID: String, for connectionID: String) {
        var targets = sessionNavigationTargets
        targets[connectionID] = sessionID
        sessionNavigationTargets = targets
    }

    private func clearSessionNavigationTarget(for connectionID: String) {
        guard sessionNavigationTargets[connectionID] != nil else {
            return
        }
        var targets = sessionNavigationTargets
        targets[connectionID] = nil
        sessionNavigationTargets = targets
    }

    private func synchronizeSessionRemoval(
        for connectionID: String,
        previousSessionIDs: [String],
        incomingSessions: [SessionInfo]
    ) {
        let incomingSessionIDs = Set(incomingSessions.map(\.id))
        let removedSessionIDs = Set(previousSessionIDs.compactMap { previousSessionID -> String? in
            let resolvedSessionID = sessionStore.resolvedSessionId(for: previousSessionID) ?? previousSessionID
            return incomingSessionIDs.contains(resolvedSessionID) ? nil : resolvedSessionID
        })

        for sessionID in removedSessionIDs {
            removeSessionLocally(sessionID, connectionID: connectionID)
        }
    }

    private func clearLocallyRestoredSessions(for connectionID: String) {
        let restoredSessionIDs = knownSessionIDs(for: connectionID)
        guard !restoredSessionIDs.isEmpty else {
            return
        }

        diagnosticsStore.recordInfo(
            "[\(connectionID)] clear_local_restore sessions=\(Self.describeSessionIDs(restoredSessionIDs))"
        )
        for sessionID in restoredSessionIDs {
            removeSessionLocally(sessionID, connectionID: connectionID)
        }
    }

    private func removeSessionLocally(_ sessionID: String, connectionID: String? = nil) {
        let resolvedSessionID = sessionStore.resolvedSessionId(for: sessionID) ?? sessionID
        let targetConnectionID = connectionID ?? sessionToSlotID[resolvedSessionID] ?? sessionToSlotID[sessionID]
        let shouldClearNavigationTarget = targetConnectionID.map { connectionID in
            let currentTarget = sessionNavigationTargets[connectionID]
            let resolvedTarget = sessionStore.resolvedSessionId(for: currentTarget) ?? currentTarget
            return resolvedTarget == resolvedSessionID
        } ?? false

        var sessionIDsToClear: [String] = []
        for (knownSessionID, mappedConnectionID) in sessionToSlotID {
            if let targetConnectionID, mappedConnectionID != targetConnectionID {
                continue
            }

            let resolvedKnownSessionID = sessionStore.resolvedSessionId(for: knownSessionID) ?? knownSessionID
            if resolvedKnownSessionID == resolvedSessionID {
                sessionIDsToClear.append(knownSessionID)
            }
        }

        for knownSessionID in sessionIDsToClear {
            sessionToSlotID[knownSessionID] = nil
        }

        diagnosticsStore.recordInfo(
            "remove_session_local session=\(sessionID) resolved=\(resolvedSessionID) connection=\(targetConnectionID ?? "nil")"
        )
        sessionStore.removeSession(id: resolvedSessionID)
        timelineStore.removeSessionTimeline(sessionId: resolvedSessionID)
        fileStore.removeSessionState(sessionId: resolvedSessionID)
        fileSearchStore.removeSessionState(sessionId: resolvedSessionID)

        if shouldClearNavigationTarget, let targetConnectionID {
            clearSessionNavigationTarget(for: targetConnectionID)
        }
    }

    private func socketURLString(for config: ConnectionConfig) -> String {
        switch config {
        case let .lan(host, port, _, _, _):
            // Tunnel URL: host is a plain hostname, use wss://
            if host.hasSuffix(".trycloudflare.com") || host.hasSuffix(".cloudflare.com") {
                return "wss://\(host)"
            }
            // Already a full URL (e.g. wss://... or ws://...)
            if host.hasPrefix("wss://") || host.hasPrefix("ws://") {
                return host
            }
            // IPv6 addresses must be wrapped in brackets for URLs
            if host.contains(":") {
                return "ws://[\(host)]:\(port)"
            }
            return "ws://\(host):\(port)"
        case let .relay(url, channel, _, _):
            let relayBase = url.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
                of: "/+$",
                with: "",
                options: .regularExpression
            )
            let encodedChannel = channel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channel
            return "\(relayBase)/ws?device=phone&channel=\(encodedChannel)"
        }
    }

    private static func defaultSavedConnections() -> [SavedConnection] {
        [
            .init(
                id: "local-lan",
                name: "Local LAN",
                config: .lan(
                    host: "127.0.0.1",
                    port: 19260,
                    token: "",
                    bridgePublicKey: "bridge-pubkey",
                    otp: "123456"
                )
            ),
            .init(
                id: "team-relay",
                name: "Team Relay",
                config: .relay(
                    url: "wss://relay.example.com",
                    channel: "team-alpha",
                    bridgePublicKey: "bridge-pubkey",
                    otp: "654321"
                )
            ),
        ]
    }

    private static func describeConnectionConfig(_ config: ConnectionConfig) -> String {
        switch config {
        case let .lan(host, port, token, bridgePublicKey, _):
            let tokenState = token.isEmpty ? "none" : "present"
            return "lan host=\(host) port=\(port) token=\(tokenState) bridge=\(describeKey(bridgePublicKey))"
        case let .relay(url, channel, bridgePublicKey, _):
            return "relay url=\(url) channel=\(channel) bridge=\(describeKey(bridgePublicKey))"
        }
    }

    private static func describeSessions(_ sessions: [SessionInfo]) -> String {
        if sessions.isEmpty {
            return "[]"
        }

        let parts = sessions.map { session in
            "\(session.id){state=\(session.state.rawValue),updated=\(session.lastActiveAt)}"
        }
        return "[\(parts.joined(separator: ","))]"
    }

    private static func describeSessionIDs(_ sessionIDs: [String]) -> String {
        if sessionIDs.isEmpty {
            return "[]"
        }
        return "[\(sessionIDs.sorted().joined(separator: ","))]"
    }

    private static func describeSessionMapping(_ mapping: [String: String]) -> String {
        if mapping.isEmpty {
            return "[]"
        }

        let parts = mapping
            .sorted { $0.key < $1.key }
            .map { "\($0.key)->\($0.value)" }
        return "[\(parts.joined(separator: ","))]"
    }

    private static func describeKey(_ value: String) -> String {
        "\(value.prefix(12))...\(value.suffix(6))"
    }
}

// MARK: - Errors

enum AppModelError: Error, LocalizedError {
    case noActiveConnection
    case connectionNotFound
    case sessionConnectionUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveConnection: return "No active connection available."
        case .connectionNotFound: return "Saved connection not found."
        case .sessionConnectionUnavailable: return "Connect to the project before deleting its sessions."
        }
    }
}

// MARK: - Stub Sender

private final class InMemoryPhoneMessageSender: PhoneMessageSending {
    var onSend: ((PhoneMessage) -> Void)?

    func send(_ message: PhoneMessage) throws {
        onSend?(message)
    }
}

// MARK: - Preview

#if DEBUG
extension AppModel {
    static func uiTestFixtureIfRequested(arguments: [String]) -> AppModel? {
        guard arguments.contains(UITestLaunchArgument.streaming.rawValue) else {
            return nil
        }
        return uiTestStreamingFixture()
    }

    static func uiTestStreamingFixture() -> AppModel {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let fileSearchStore = FileSearchStore()
        let diffStore = DiffStore()
        let diagnosticsStore = DiagnosticsStore()
        let slashCatalogStore = SlashCatalogStore()
        let diagnosticsViewModel = DiagnosticsViewModel(diagnosticsStore: diagnosticsStore)
        let suiteName = "AppModelUITest.\(UUID().uuidString)"
        let previewDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        let previewSecretStore = KeychainSecretStore(service: "com.ctunnel.uitest.\(UUID().uuidString)")
        let savedConnectionStore = SavedConnectionStore(
            userDefaults: previewDefaults,
            secretStore: previewSecretStore
        )
        let conversationSnapshotStore = ConversationSnapshotStore(userDefaults: previewDefaults)
        let connectionsViewModel = ConnectionsViewModel(savedConnections: AppUITestFixtures.savedConnections.connections)
        _ = connectionsViewModel.selectSavedConnection(id: AppUITestFixtures.savedConnections.selectedConnectionID)
        let session = AppUITestFixtures.makeSession()
        let stubSender = InMemoryPhoneMessageSender()

        _ = sessionStore.applySessionList([session])
        sessionStore.setActiveSession(id: session.id)
        diagnosticsStore.recordInfo("[ui-test] streaming fixture booted")

        let model = AppModel(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            fileSearchStore: fileSearchStore,
            diffStore: diffStore,
            diagnosticsStore: diagnosticsStore,
            slashCatalogStore: slashCatalogStore,
            diagnosticsViewModel: diagnosticsViewModel,
            savedConnectionStore: savedConnectionStore,
            conversationSnapshotStore: conversationSnapshotStore,
            stubSender: stubSender,
            connectionsViewModel: connectionsViewModel,
            pendingSessionCoordinator: PendingSessionCoordinator(),
            sessionReplayCoordinator: SessionReplayCoordinator(),
            currentConnectionSummary: AppUITestFixtures.currentConnectionSummary,
            latestErrorMessage: nil,
            persistsSavedConnections: false,
            persistsConversationState: false
        )
        model.seedPreviewMappings(
            sessionToSlot: [session.id: AppUITestFixtures.connectionID],
            slotStates: [AppUITestFixtures.connectionID: "Connected (encrypted)"]
        )

        let harness = UITestStreamingHarness(model: model, sessionID: session.id)
        harness.install(on: stubSender)
        model.uiTestHarness = harness
        return model
    }

    func uiTestApply(
        event: AgentEvent? = nil,
        sessionState: AgentState? = nil,
        sessionID: String,
        timestamp: Int? = nil,
        eventId: Int? = nil
    ) {
        if let event, let timestamp {
            timelineStore.appendBridgeEvent(
                sessionId: sessionID,
                event: event,
                timestamp: timestamp,
                eventId: eventId
            )
        }
        if let sessionState {
            sessionStore.updateState(for: sessionID, state: sessionState)
        }
        refreshPublishedState()
    }

    static func previewFixture() -> AppModel {
        let sessionStore = SessionStore()
        let timelineStore = TimelineStore()
        let fileStore = FileStore()
        let fileSearchStore = FileSearchStore()
        let diffStore = DiffStore()
        let diagnosticsStore = DiagnosticsStore()
        let slashCatalogStore = SlashCatalogStore()
        let diagnosticsViewModel = DiagnosticsViewModel(diagnosticsStore: diagnosticsStore)
        let previewDefaults = UserDefaults(suiteName: "AppModelPreview.\(UUID().uuidString)") ?? .standard
        let previewSecretStore = KeychainSecretStore(service: "com.ctunnel.preview.\(UUID().uuidString)")
        let savedConnectionStore = SavedConnectionStore(
            userDefaults: previewDefaults,
            secretStore: previewSecretStore
        )
        let conversationSnapshotStore = ConversationSnapshotStore(userDefaults: previewDefaults)
        let connectionsViewModel = ConnectionsViewModel(savedConnections: AppPreviewFixtures.savedConnections.connections)
        _ = connectionsViewModel.selectSavedConnection(id: AppPreviewFixtures.savedConnections.selectedConnectionID)

        _ = sessionStore.applySessionList(AppPreviewFixtures.sessions)
        sessionStore.setActiveSession(id: AppPreviewFixtures.primarySessionID)
        AppPreviewFixtures.seedTimeline(into: timelineStore)
        AppPreviewFixtures.seedFiles(into: fileStore, sessionID: AppPreviewFixtures.primarySessionID)
        AppPreviewFixtures.seedDiagnostics(into: diagnosticsStore)

        let model = AppModel(
            sessionStore: sessionStore,
            timelineStore: timelineStore,
            fileStore: fileStore,
            fileSearchStore: fileSearchStore,
            diffStore: diffStore,
            diagnosticsStore: diagnosticsStore,
            slashCatalogStore: slashCatalogStore,
            diagnosticsViewModel: diagnosticsViewModel,
            savedConnectionStore: savedConnectionStore,
            conversationSnapshotStore: conversationSnapshotStore,
            stubSender: InMemoryPhoneMessageSender(),
            connectionsViewModel: connectionsViewModel,
            pendingSessionCoordinator: PendingSessionCoordinator(),
            sessionReplayCoordinator: SessionReplayCoordinator(),
            currentConnectionSummary: AppPreviewFixtures.currentConnectionSummary,
            latestErrorMessage: nil,
            persistsSavedConnections: false,
            persistsConversationState: false
        )
        // Seed session→connection mapping and slot states for preview
        model.seedPreviewMappings(
            sessionToSlot: [
                AppPreviewFixtures.primarySessionID: "preview-lan",
                "session-preview-secondary": "preview-relay",
            ],
            slotStates: [
                "preview-lan": "Connected (encrypted)",
                "preview-relay": "Connected (encrypted)",
            ]
        )
        return model
    }

    /// Seeds session→connection mapping and slot states for previews.
    func seedPreviewMappings(sessionToSlot: [String: String], slotStates: [String: String]) {
        for (sessionID, slotID) in sessionToSlot {
            sessionToSlotID[sessionID] = slotID
        }
        self.slotStates = slotStates
        currentConnectionSummary = slotStates.values.first(where: {
            $0.lowercased().contains("connected") && !$0.lowercased().contains("disconnected")
        }) ?? "Disconnected"
    }
}

private enum UITestLaunchArgument: String {
    case streaming = "--uitest-streaming"
}

private enum AppUITestFixtures {
    static let connectionID = "ui-test-streaming"
    static let sessionID = "ui-test-session"
    static let currentConnectionSummary = "Connected (encrypted)"

    static let savedConnections = SavedConnectionsSnapshot(
        connections: [
            .init(
                id: connectionID,
                name: "UI Test Streaming",
                config: .lan(
                    host: "ui-test.local",
                    port: 19260,
                    token: "",
                    bridgePublicKey: "ui-test-bridge-public-key",
                    otp: "112233"
                )
            )
        ],
        selectedConnectionID: connectionID
    )

    static func makeSession(nowMillis: Int = Int(Date().timeIntervalSince1970 * 1_000)) -> SessionInfo {
        .init(
            id: sessionID,
            agentType: .codex,
            workDir: "/tmp/ctunnel/ui-test-streaming",
            state: .idle,
            createdAt: nowMillis - 60_000,
            lastActiveAt: nowMillis - 60_000
        )
    }
}

@MainActor
private final class UITestStreamingHarness {
    private weak var model: AppModel?
    private let sessionID: String
    private var pendingWorkItems: [DispatchWorkItem] = []
    private var nextEventID = 1

    init(model: AppModel, sessionID: String) {
        self.model = model
        self.sessionID = sessionID
    }

    func install(on sender: InMemoryPhoneMessageSender) {
        sender.onSend = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handle(message)
            }
        }
    }

    private func handle(_ message: PhoneMessage) {
        switch message {
        case let .command(_, incomingSessionID, _):
            guard incomingSessionID == sessionID else {
                return
            }
            streamReply()
        case let .cancel(incomingSessionID):
            guard incomingSessionID == sessionID else {
                return
            }
            cancelStream(markTurnCompleted: true)
        default:
            break
        }
    }

    private func streamReply() {
        cancelStream(markTurnCompleted: false)
        guard let model else {
            return
        }

        let start = nowMillis()
        model.uiTestApply(
            event: .thinking(text: "Drafting a streamed CTunnel reply"),
            sessionState: .thinking,
            sessionID: sessionID,
            timestamp: start,
            eventId: takeEventID()
        )

        schedule(after: 0.10) { [weak self] in
            guard let self, let model = self.model else { return }
            model.uiTestApply(
                event: .agentMessage(text: "H"),
                sessionState: .coding,
                sessionID: self.sessionID,
                timestamp: start + 100,
                eventId: self.takeEventID()
            )
        }

        schedule(after: 1.00) { [weak self] in
            guard let self, let model = self.model else { return }
            model.uiTestApply(
                event: .agentMessage(text: "Hello"),
                sessionState: .coding,
                sessionID: self.sessionID,
                timestamp: start + 1_000,
                eventId: self.takeEventID()
            )
        }

        schedule(after: 3.00) { [weak self] in
            guard let self, let model = self.model else { return }
            model.uiTestApply(
                event: .agentMessage(text: ", CTunnel."),
                sessionState: .coding,
                sessionID: self.sessionID,
                timestamp: start + 3_000,
                eventId: self.takeEventID()
            )
        }

        schedule(after: 3.25) { [weak self] in
            guard let self, let model = self.model else { return }
            model.uiTestApply(
                event: .turnCompleted(summary: "Turn completed", filesChanged: [], usage: nil),
                sessionState: .idle,
                sessionID: self.sessionID,
                timestamp: start + 3_250,
                eventId: self.takeEventID()
            )
            self.pendingWorkItems.removeAll()
        }
    }

    private func cancelStream(markTurnCompleted: Bool) {
        pendingWorkItems.forEach { $0.cancel() }
        pendingWorkItems.removeAll()

        guard markTurnCompleted, let model else {
            return
        }

        model.uiTestApply(
            event: .turnCompleted(summary: "Cancelled", filesChanged: [], usage: nil),
            sessionState: .idle,
            sessionID: sessionID,
            timestamp: nowMillis(),
            eventId: takeEventID()
        )
    }

    private func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                action()
            }
        }
        pendingWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func takeEventID() -> Int {
        defer { nextEventID += 1 }
        return nextEventID
    }

    private func nowMillis() -> Int {
        Int(Date().timeIntervalSince1970 * 1_000)
    }
}

enum AppPreviewFixtures {
    static let primarySessionID = "session-preview-primary"

    static let savedConnections = SavedConnectionsSnapshot(
        connections: [
            .init(
                id: "preview-lan",
                name: "Preview LAN",
                config: .lan(
                    host: "192.168.1.24",
                    port: 19260,
                    token: "preview-token",
                    bridgePublicKey: "preview-bridge-pubkey",
                    otp: "246810"
                )
            ),
            .init(
                id: "preview-relay",
                name: "Preview Relay",
                config: .relay(
                    url: "wss://relay.example.com",
                    channel: "design-review",
                    bridgePublicKey: "preview-relay-pubkey",
                    otp: "135790"
                )
            ),
        ],
        selectedConnectionID: "preview-relay"
    )

    static let sessions: [SessionInfo] = [
        .init(
            id: primarySessionID,
            agentType: .codex,
            workDir: "/preview/ctunnel",
            state: .coding,
            createdAt: 1_742_281_200_000,
            lastActiveAt: 1_742_281_560_000
        ),
        .init(
            id: "session-preview-secondary",
            agentType: .claude,
            workDir: "/preview/ctunnel/packages/ios",
            state: .thinking,
            createdAt: 1_742_280_900_000,
            lastActiveAt: 1_742_281_000_000
        ),
    ]

    static let previewFile = FileState(
        path: "/preview/ctunnel/README.md",
        content: "# CTunnel iOS Preview\n\nThis file is shown inside the SwiftUI Canvas preview.",
        language: "markdown",
        isLoading: false
    )

    static let currentConnectionSummary = "Connected: wss://relay.example.com/ws?device=phone&channel=design-review"

    static func seedTimeline(into timelineStore: TimelineStore) {
        timelineStore.appendSystem(
            "relay authenticated token=preview-token otp=135790",
            sessionId: nil,
            timestamp: 1_742_281_100_000
        )
        timelineStore.appendTransportError(
            "reconnect triggered ciphertext=PREVIEW-CIPHERTEXT",
            timestamp: 1_742_281_110_000
        )
        timelineStore.appendUserCommand(
            "Add SwiftUI previews for the main iOS screens",
            sessionId: primarySessionID,
            timestamp: 1_742_281_200_000
        )
        timelineStore.appendBridgeEvent(
            sessionId: primarySessionID,
            event: .status(state: .runningCommand, message: "Generating preview fixtures"),
            timestamp: 1_742_281_220_000
        )
        timelineStore.appendBridgeEvent(
            sessionId: primarySessionID,
            event: .thinking(text: "Reusing the existing AppModel environment keeps previews honest."),
            timestamp: 1_742_281_240_000
        )
        timelineStore.appendBridgeEvent(
            sessionId: primarySessionID,
            event: .codeChange(
                changes: [
                    .init(path: "packages/ios/CodePilotApp/CodePilot/App/RootView.swift", kind: .update),
                    .init(path: "packages/ios/CodePilotApp/CodePilot/Connections/ConnectionsView.swift", kind: .update),
                ]
            ),
            timestamp: 1_742_281_280_000
        )
        timelineStore.appendBridgeEvent(
            sessionId: primarySessionID,
            event: .commandExec(
                command: "xcodebuild -scheme CTunnel build",
                output: "BUILD SUCCEEDED",
                exitCode: 0,
                status: .done
            ),
            timestamp: 1_742_281_340_000
        )
        timelineStore.appendBridgeEvent(
            sessionId: primarySessionID,
            event: .turnCompleted(
                summary: "Added preview fixtures and page-level previews.",
                filesChanged: [
                    "packages/ios/CodePilotApp/CodePilot/App/RootView.swift",
                    "packages/ios/CodePilotApp/CodePilot/Sessions/SessionDetailView.swift",
                ],
                usage: .init(inputTokens: 482, outputTokens: 176, cachedInputTokens: 64)
            ),
            timestamp: 1_742_281_420_000
        )
    }

    static func seedFiles(into fileStore: FileStore, sessionID: String) {
        fileStore.markRequested(path: previewFile.path, sessionId: sessionID)
        fileStore.routeFileContent(
            path: previewFile.path,
            content: previewFile.content,
            language: previewFile.language,
            fallbackSessionId: sessionID
        )
    }

    static func seedDiagnostics(into diagnosticsStore: DiagnosticsStore) {
        diagnosticsStore.recordStateTransition(
            from: .connected(encrypted: true, clientId: "preview-client"),
            to: .reconnecting
        )
        diagnosticsStore.recordInfo("token=preview-token otp=135790 ciphertext=PREVIEW-CIPHERTEXT")
        diagnosticsStore.recordInfo("pong:42ms")
    }
}

#Preview("Root View") {
    RootView(appModel: AppModel.previewFixture())
}
#endif
