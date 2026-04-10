import XCTest

final class ConnectionScopedSessionSourceTests: XCTestCase {
    func testProjectScopedSessionsOnlyShowSessionsMappedToThatConnection() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertTrue(
            source.contains("if sessionToSlotID[session.id] == connectionID {\n                return true\n            }\n            return false"),
            "Project-scoped session lists should only show sessions explicitly mapped to that bridge connection."
        )
        XCTAssertFalse(
            source.contains("activeSlotID == connectionID && sessionToSlotID[session.id] == nil"),
            "Unmapped restored sessions should not leak into the active project's session list."
        )
    }

    func testUnknownEventSessionsAreNotImmediatelyBoundToCurrentConnection() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertTrue(
            source.contains("let shouldBindEventSession = resolution != nil\n                || isConfirmedSession\n                || isExpectedReplaySession"),
            "Unknown event sessions should only bind to a connection after a pending-session resolution or an existing connection mapping."
        )
        XCTAssertTrue(
            source.contains("ignored_unmapped_session"),
            "Diagnostics should record when an unmapped event session is ignored instead of being rebound into the current project."
        )
    }

    func testUnknownSessionMessagesAreFilteredBeforeRouterProcessing() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertFalse(
            source.contains("let restoredSessionIDs = sessionStore.sessions.map(\\.id)\n\n        slot.router.handle(message)\n\n        switch message"),
            "Bridge messages should not be handed to the shared session router before connection-scoped filtering runs."
        )
        XCTAssertTrue(
            source.contains("if shouldBindEventSession {\n                slot.router.handle(message)"),
            "Only event sessions that are already mapped or resolved from a pending command should reach the shared session router."
        )
    }

    func testUnknownSessionSyncCompletionIsIgnoredInsteadOfRebindingConnection() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertTrue(
            source.contains("ignored_unmapped_sync_session"),
            "Diagnostics should record when a sync completion for an unmapped session is ignored."
        )
        XCTAssertFalse(
            source.contains("case let .sessionSyncComplete(sessionId, _, resolvedSessionId):\n            let resolvedSessionID = resolvedSessionId ?? sessionId\n            sessionToSlotID[resolvedSessionID] = slotID"),
            "Unknown sync completion messages should not unconditionally remap the session into the current connection."
        )
    }

    func testReplayBootstrapSessionsAreAllowedThroughConnectionScopedFiltering() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertTrue(
            source.contains("let isExpectedReplaySession = sessionReplayCoordinator.hasInFlightSync(for: slotID, sessionID: resolvedSessionID)\n                || sessionReplayCoordinator.hasInFlightSync(for: slotID, sessionID: sessionId)"),
            "Replay bootstrap sessions should be recognized from in-flight sync state even after locally restored mappings are cleared."
        )
        XCTAssertTrue(
            source.contains("|| isExpectedReplaySession"),
            "Replay bootstrap events and sync completions should bind once iOS has explicitly requested replay for that session."
        )
    }

    func testConnectingAProjectKeepsLocallyRestoredSessionsAvailableForHistoryRecovery() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertFalse(
            source.contains("clearLocallyRestoredSessions(for: id)"),
            "Connecting should not destructively clear restored history before the bridge has a chance to reconcile it."
        )
    }

    func testSessionListsDoNotDeleteLocallyRestoredHistoryWhenBridgeOmitsOlderSessions() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertFalse(
            source.contains("synchronizeSessionRemoval(\n                for: slotID,"),
            "Incoming session lists should not delete locally restored history just because the bridge omitted those sessions."
        )
    }

    func testConnectionScopedFilteringUsesBridgeConfirmedSessionIDsRatherThanAllRestoredMappings() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertTrue(
            source.contains("let confirmedSessionIDs = slots[slotID]?.confirmedSessionIDs ?? []"),
            "Connection-scoped filtering should track bridge-confirmed sessions separately from restored local history."
        )
        XCTAssertTrue(
            source.contains("let isConfirmedSession = confirmedSessionIDs.contains(resolvedSessionID)\n                || confirmedSessionIDs.contains(sessionId)"),
            "Only bridge-confirmed live sessions should auto-bind regular events after reconnect."
        )
    }

    func testUnknownSessionsAreFilteredBeforeRouterHandlesReplayMessages() throws {
        let source = try loadAppSource(
            at: "../CodePilotApp/CodePilot/App/RootView.swift"
        )

        XCTAssertFalse(
            source.contains("let restoredSessionIDs = sessionStore.sessions.map(\\.id)\n\n        slot.router.handle(message)\n\n        switch message"),
            "Bridge messages should not be routed before RootView decides whether the session belongs to the current connection."
        )
        XCTAssertTrue(
            source.contains("case let .sessionList(sessions):\n            slot.router.handle(message)"),
            "Session lists should still be routed normally after moving router handling inside the message switch."
        )
        XCTAssertTrue(
            source.contains("if shouldBindEventSession {\n                slot.router.handle(message)"),
            "Event replay should only start after the event session is allowed to bind to this connection."
        )
        XCTAssertTrue(
            source.contains("ignored_unmapped_sync_session"),
            "Unknown session sync completions should be ignored instead of silently rebinding stale sessions."
        )
    }

    private func loadAppSource(at relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
