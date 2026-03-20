import Foundation
@testable import CodePilotCore

final class MockBridgeTransport: BridgeTransport {
    var onReceive: ((BridgeTransportFrame) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private(set) var openCallCount = 0
    private(set) var closeCallCount = 0
    private(set) var sentFrames: [BridgeTransportFrame] = []

    var openError: Error?
    var sendError: Error?

    func open() throws {
        openCallCount += 1
        if let openError {
            throw openError
        }
    }

    func close() {
        closeCallCount += 1
    }

    func send(_ frame: BridgeTransportFrame) throws {
        if let sendError {
            throw sendError
        }
        sentFrames.append(frame)
    }

    func simulateReceive(_ frame: BridgeTransportFrame) {
        onReceive?(frame)
    }

    func simulateDisconnect(error: Error? = nil) {
        onDisconnect?(error)
    }
}
