import CryptoKit
import Foundation
import CodePilotProtocol

public enum E2ECryptoSessionError: Error, Equatable {
    case invalidPublicKeyBase64
    case invalidPublicKeyLength(Int)
    case invalidSessionKeyLength(Int)
}

public struct E2ECryptoSession: Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(privateKeyRawRepresentation: Data) throws {
        self.privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRawRepresentation)
    }

    public var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    public func deriveSessionKey(theirPublicKeyBase64: String, otp: String) throws -> Data {
        guard let theirPublicKeyRaw = Data(base64Encoded: theirPublicKeyBase64) else {
            throw E2ECryptoSessionError.invalidPublicKeyBase64
        }
        guard theirPublicKeyRaw.count == 32 else {
            throw E2ECryptoSessionError.invalidPublicKeyLength(theirPublicKeyRaw.count)
        }

        let theirPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublicKeyRaw)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(otp.utf8),
            sharedInfo: Data("codepilot-e2e-v1".utf8),
            outputByteCount: 32
        )

        return key.dataRepresentation
    }

    public static func encrypt(plaintext: Data, sessionKey: Data) throws -> EncryptedWireMessage {
        let nonce = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
        return try encrypt(plaintext: plaintext, sessionKey: sessionKey, nonce: nonce)
    }

    static func encrypt(plaintext: Data, sessionKey: Data, nonce: Data) throws -> EncryptedWireMessage {
        let key = try symmetricKey(from: sessionKey)
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce)

        return try EncryptedWireCodec.encode(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
    }

    public static func decrypt(message: EncryptedWireMessage, sessionKey: Data) throws -> Data {
        let key = try symmetricKey(from: sessionKey)
        let wire = try EncryptedWireCodec.decode(message)
        let nonce = try AES.GCM.Nonce(data: wire.nonce)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: wire.ciphertext, tag: wire.tag)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private static func symmetricKey(from sessionKey: Data) throws -> SymmetricKey {
        guard sessionKey.count == 32 else {
            throw E2ECryptoSessionError.invalidSessionKeyLength(sessionKey.count)
        }
        return SymmetricKey(data: sessionKey)
    }
}

private extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}
