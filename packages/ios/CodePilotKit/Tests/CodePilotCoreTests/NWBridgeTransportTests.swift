import Foundation
import Network
import XCTest
@testable import CodePilotCore

final class NWBridgeTransportTests: XCTestCase {
    func testOpenDropsBufferedBytesFromPreviousConnectionGeneration() throws {
        let firstConnection = MockNWConnection()
        let secondConnection = MockNWConnection()
        var pendingConnections: [MockNWConnection] = [firstConnection, secondConnection]

        let transport = NWBridgeTransport(
            url: URL(string: "ws://example.com/socket")!,
            connectionFactory: { _, _, _ in
                XCTAssertFalse(pendingConnections.isEmpty, "expected a mock connection")
                return pendingConnections.removeFirst()
            }
        )

        var receivedFrames: [BridgeTransportFrame] = []
        transport.onReceive = { receivedFrames.append($0) }

        try transport.open()
        completeUpgrade(for: firstConnection)

        let staleFrame = makeServerTextFrame(#"{"type":"pong","latencyMs":1}"#)
        firstConnection.triggerReceive(data: Data(staleFrame.prefix(12)))

        try transport.open()
        XCTAssertEqual(firstConnection.cancelCallCount, 1)
        completeUpgrade(for: secondConnection)

        let freshFrame = makeServerTextFrame(#"{"type":"pong","latencyMs":42}"#)
        secondConnection.triggerReceive(data: freshFrame)

        XCTAssertEqual(receivedFrames.count, 1, "stale bytes from the first socket should not block the new frame")
        guard receivedFrames.count == 1 else {
            return
        }

        guard case let .bridge(message) = receivedFrames[0] else {
            return XCTFail("expected a bridge frame")
        }
        XCTAssertEqual(message, .pong(latencyMs: 42))
    }
}

private extension NWBridgeTransportTests {
    func completeUpgrade(for connection: MockNWConnection) {
        connection.triggerState(.ready)
        XCTAssertEqual(connection.sentPayloads.count, 1, "upgrade request should be sent once the socket is ready")
        connection.triggerReceive(
            data: Data(
                """
                HTTP/1.1 101 Switching Protocols\r
                Upgrade: websocket\r
                Connection: Upgrade\r
                \r
                """.utf8
            )
        )
    }

    func makeServerTextFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var frame = Data()
        frame.append(0x81)

        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65_535 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for index in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (index * 8)) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }
}

private final class MockNWConnection: NWConnectionProtocol {
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?

    private(set) var cancelCallCount = 0
    private(set) var sentPayloads: [Data] = []
    private var receiveHandlers: [@Sendable (Data?, Bool, NWError?) -> Void] = []

    func start(queue: DispatchQueue) {}

    func cancel() {
        cancelCallCount += 1
    }

    func send(content: Data?, completion: @escaping @Sendable (NWError?) -> Void) {
        if let content {
            sentPayloads.append(content)
        }
        completion(nil)
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping @Sendable (Data?, Bool, NWError?) -> Void
    ) {
        receiveHandlers.append(completion)
    }

    func triggerState(_ state: NWConnection.State) {
        stateUpdateHandler?(state)
    }

    func triggerReceive(data: Data?, isComplete: Bool = false, error: NWError? = nil) {
        guard !receiveHandlers.isEmpty else {
            XCTFail("No receive handler registered")
            return
        }
        let handler = receiveHandlers.removeFirst()
        handler(data, isComplete, error)
    }
}
