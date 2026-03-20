import Foundation
import XCTest
@testable import CodePilotProtocol

final class ProtocolModelTests: XCTestCase {
    func testHandshakeMessagesAreModeledOutsideAppLayerUnions() throws {
        let handshake = #"{"type":"handshake","phone_pubkey":"pubkey","otp":"123456"}"#
        let handshakeOK = #"{"type":"handshake_ok","encrypted":true,"clientId":"client-1"}"#

        try assertRoundTrip(
            HandshakeMessage.self,
            json: handshake,
            expected: .init(phonePubkey: "pubkey", otp: "123456")
        )
        try assertRoundTrip(
            HandshakeOkMessage.self,
            json: handshakeOK,
            expected: .init(encrypted: true, clientId: "client-1")
        )

        XCTAssertThrowsError(try decode(PhoneMessage.self, from: handshake))
        XCTAssertThrowsError(try decode(BridgeMessage.self, from: handshakeOK))
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
            json: #"{"type":"list_sessions"}"#,
            expected: .listSessions
        )
        try assertRoundTrip(
            PhoneMessage.self,
            json: #"{"type":"ping","ts":1700000000}"#,
            expected: .ping(ts: 1_700_000_000)
        )
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
            json: #"{"type":"event","sessionId":"session-1","event":{"type":"status","state":"thinking","message":"working"},"timestamp":1700000001}"#,
            expected: .event(
                sessionId: "session-1",
                event: .status(state: .thinking, message: "working"),
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
            json: #"{"type":"pong","latencyMs":42}"#,
            expected: .pong(latencyMs: 42)
        )
        try assertRoundTrip(
            BridgeMessage.self,
            json: #"{"type":"error","message":"bad request"}"#,
            expected: .error(message: "bad request")
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
