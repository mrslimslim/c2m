import XCTest
@testable import CodePilotCore

final class SessionReplayBootstrapPlannerTests: XCTestCase {
    func testReconnectBootstrapKeepsRestoredSessionsWhenConnectionMappingWasLost() {
        let sessionIDs = SessionReplayBootstrapPlanner.sessionIDsForReconnect(
            restoredSessionIDs: ["restored-session"],
            previouslyMappedSessionIDs: [],
            currentMappedSessionIDs: ["restored-session", "unseen-session"]
        ) { sessionID in
            sessionID
        }

        XCTAssertEqual(
            sessionIDs,
            ["restored-session"],
            "replay bootstrap should recover sessions we restored locally without replaying unseen sessions"
        )
    }

    func testReconnectBootstrapResolvesAliasSeedsIntoCurrentCanonicalSessionIDs() {
        let sessionIDs = SessionReplayBootstrapPlanner.sessionIDsForReconnect(
            restoredSessionIDs: ["temp-session"],
            previouslyMappedSessionIDs: ["temp-session"],
            currentMappedSessionIDs: ["stable-session"]
        ) { sessionID in
            switch sessionID {
            case "temp-session":
                "stable-session"
            default:
                sessionID
            }
        }

        XCTAssertEqual(sessionIDs, ["stable-session"])
    }
}
