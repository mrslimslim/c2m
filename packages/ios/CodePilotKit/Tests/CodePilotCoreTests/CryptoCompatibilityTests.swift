import Foundation
import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class CryptoCompatibilityTests: XCTestCase {
    func testX25519PublicKeyExportMatchesBridgeRaw32ByteBase64() throws {
        let fixture = try loadFixture()
        let privateKeyRaw = try decodeBase64(fixture.x25519.privateKeyRawBase64, label: "x25519.privateKeyRawBase64")

        let session = try E2ECryptoSession(privateKeyRawRepresentation: privateKeyRaw)

        XCTAssertEqual(session.publicKeyBase64, fixture.x25519.expectedPublicKeyBase64)
        XCTAssertEqual(try decodeBase64(session.publicKeyBase64, label: "session.publicKeyBase64").count, 32)
    }

    func testHKDFDerivesBridgeCompatibleSessionKey() throws {
        let fixture = try loadFixture()
        let privateKeyRaw = try decodeBase64(fixture.hkdf.myPrivateKeyRawBase64, label: "hkdf.myPrivateKeyRawBase64")

        let session = try E2ECryptoSession(privateKeyRawRepresentation: privateKeyRaw)
        let sessionKey = try session.deriveSessionKey(
            theirPublicKeyBase64: fixture.hkdf.theirPublicKeyBase64,
            otp: fixture.hkdf.otp
        )

        XCTAssertEqual(sessionKey.base64EncodedString(), fixture.hkdf.expectedSessionKeyBase64)
        XCTAssertEqual(sessionKey.count, 32)
    }

    func testAESGCMDecryptsBridgeFixture() throws {
        let fixture = try loadFixture()
        let sessionKey = try decodeBase64(fixture.aesGcm.sessionKeyBase64, label: "aesGcm.sessionKeyBase64")
        let message = EncryptedWireMessage(
            nonce: fixture.aesGcm.nonceBase64,
            ciphertext: fixture.aesGcm.ciphertextBase64,
            tag: fixture.aesGcm.tagBase64
        )

        let decrypted = try E2ECryptoSession.decrypt(message: message, sessionKey: sessionKey)

        XCTAssertEqual(String(data: decrypted, encoding: .utf8), fixture.aesGcm.plaintext)
    }

    func testAESGCMEncryptWithFixedNonceMatchesBridgeFixture() throws {
        let fixture = try loadFixture()
        let sessionKey = try decodeBase64(fixture.aesGcm.sessionKeyBase64, label: "aesGcm.sessionKeyBase64")
        let nonce = try decodeBase64(fixture.aesGcm.nonceBase64, label: "aesGcm.nonceBase64")
        let plaintext = Data(fixture.aesGcm.plaintext.utf8)

        let encrypted = try E2ECryptoSession.encrypt(plaintext: plaintext, sessionKey: sessionKey, nonce: nonce)

        XCTAssertEqual(encrypted.nonce, fixture.aesGcm.nonceBase64)
        XCTAssertEqual(encrypted.ciphertext, fixture.aesGcm.ciphertextBase64)
        XCTAssertEqual(encrypted.tag, fixture.aesGcm.tagBase64)
    }

    func testEncryptedWireCodecRoundTripsWireEnvelopeLosslessly() throws {
        let fixture = try loadFixture()
        let nonce = try decodeBase64(fixture.wireRoundTrip.nonceBase64, label: "wireRoundTrip.nonceBase64")
        let ciphertext = try decodeBase64(fixture.wireRoundTrip.ciphertextBase64, label: "wireRoundTrip.ciphertextBase64")
        let tag = try decodeBase64(fixture.wireRoundTrip.tagBase64, label: "wireRoundTrip.tagBase64")

        let wire = try EncryptedWireCodec.encode(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let encoded = try JSONEncoder().encode(wire)
        let decodedWire = try JSONDecoder().decode(EncryptedWireMessage.self, from: encoded)
        let decoded = try EncryptedWireCodec.decode(decodedWire)

        XCTAssertEqual(decoded.nonce, nonce)
        XCTAssertEqual(decoded.ciphertext, ciphertext)
        XCTAssertEqual(decoded.tag, tag)
    }

    func testDeriveSessionKeyRejectsMalformedPublicKeyBase64() throws {
        let fixture = try loadFixture()
        let privateKeyRaw = try decodeBase64(fixture.hkdf.myPrivateKeyRawBase64, label: "hkdf.myPrivateKeyRawBase64")
        let session = try E2ECryptoSession(privateKeyRawRepresentation: privateKeyRaw)

        XCTAssertThrowsError(try session.deriveSessionKey(theirPublicKeyBase64: "%%%not_base64%%%", otp: fixture.hkdf.otp)) { error in
            XCTAssertEqual(error as? E2ECryptoSessionError, .invalidPublicKeyBase64)
        }
    }

    func testDeriveSessionKeyRejectsWrongLengthPublicKey() throws {
        let fixture = try loadFixture()
        let privateKeyRaw = try decodeBase64(fixture.hkdf.myPrivateKeyRawBase64, label: "hkdf.myPrivateKeyRawBase64")
        let session = try E2ECryptoSession(privateKeyRawRepresentation: privateKeyRaw)
        let wrongLengthPublicKey = Data(repeating: 0xAB, count: 31).base64EncodedString()

        XCTAssertThrowsError(try session.deriveSessionKey(theirPublicKeyBase64: wrongLengthPublicKey, otp: fixture.hkdf.otp)) { error in
            XCTAssertEqual(error as? E2ECryptoSessionError, .invalidPublicKeyLength(31))
        }
    }

    func testEncryptRejectsWrongLengthSessionKey() throws {
        XCTAssertThrowsError(try E2ECryptoSession.encrypt(
            plaintext: Data("hello".utf8),
            sessionKey: Data(repeating: 0x01, count: 31)
        )) { error in
            XCTAssertEqual(error as? E2ECryptoSessionError, .invalidSessionKeyLength(31))
        }
    }

    func testEncryptedWireCodecRejectsMalformedBase64() throws {
        let message = EncryptedWireMessage(
            nonce: "%%%bad%%%",
            ciphertext: Data("ciphertext".utf8).base64EncodedString(),
            tag: Data(repeating: 0x00, count: 16).base64EncodedString()
        )

        XCTAssertThrowsError(try EncryptedWireCodec.decode(message)) { error in
            XCTAssertEqual(error as? EncryptedWireCodecError, .invalidBase64(field: "nonce"))
        }
    }

    func testEncryptedWireCodecRejectsWrongNonceAndTagLength() throws {
        XCTAssertThrowsError(try EncryptedWireCodec.encode(
            nonce: Data(repeating: 0x00, count: 11),
            ciphertext: Data("ciphertext".utf8),
            tag: Data(repeating: 0x01, count: 16)
        )) { error in
            XCTAssertEqual(error as? EncryptedWireCodecError, .invalidNonceLength(11))
        }

        XCTAssertThrowsError(try EncryptedWireCodec.encode(
            nonce: Data(repeating: 0x00, count: 12),
            ciphertext: Data("ciphertext".utf8),
            tag: Data(repeating: 0x01, count: 15)
        )) { error in
            XCTAssertEqual(error as? EncryptedWireCodecError, .invalidTagLength(15))
        }
    }

    func testDecryptRejectsTamperedCiphertext() throws {
        let fixture = try loadFixture()
        let sessionKey = try decodeBase64(fixture.aesGcm.sessionKeyBase64, label: "aesGcm.sessionKeyBase64")
        var ciphertext = try decodeBase64(fixture.aesGcm.ciphertextBase64, label: "aesGcm.ciphertextBase64")
        ciphertext[0] ^= 0xFF

        let tampered = EncryptedWireMessage(
            nonce: fixture.aesGcm.nonceBase64,
            ciphertext: ciphertext.base64EncodedString(),
            tag: fixture.aesGcm.tagBase64
        )

        XCTAssertThrowsError(try E2ECryptoSession.decrypt(message: tampered, sessionKey: sessionKey))
    }
}

private extension CryptoCompatibilityTests {
    struct CryptoFixture: Decodable {
        struct X25519Fixture: Decodable {
            let privateKeyRawBase64: String
            let expectedPublicKeyBase64: String
        }

        struct HKDFFixture: Decodable {
            let myPrivateKeyRawBase64: String
            let theirPublicKeyBase64: String
            let otp: String
            let expectedSessionKeyBase64: String
        }

        struct AESGCMFixture: Decodable {
            let sessionKeyBase64: String
            let nonceBase64: String
            let ciphertextBase64: String
            let tagBase64: String
            let plaintext: String
        }

        struct WireRoundTripFixture: Decodable {
            let nonceBase64: String
            let ciphertextBase64: String
            let tagBase64: String
        }

        let x25519: X25519Fixture
        let hkdf: HKDFFixture
        let aesGcm: AESGCMFixture
        let wireRoundTrip: WireRoundTripFixture
    }

    func loadFixture() throws -> CryptoFixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "crypto-fixtures", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CryptoFixture.self, from: data)
    }

    func decodeBase64(_ value: String, label: String) throws -> Data {
        let data = try XCTUnwrap(Data(base64Encoded: value), "Invalid base64 for \(label)")
        return data
    }
}
