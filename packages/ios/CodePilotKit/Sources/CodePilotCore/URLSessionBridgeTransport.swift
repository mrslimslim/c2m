import Foundation
import CodePilotProtocol

public enum URLSessionBridgeTransportError: Error {
    case notConnected
    case invalidOutboundFrame
    case unsupportedInboundPayload
}

protocol URLSessionWebSocketTaskProtocol: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @Sendable @escaping (Error?) -> Void)
    func receive(completionHandler: @Sendable @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

extension URLSessionWebSocketTask: URLSessionWebSocketTaskProtocol {}

public final class URLSessionBridgeTransport: BridgeTransport {
    public var onReceive: ((BridgeTransportFrame) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let url: URL
    private let taskFactory: (URL) -> URLSessionWebSocketTaskProtocol
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let stateQueue = DispatchQueue(label: "CodePilotCore.URLSessionBridgeTransport")

    private var task: URLSessionWebSocketTaskProtocol?
    private var isClosed = true
    private var connectionGeneration: UInt64 = 0

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.taskFactory = { session.webSocketTask(with: $0) }
    }

    init(url: URL, taskFactory: @escaping (URL) -> URLSessionWebSocketTaskProtocol) {
        self.url = url
        self.taskFactory = taskFactory
    }

    public func open() throws {
        var oldTask: URLSessionWebSocketTaskProtocol?
        var newTask: URLSessionWebSocketTaskProtocol?
        var token: UInt64 = 0

        stateQueue.sync {
            isClosed = false
            connectionGeneration += 1
            token = connectionGeneration
            oldTask = task
            let createdTask = taskFactory(url)
            task = createdTask
            newTask = createdTask
        }

        oldTask?.cancel(with: URLSessionWebSocketTask.CloseCode.normalClosure, reason: nil as Data?)
        guard let newTask else {
            throw URLSessionBridgeTransportError.notConnected
        }
        newTask.resume()
        receiveNext(task: newTask, generation: token)
    }

    public func close() {
        let previousTask = stateQueue.sync { () -> URLSessionWebSocketTaskProtocol? in
            isClosed = true
            connectionGeneration += 1
            let previousTask = task
            task = nil
            return previousTask
        }
        previousTask?.cancel(with: URLSessionWebSocketTask.CloseCode.normalClosure, reason: nil as Data?)
    }

    public func send(_ frame: BridgeTransportFrame) throws {
        let payload = try encode(frame: frame)
        let context = stateQueue.sync { () -> (task: URLSessionWebSocketTaskProtocol?, generation: UInt64) in
            (task, connectionGeneration)
        }
        guard let task = context.task else {
            throw URLSessionBridgeTransportError.notConnected
        }
        let callbackGeneration = context.generation

        task.send(.string(payload)) { [weak self, weak task] error in
            guard let self else { return }
            guard self.isActive(task: task, generation: callbackGeneration) else {
                return
            }

            if let error {
                self.onDisconnect?(error)
            }
        }
    }

    private func receiveNext(task: URLSessionWebSocketTaskProtocol, generation: UInt64) {
        guard isActive(task: task, generation: generation) else {
            return
        }

        task.receive { [weak self, weak task] result in
            guard let self else { return }
            guard self.isActive(task: task, generation: generation) else {
                return
            }

            switch result {
            case let .success(message):
                do {
                    let frame = try self.decode(message: message)
                    self.onReceive?(frame)
                    guard let task else {
                        return
                    }
                    self.receiveNext(task: task, generation: generation)
                } catch {
                    if self.isActive(task: task, generation: generation) {
                        self.onDisconnect?(error)
                    }
                }

            case let .failure(error):
                if self.isActive(task: task, generation: generation) {
                    self.onDisconnect?(error)
                }
            }
        }
    }

    private func isActive(task: URLSessionWebSocketTaskProtocol?, generation: UInt64) -> Bool {
        stateQueue.sync {
            guard !isClosed else { return false }
            guard let task, let activeTask = self.task else { return false }
            return self.connectionGeneration == generation && task === activeTask
        }
    }

    private func encode(frame: BridgeTransportFrame) throws -> String {
        let data: Data
        switch frame {
        case let .handshake(message):
            data = try encoder.encode(message)
        case let .handshakeOK(message):
            data = try encoder.encode(message)
        case let .transport(message):
            data = try encoder.encode(message)
        case let .phone(message):
            data = try encoder.encode(message)
        case let .bridge(message):
            data = try encoder.encode(message)
        case let .encrypted(message):
            data = try encoder.encode(message)
        }

        guard let payload = String(data: data, encoding: .utf8) else {
            throw URLSessionBridgeTransportError.invalidOutboundFrame
        }
        return payload
    }

    private func decode(message: URLSessionWebSocketTask.Message) throws -> BridgeTransportFrame {
        let data: Data
        switch message {
        case let .string(value):
            data = Data(value.utf8)
        case let .data(value):
            data = value
        @unknown default:
            throw URLSessionBridgeTransportError.unsupportedInboundPayload
        }

        if let handshakeOK = try? decoder.decode(HandshakeOkMessage.self, from: data) {
            return .handshakeOK(handshakeOK)
        }
        if let transport = try? decoder.decode(TransportFrame.self, from: data) {
            return .transport(transport)
        }
        if let encrypted = try? decoder.decode(EncryptedWireMessage.self, from: data) {
            return .encrypted(encrypted)
        }
        if let bridgeMessage = try? decoder.decode(BridgeMessage.self, from: data) {
            return .bridge(bridgeMessage)
        }
        if let phoneMessage = try? decoder.decode(PhoneMessage.self, from: data) {
            return .phone(phoneMessage)
        }
        if let handshake = try? decoder.decode(HandshakeMessage.self, from: data) {
            return .handshake(handshake)
        }

        throw URLSessionBridgeTransportError.unsupportedInboundPayload
    }
}
