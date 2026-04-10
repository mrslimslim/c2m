import XCTest
@testable import CodePilotCore

final class SessionReplayBootstrapPlannerTests: XCTestCase {
    func testReconnectBootstrapReplaysRestoredSessionsWhenBridgeStartsEmpty() {
        let sessionIDs = SessionReplayBootstrapPlanner.sessionIDsForReconnect(
            restoredSessionIDs: ["restored-session", "temp-session"],
            previouslyMappedSessionIDs: [],
            currentMappedSessionIDs: []
        ) { sessionID in
            switch sessionID {
            case "temp-session":
                "stable-session"
            default:
                sessionID
            }
        }

        XCTAssertEqual(
            sessionIDs,
            ["restored-session", "stable-session"],
            "replay bootstrap should recover locally restored sessions when the bridge reconnects without any live session list"
        )
    }

    func testReconnectBootstrapReplaysRestoredSessionsThatBridgeStillLists() {
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
            "replay bootstrap should recover the restored session when the bridge still lists it after reconnect"
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
