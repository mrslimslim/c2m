import CodePilotCore
import CodePilotProtocol

public protocol PhoneMessageSending: AnyObject {
    func send(_ message: PhoneMessage) throws
}

extension BridgeConnectionController: PhoneMessageSending {}
