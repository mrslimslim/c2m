import XCTest
@testable import CodePilotCore
@testable import CodePilotFeatures

final class DiagnosticsViewModelTests: XCTestCase {
    func testReconnectTransitionAndSensitiveValuesAreRedactedInOutput() {
        let diagnostics = DiagnosticsStore()
        diagnostics.recordStateTransition(from: .connected(encrypted: true, clientId: "client-1"), to: .reconnecting)
        diagnostics.recordInfo("token=legacy-token otp=654321 ciphertext=ABC123XYZ")

        let viewModel = DiagnosticsViewModel(diagnosticsStore: diagnostics)
        viewModel.refresh()

        XCTAssertTrue(viewModel.redactedLines.contains { $0.contains("state: connected(encrypted) -> reconnecting") })
        XCTAssertTrue(viewModel.redactedLines.contains { $0.contains("token=[REDACTED]") })
        XCTAssertTrue(viewModel.redactedLines.contains { $0.contains("otp=[REDACTED]") })
        XCTAssertTrue(viewModel.redactedLines.contains { $0.contains("ciphertext=[REDACTED]") })
        XCTAssertFalse(viewModel.redactedLines.contains { $0.contains("legacy-token") })
        XCTAssertFalse(viewModel.redactedLines.contains { $0.contains("654321") })
        XCTAssertFalse(viewModel.redactedLines.contains { $0.contains("ABC123XYZ") })
    }

    func testLatencyUpdatesWithPingAndPongEvents() {
        let diagnostics = DiagnosticsStore()
        let viewModel = DiagnosticsViewModel(diagnosticsStore: diagnostics)

        diagnostics.recordInfo("ping:1700000010")
        diagnostics.recordInfo("pong:120ms")
        viewModel.refresh()

        XCTAssertEqual(viewModel.latestLatencyMs, 120)

        diagnostics.recordInfo("pong:44ms")
        viewModel.refresh()

        XCTAssertEqual(viewModel.latestLatencyMs, 44)
    }

    func testTimelineStyleCommandTextIsRedactedInDiagnosticsOutput() {
        let diagnostics = DiagnosticsStore()
        diagnostics.recordInfo("Exec done: run --token=legacy-token otp=654321 ciphertext=ABC123XYZ")
        let viewModel = DiagnosticsViewModel(diagnosticsStore: diagnostics)

        viewModel.refresh()

        XCTAssertTrue(
            viewModel.redactedLines.contains(
                "Exec done: run --token=[REDACTED] otp=[REDACTED] ciphertext=[REDACTED]"
            )
        )
        XCTAssertFalse(viewModel.redactedLines.joined(separator: "\n").contains("legacy-token"))
        XCTAssertFalse(viewModel.redactedLines.joined(separator: "\n").contains("654321"))
        XCTAssertFalse(viewModel.redactedLines.joined(separator: "\n").contains("ABC123XYZ"))
    }
}
