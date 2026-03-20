import XCTest
@testable import CodePilotCore

final class DiagnosticsRedactorTests: XCTestCase {
    func testRedactsTimelineStyleCommandOutput() {
        let input = "Exec done: run --token=legacy-token otp=654321 ciphertext=ABC123XYZ"

        let output = DiagnosticsRedactor.redact(input)

        XCTAssertEqual(
            output,
            "Exec done: run --token=[REDACTED] otp=[REDACTED] ciphertext=[REDACTED]"
        )
        XCTAssertFalse(output.contains("legacy-token"))
        XCTAssertFalse(output.contains("654321"))
        XCTAssertFalse(output.contains("ABC123XYZ"))
    }
}
