import Foundation
import XCTest
@testable import CodePilotCore

final class URLSessionBridgeTransportTests: XCTestCase {
    func testStaleCallbacksFromPreviousTaskAreIgnoredAfterReopen() throws {
        var createdTasks: [MockWebSocketTask] = []
        let transport = URLSessionBridgeTransport(
            url: URL(string: "ws://example.com")!,
            taskFactory: { _ in
                let task = MockWebSocketTask()
                createdTasks.append(task)
                return task
            }
        )

        var receivedFrames: [BridgeTransportFrame] = []
        var disconnectCount = 0
        transport.onReceive = { receivedFrames.append($0) }
        transport.onDisconnect = { _ in disconnectCount += 1 }

        try transport.open()
        try transport.open()

        XCTAssertEqual(createdTasks.count, 2)
        XCTAssertTrue(createdTasks[0].cancelCalled)

        createdTasks[0].triggerReceive(
            .success(.string(#"{"type":"auth_ok","clientId":"stale-client"}"#))
        )
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertEqual(receivedFrames, [])

        createdTasks[1].triggerReceive(.failure(MockTransportError.synthetic))
        XCTAssertEqual(disconnectCount, 1)
    }

    func testLegacyEventFramesWithoutEventIDDoNotDisconnectTransport() throws {
        var createdTasks: [MockWebSocketTask] = []
        let transport = URLSessionBridgeTransport(
            url: URL(string: "ws://example.com")!,
            taskFactory: { _ in
                let task = MockWebSocketTask()
                createdTasks.append(task)
                return task
            }
        )

        var receivedFrames: [BridgeTransportFrame] = []
        var disconnectErrors: [Error?] = []
        transport.onReceive = { receivedFrames.append($0) }
        transport.onDisconnect = { disconnectErrors.append($0) }

        try transport.open()
        XCTAssertEqual(createdTasks.count, 1)

        createdTasks[0].triggerReceive(
            .success(
                .string(
                    #"{"type":"event","sessionId":"session-1","event":{"type":"agent_message","text":"hello from legacy bridge"},"timestamp":1700000001}"#
                )
            )
        )

        XCTAssertTrue(
            disconnectErrors.isEmpty,
            "legacy bridge event frames should not disconnect the client"
        )
        XCTAssertEqual(receivedFrames.count, 1)
        guard receivedFrames.count == 1 else {
            return
        }

        guard case let .bridge(message) = receivedFrames[0] else {
            return XCTFail("expected a bridge frame")
        }
        guard case let .event(sessionId, event, _, timestamp) = message else {
            return XCTFail("expected an event bridge message")
        }

        XCTAssertEqual(sessionId, "session-1")
        XCTAssertEqual(event, .agentMessage(text: "hello from legacy bridge"))
        XCTAssertEqual(timestamp, 1_700_000_001)
    }
}

private enum MockTransportError: Error {
    case synthetic
}

private final class MockWebSocketTask: URLSessionWebSocketTaskProtocol {
    var cancelCalled = false
    private var receiveHandlers: [(Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCalled = true
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @Sendable @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    func receive(completionHandler: @Sendable @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandlers.append(completionHandler)
    }

    func triggerReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard !receiveHandlers.isEmpty else {
            XCTFail("No receive handler registered")
            return
        }
        let handler = receiveHandlers.removeFirst()
        handler(result)
    }
}
