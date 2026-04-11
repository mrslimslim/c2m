import Foundation
import XCTest
@testable import CodePilotProtocol

final class ProtocolModelTests: XCTestCase {
    func testHandshakeMessagesAreModeledOutsideAppLayerUnions() throws {
        let handshake = #"{"type":"handshake","phone_pubkey":"pubkey","otp":"123456"}"#
        let handshakeOK = #"{"type":"handshake_ok","encrypted":true,"clientId":"client-1","capabilities":["session_replay_v1"]}"#

        try assertRoundTrip(
            HandshakeMessage.self,
            json: handshake,
            expected: .init(phonePubkey: "pubkey", otp: "123456")
        )
        try assertRoundTrip(
            HandshakeOkMessage.self,
            json: handshakeOK,
            expected: .init(
                encrypted: true,
                clientId: "client-1",
                capabilities: [BridgeCapability.sessionReplayV1]
            )
        )

        XCTAssertThrowsError(try decode(PhoneMessage.self, from: handshake))
        XCTAssertThrowsError(try decode(BridgeMessage.self, from: handshakeOK))
    }

    func testHandshakeOkMessageDefaultsCapabilitiesToNilWhenBridgeOmitsThem() throws {
        let handshakeOK = #"{"type":"handshake_ok","encrypted":true,"clientId":"client-1"}"#

        let decoded = try decode(HandshakeOkMessage.self, from: handshakeOK)

        XCTAssertEqual(decoded, .init(encrypted: true, clientId: "client-1", capabilities: nil))
        XCTAssertNil(decoded.capabilities)
    }

    func testHandshakeMessageRejectsWrongTypeDiscriminator() {
        let malformed = #"{"type":"not_handshake","phone_pubkey":"pubkey","otp":"123456"}"#
        XCTAssertThrowsError(try decode(HandshakeMessage.self, from: malformed))
    }

    func testHandshakeOkMessageRejectsWrongTypeDiscriminator() {
        let malformed = #"{"type":"not_handshake_ok","encrypted":true,"clientId":"client-1"}"#
        XCTAssertThrowsError(try decode(HandshakeOkMessage.self, from: malformed))
    }

    func testEncryptedWireMessageRejectsUnsupportedVersion() {
        let unsupportedVersion = #"{"v":2,"nonce":"n","ciphertext":"c","tag":"t"}"#
        XCTAssertThrowsError(try decode(EncryptedWireMessage.self, from: unsupportedVersion))
    }

    func testPhoneMessageRoundTripsRequiredVariants() throws {
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"command","text":"run tests","sessionId":"session-1"}"#,
            expected: .command(text: "run tests", sessionId: "session-1", config: nil)
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"cancel","sessionId":"session-1"}"#,
            expected: .cancel(sessionId: "session-1")
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"file_req","path":"Sources/App.swift","sessionId":"session-1"}"#,
            expected: .fileRequest(path: "Sources/App.swift", sessionId: "session-1")
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"file_search_req","sessionId":"session-1","query":"turnview","limit":12}"#,
            expected: .fileSearchRequest(sessionId: "session-1", query: "turnview", limit: 12)
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"delete_session","sessionId":"session-1"}"#,
            expected: .deleteSession(sessionId: "session-1")
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"list_sessions"}"#,
            expected: .listSessions
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"ping","ts":1700000000}"#,
            expected: .ping(ts: 1_700_000_000)
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"sync_session","sessionId":"session-1","afterEventId":42}"#,
            expected: .syncSession(sessionId: "session-1", afterEventId: 42)
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"diff_req","sessionId":"session-1","eventId":42}"#,
            expected: .diffRequest(sessionId: "session-1", eventId: 42)
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"diff_hunks_req","sessionId":"session-1","eventId":42,"path":"Sources/App.swift","afterHunkIndex":1}"#,
            expected: .diffHunksRequest(
                sessionId: "session-1",
                eventId: 42,
                path: "Sources/App.swift",
                afterHunkIndex: 1
            )
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"slash_action","sessionId":"session-1","commandId":"review","arguments":{"depth":"full","apply":false,"count":2}}"#,
            expected: .slashAction(
                .init(
                    commandId: "review",
                    sessionId: "session-1",
                    arguments: [
                        "depth": .string("full"),
                        "apply": .bool(false),
                        "count": .int(2),
                    ]
                )
            )
        )
    }

    func testCommandMessageRoundTripsConfigWithReasoningEffort() throws {
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"command","text":"run tests","sessionId":"session-1","config":{"model":"gpt-5.4","modelReasoningEffort":"xhigh"}}"#,
            expected: .command(
                text: "run tests",
                sessionId: "session-1",
                config: .init(model: "gpt-5.4", modelReasoningEffort: "xhigh")
            )
        )
    }

    func testSessionConfigTreatsReasoningEffortAsMeaningfulConfig() {
        XCTAssertFalse(SessionConfig(modelReasoningEffort: "high").isEmpty)
    }

    func testBridgeMessageRoundTripsRequiredVariants() throws {
        let session = SessionInfo(
            id: "session-1",
            agentType: .codex,
            workDir: "/tmp/repo",
            state: .thinking,
            createdAt: 1_700_000_000,
            lastActiveAt: 1_700_000_123
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"event","sessionId":"session-1","event":{"type":"status","state":"thinking","message":"working"},"eventId":5,"timestamp":1700000001}"#,
            expected: .event(
                sessionId: "session-1",
                event: .status(state: .thinking, message: "working"),
                eventId: 5,
                timestamp: 1_700_000_001
            )
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"session_list","sessions":[{"id":"session-1","agentType":"codex","workDir":"/tmp/repo","state":"thinking","createdAt":1700000000,"lastActiveAt":1700000123}]}"#,
            expected: .sessionList(sessions: [session])
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"file_content","path":"README.md","content":"hi","language":"markdown"}"#,
            expected: .fileContent(path: "README.md", content: "hi", language: "markdown")
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"file_error","sessionId":"session-1","path":"README.md","message":"No such file or directory"}"#,
            expected: .fileError(
                sessionId: "session-1",
                path: "README.md",
                message: "No such file or directory"
            )
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"file_search_results","sessionId":"session-1","query":"turnview","results":[{"path":"Sources/TurnView.swift","displayName":"TurnView.swift","directoryHint":"Sources"}]}"#,
            expected: .fileSearchResults(
                sessionId: "session-1",
                query: "turnview",
                results: [
                    .init(
                        path: "Sources/TurnView.swift",
                        displayName: "TurnView.swift",
                        directoryHint: "Sources"
                    ),
                ]
            )
        )
        let firstHunk = DiffHunk(
            oldStart: 10,
            oldLineCount: 2,
            newStart: 10,
            newLineCount: 3,
            lines: [
                .init(kind: .context, text: " let value = 1"),
                .init(kind: .delete, text: "-let oldValue = 2"),
                .init(kind: .add, text: "+let oldValue = 3"),
            ]
        )
        let file = DiffFile(
            path: "Sources/App.swift",
            kind: .update,
            addedLines: 1,
            deletedLines: 1,
            isTruncated: false,
            truncationReason: nil,
            totalHunkCount: 3,
            loadedHunks: [firstHunk],
            nextHunkIndex: 1
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"diff_content","sessionId":"session-1","eventId":42,"files":[{"path":"Sources/App.swift","kind":"update","addedLines":1,"deletedLines":1,"isTruncated":false,"totalHunkCount":3,"loadedHunks":[{"oldStart":10,"oldLineCount":2,"newStart":10,"newLineCount":3,"lines":[{"kind":"context","text":" let value = 1"},{"kind":"delete","text":"-let oldValue = 2"},{"kind":"add","text":"+let oldValue = 3"}]}],"nextHunkIndex":1}]}"#,
            expected: .diffContent(sessionId: "session-1", eventId: 42, files: [file])
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"diff_hunks_content","sessionId":"session-1","eventId":42,"path":"Sources/App.swift","hunks":[{"oldStart":18,"oldLineCount":1,"newStart":19,"newLineCount":2,"lines":[{"kind":"context","text":" func run() {"},{"kind":"add","text":"+    print(value)"}]}],"nextHunkIndex":2}"#,
            expected: .diffHunksContent(
                sessionId: "session-1",
                eventId: 42,
                path: "Sources/App.swift",
                hunks: [
                    .init(
                        oldStart: 18,
                        oldLineCount: 1,
                        newStart: 19,
                        newLineCount: 2,
                        lines: [
                            .init(kind: .context, text: " func run() {"),
                            .init(kind: .add, text: "+    print(value)"),
                        ]
                    ),
                ],
                nextHunkIndex: 2
            )
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"diff_error","sessionId":"session-1","eventId":42,"message":"No event found"}"#,
            expected: .diffError(
                sessionId: "session-1",
                eventId: 42,
                path: nil,
                message: "No event found"
            )
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"diff_error","sessionId":"session-1","eventId":42,"path":"Sources/App.swift","message":"No diff file found"}"#,
            expected: .diffError(
                sessionId: "session-1",
                eventId: 42,
                path: "Sources/App.swift",
                message: "No diff file found"
            )
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"pong","latencyMs":42}"#,
            expected: .pong(latencyMs: 42)
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"error","message":"bad request"}"#,
            expected: .error(message: "bad request")
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"session_sync_complete","sessionId":"session-1","latestEventId":24,"resolvedSessionId":"session-1a"}"#,
            expected: .sessionSyncComplete(
                sessionId: "session-1",
                latestEventId: 24,
                resolvedSessionId: "session-1a"
            )
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"slash_action_result","commandId":"review","ok":false,"message":"Command is disabled"}"#,
            expected: .slashActionResult(
                .init(commandId: "review", ok: false, message: "Command is disabled")
            )
        )
    }

    func testBridgeMessageRoundTripsSlashCatalogVariant() throws {
        let expectedMenu = SlashMenuNode(
            title: "Select Model and Effort",
            helperText: "Access legacy models by running codex -m <model_name> or in your config.toml",
            presentation: .list,
            options: [
                .init(
                    id: "gpt-5.4",
                    label: "gpt-5.4",
                    description: "Latest frontier agentic coding model.",
                    badges: [.default],
                    effects: nil,
                    next: .init(
                        title: "Select Reasoning Level for gpt-5.4",
                        helperText: nil,
                        presentation: .list,
                        options: [
                            .init(
                                id: "xhigh",
                                label: "Extra high",
                                description: "Extra high reasoning depth for complex problems",
                                badges: [.recommended],
                                effects: [
                                    .setSessionConfig(field: .model, value: "gpt-5.4"),
                                    .setSessionConfig(field: .modelReasoningEffort, value: "xhigh"),
                                ],
                                next: nil
                            ),
                        ]
                    )
                ),
            ]
        )

        let expectedCommand = SlashCommandMeta(
            id: "model",
            label: "/model",
            description: "Choose what model and reasoning effort to use",
            kind: .workflow,
            availability: .enabled,
            disabledReason: nil,
            searchTerms: ["models", "reasoning"],
            menu: expectedMenu,
            action: nil
        )

        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"slash_catalog","capability":"slash_catalog_v1","adapter":"codex","adapterVersion":"0.116.0","catalogVersion":"codex-0.116.0","defaults":{"model":"gpt-5.4","modelReasoningEffort":"medium"},"commands":[{"id":"model","label":"/model","description":"Choose what model and reasoning effort to use","kind":"workflow","availability":"enabled","searchTerms":["models","reasoning"],"menu":{"title":"Select Model and Effort","helperText":"Access legacy models by running codex -m <model_name> or in your config.toml","presentation":"list","options":[{"id":"gpt-5.4","label":"gpt-5.4","description":"Latest frontier agentic coding model.","badges":["default"],"next":{"title":"Select Reasoning Level for gpt-5.4","presentation":"list","options":[{"id":"xhigh","label":"Extra high","description":"Extra high reasoning depth for complex problems","badges":["recommended"],"effects":[{"type":"set_session_config","field":"model","value":"gpt-5.4"},{"type":"set_session_config","field":"modelReasoningEffort","value":"xhigh"}]}]}}]}}]}"#,
            expected: .slashCatalog(
                .init(
                    capability: BridgeCapability.slashCatalogV1,
                    adapter: .codex,
                    adapterVersion: "0.116.0",
                    catalogVersion: "codex-0.116.0",
                    defaults: .init(model: "gpt-5.4", modelReasoningEffort: "medium"),
                    commands: [expectedCommand]
                )
            )
        )
    }

    func testAgentEventRoundTripsRequiredVariants() throws {
        try assertRoundTrip(
            AgentEvent.self,
            json: #"{"type":"status","state":"running_command","message":"executing"}"#,
            expected: .status(state: .runningCommand, message: "executing")
        )
        try assertRoundTrip(
            AgentEvent.self,
            json: #"{"type":"thinking","text":"thinking..."}"#,
            expected: .thinking(text: "thinking...")
        )
        try assertRoundTrip(
            AgentEvent.self,
            json: #"{"type":"code_change","changes":[{"path":"Sources/App.swift","kind":"update"}]}"#,
            expected: .codeChange(changes: [.init(path: "Sources/App.swift", kind: .update)])
        )
        try assertRoundTrip(
            AgentEvent.self,
            json: #"{"type":"command_exec","command":"swift test","output":"ok","exitCode":0,"status":"done"}"#,
            expected: .commandExec(
                command: "swift test",
                output: "ok",
                exitCode: 0,
                status: .done
            )
        )
        try assertRoundTrip(
            AgentEvent.self,
            json: #"{"type":"agent_message","text":"I updated the file"}"#,
            expected: .agentMessage(text: "I updated the file")
        )
        try assertRoundTrip(
            AgentEvent.self,
            json: #"{"type":"turn_completed","summary":"all done","filesChanged":["Sources/App.swift"],"usage":{"inputTokens":10,"outputTokens":5,"cachedInputTokens":2}}"#,
            expected: .turnCompleted(
                summary: "all done",
                filesChanged: ["Sources/App.swift"],
                usage: .init(inputTokens: 10, outputTokens: 5, cachedInputTokens: 2)
            )
        )
    }

    func testTurnCompletedAllowsExplicitNullUsageAndPreservesUsageKeyWhenEncoding() throws {
        let json = #"{"type":"turn_completed","summary":"all done","filesChanged":[],"usage":null}"#
        let decoded = try decode(AgentEvent.self, from: json)
        XCTAssertEqual(decoded, .turnCompleted(summary: "all done", filesChanged: [], usage: nil))

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "turn_completed")
        XCTAssertTrue(object.keys.contains("usage"))
        XCTAssertTrue(object["usage"] is NSNull)
    }

    func testTurnCompletedAcceptsMissingUsageKey() throws {
        let missingUsage = #"{"type":"turn_completed","summary":"all done","filesChanged":[]}"#
        let decoded = try decode(AgentEvent.self, from: missingUsage)
        XCTAssertEqual(decoded, .turnCompleted(summary: "all done", filesChanged: [], usage: nil))
    }

    func testTransportFramesRoundTrip() throws {
        try assertRoundTrip(
            TransportFrame.self,
            json: #"{"type":"auth","token":"abc123"}"#,
            expected: .auth(token: "abc123")
        )
        try assertRoundTrip(
            TransportFrame.self,
            json: #"{"type":"auth_ok","clientId":"client-1"}"#,
            expected: .authOK(clientId: "client-1")
        )
        try assertRoundTrip(
            TransportFrame.self,
            json: #"{"type":"auth_failed","reason":"invalid_otp"}"#,
            expected: .authFailed(reason: "invalid_otp")
        )
        try assertRoundTrip(
            TransportFrame.self,
            json: #"{"type":"relay_peer_connected","device":"phone"}"#,
            expected: .relayPeerConnected(device: .phone)
        )
        try assertRoundTrip(
            TransportFrame.self,
            json: #"{"type":"relay_peer_disconnected","device":"bridge"}"#,
            expected: .relayPeerDisconnected(device: .bridge)
        )
    }

    func testUnknownFrameTypesAreRejectedWithoutCrashing() {
        let unknown = #"{"type":"something_new","payload":"x"}"#

        XCTAssertThrowsError(try decode(PhoneMessage.self, from: unknown))
        XCTAssertThrowsError(try decode(BridgeMessage.self, from: unknown))
        XCTAssertThrowsError(try decode(TransportFrame.self, from: unknown))
    }
}

private extension ProtocolModelTests {
    func assertRoundTrip<T: Codable & Equatable>(
        _ type: T.Type,
        json: String,
        expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let decoded = try decode(type, from: json)
        XCTAssertEqual(decoded, expected, file: file, line: line)

        let encoded = try JSONEncoder().encode(decoded)
        let decodedAgain = try JSONDecoder().decode(type, from: encoded)
        XCTAssertEqual(decodedAgain, expected, file: file, line: line)
    }

    func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
