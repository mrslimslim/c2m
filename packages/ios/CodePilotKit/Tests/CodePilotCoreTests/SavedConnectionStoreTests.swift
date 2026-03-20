import XCTest
@testable import CodePilotCore

final class SavedConnectionStoreTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var keychainServiceName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SavedConnectionStoreTests.\(UUID().uuidString)"
        keychainServiceName = "com.codepilot.tests.keychain.\(UUID().uuidString)"
    }

    override func tearDown() {
        if let defaultsSuiteName {
            UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        }
        super.tearDown()
    }

    func testKeychainSecretStorePersistsAcrossStoreInstances() throws {
        let account = "connection.secret"
        let storeA = KeychainSecretStore(service: keychainServiceName)
        let storeB = KeychainSecretStore(service: keychainServiceName)

        try storeA.removeSecret(for: account)
        try storeA.setSecret("otp-123456", for: account)

        XCTAssertEqual(try storeB.secret(for: account), "otp-123456")

        try storeB.removeSecret(for: account)
        XCTAssertNil(try storeA.secret(for: account))
    }

    func testSaveAndLoadSnapshotSeparatesMetadataFromSecrets() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let secretStore = KeychainSecretStore(service: keychainServiceName)
        let store = SavedConnectionStore(
            userDefaults: defaults,
            secretStore: secretStore
        )
        let snapshot = SavedConnectionsSnapshot(
            connections: [
                .init(
                    id: "lan-office",
                    name: "Office LAN",
                    config: .lan(
                        host: "10.0.0.24",
                        port: 19260,
                        token: "legacy-token-123",
                        bridgePublicKey: "bridge-public-key-value",
                        otp: "654321"
                    )
                ),
                .init(
                    id: "relay-team",
                    name: "Team Relay",
                    config: .relay(
                        url: "wss://relay.example.com",
                        channel: "alpha",
                        bridgePublicKey: "relay-bridge-key",
                        otp: "111222"
                    )
                ),
            ],
            selectedConnectionID: "relay-team"
        )

        try store.saveSnapshot(snapshot)
        let loaded = store.loadSnapshot()

        XCTAssertEqual(loaded, snapshot)

        let metadataData = try XCTUnwrap(defaults.data(forKey: SavedConnectionStore.metadataDefaultsKey))
        let metadataText = String(decoding: metadataData, as: UTF8.self)
        XCTAssertFalse(metadataText.contains("legacy-token-123"))
        XCTAssertFalse(metadataText.contains("654321"))
        XCTAssertFalse(metadataText.contains("bridge-public-key-value"))
        XCTAssertFalse(metadataText.contains("relay-bridge-key"))
    }

    func testColdLaunchRestoreReadsPreviouslySavedSelectionAndConfigs() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let secretStore = KeychainSecretStore(service: keychainServiceName)
        let firstLaunchStore = SavedConnectionStore(
            userDefaults: defaults,
            secretStore: secretStore
        )

        let originalSnapshot = SavedConnectionsSnapshot(
            connections: [
                .init(
                    id: "local-lan",
                    name: "Local LAN",
                    config: .lan(
                        host: "127.0.0.1",
                        port: 19260,
                        token: "",
                        bridgePublicKey: "bridge-key",
                        otp: "123456"
                    )
                ),
            ],
            selectedConnectionID: "local-lan"
        )
        try firstLaunchStore.saveSnapshot(originalSnapshot)

        let coldLaunchStore = SavedConnectionStore(
            userDefaults: defaults,
            secretStore: KeychainSecretStore(service: keychainServiceName)
        )
        let restoredSnapshot = coldLaunchStore.loadSnapshot()

        XCTAssertEqual(restoredSnapshot, originalSnapshot)
    }
}
