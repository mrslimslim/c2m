import Foundation
import CodePilotProtocol

public enum BridgeTransportFrame: Equatable, Sendable {
    case handshake(HandshakeMessage)
    case handshakeOK(HandshakeOkMessage)
    case transport(TransportFrame)
    case phone(PhoneMessage)
    case bridge(BridgeMessage)
    case encrypted(EncryptedWireMessage)
}

public protocol BridgeTransport: AnyObject {
    var onReceive: ((BridgeTransportFrame) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }

    func open() throws
    func close()
    func send(_ frame: BridgeTransportFrame) throws
}
