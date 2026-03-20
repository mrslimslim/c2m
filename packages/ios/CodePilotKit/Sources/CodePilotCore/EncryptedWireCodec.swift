import Foundation
import CodePilotProtocol

public enum EncryptedWireCodecError: Error, Equatable {
    case invalidBase64(field: String)
    case invalidNonceLength(Int)
    case invalidTagLength(Int)
}

public struct EncryptedWirePayload: Equatable, Sendable {
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(nonce: Data, ciphertext: Data, tag: Data) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public enum EncryptedWireCodec {
    public static func encode(nonce: Data, ciphertext: Data, tag: Data) throws -> EncryptedWireMessage {
        guard nonce.count == 12 else {
            throw EncryptedWireCodecError.invalidNonceLength(nonce.count)
        }
        guard tag.count == 16 else {
            throw EncryptedWireCodecError.invalidTagLength(tag.count)
        }

        return EncryptedWireMessage(
            nonce: nonce.base64EncodedString(),
            ciphertext: ciphertext.base64EncodedString(),
            tag: tag.base64EncodedString()
        )
    }

    public static func decode(_ message: EncryptedWireMessage) throws -> EncryptedWirePayload {
        guard let nonce = Data(base64Encoded: message.nonce) else {
            throw EncryptedWireCodecError.invalidBase64(field: "nonce")
        }
        guard let ciphertext = Data(base64Encoded: message.ciphertext) else {
            throw EncryptedWireCodecError.invalidBase64(field: "ciphertext")
        }
        guard let tag = Data(base64Encoded: message.tag) else {
            throw EncryptedWireCodecError.invalidBase64(field: "tag")
        }
        guard nonce.count == 12 else {
            throw EncryptedWireCodecError.invalidNonceLength(nonce.count)
        }
        guard tag.count == 16 else {
            throw EncryptedWireCodecError.invalidTagLength(tag.count)
        }

        return EncryptedWirePayload(nonce: nonce, ciphertext: ciphertext, tag: tag)
    }
}
