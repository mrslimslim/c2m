import XCTest
@testable import CodePilotFeatures
@testable import CodePilotCore

final class ConnectionsViewModelTests: XCTestCase {
    func testParsePayloadAcceptsLANJSONObjectPayload() throws {
        let payload = #"{"host":"10.0.0.8","port":19260,"token":"","bridge_pubkey":"bridge-key","otp":"654321","protocol":"codepilot-bridge-v1"}"#

        let config = try ConnectionPayloadParser.parse(payload)

        XCTAssertEqual(
            config,
            .lan(
                host: "10.0.0.8",
                port: 19260,
                token: "",
                bridgePublicKey: "bridge-key",
                otp: "654321"
            )
        )
    }

    func testParsePayloadPrefersRelayModeAndNormalizesRelayURL() throws {
        let payload = "codepilot://pair?relay=wss%3A%2F%2Frelay.example.com%2F&channel=alpha-123&bridge_pubkey=bridge-key&otp=123456"

        let config = try ConnectionPayloadParser.parse(payload)

        XCTAssertEqual(
            config,
            .relay(
                url: "wss://relay.example.com",
                channel: "alpha-123",
                bridgePublicKey: "bridge-key",
                otp: "123456"
            )
        )
    }

    func testSelectingSavedConnectionTracksSelectionAndReturnsConfig() {
        let relay = SavedConnection(
            id: "relay-home",
            name: "Home Relay",
            config: .relay(
                url: "wss://relay.example.com",
                channel: "alpha",
                bridgePublicKey: "bridge-key",
                otp: "654321"
            )
        )
        let lan = SavedConnection(
            id: "lan-office",
            name: "Office LAN",
            config: .lan(
                host: "10.0.0.24",
                port: 19260,
                token: "legacy-token",
                bridgePublicKey: "",
                otp: ""
            )
        )
        let viewModel = ConnectionsViewModel(savedConnections: [relay, lan])

        let selected = viewModel.selectSavedConnection(id: "lan-office")

        XCTAssertEqual(viewModel.selectedSavedConnectionID, "lan-office")
        XCTAssertEqual(selected, lan.config)
    }
}
