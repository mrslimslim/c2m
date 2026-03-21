import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class PendingSessionCoordinatorTests: XCTestCase {
    func testResolveFromSessionListReturnsNewestUnknownSessionAndConsumesPendingCreation() {
        let coordinator = PendingSessionCoordinator()
        coordinator.registerPendingCommand(
            "explain this repo",
            for: "connection-1",
            timestamp: 1_700_000_050
        )

        let olderKnown = makeSession(
            id: "session-1",
            createdAt: 1_700_000_000,
            lastActiveAt: 1_700_000_010
        )
        let newestUnknown = makeSession(
            id: "session-3",
            createdAt: 1_700_000_060,
            lastActiveAt: 1_700_000_090
        )
        let olderUnknown = makeSession(
            id: "session-2",
            createdAt: 1_700_000_055,
            lastActiveAt: 1_700_000_070
        )

        let resolution = coordinator.resolvePendingCommand(
            for: "connection-1",
            knownSessionIDs: [olderKnown.id],
            incomingSessions: [olderKnown, olderUnknown, newestUnknown]
        )

        XCTAssertEqual(
            resolution,
            .init(
                connectionID: "connection-1",
                sessionID: newestUnknown.id,
                command: "explain this repo",
                timestamp: 1_700_000_050
            )
        )
        XCTAssertNil(
            coordinator.resolvePendingCommand(
                for: "connection-1",
                knownSessionIDs: [olderKnown.id, newestUnknown.id],
                incomingSessions: [olderKnown, newestUnknown]
            )
        )
    }

    func testResolveFromUnknownEventBindsPendingCommandWhenSessionListHasNotArrivedYet() {
        let coordinator = PendingSessionCoordinator()
        coordinator.registerPendingCommand(
            "run tests",
            for: "connection-1",
            timestamp: 1_700_000_123
        )

        let resolution = coordinator.resolvePendingCommand(
            for: "connection-1",
            knownSessionIDs: ["existing-session"],
            incomingEventSessionID: "temp-session"
        )

        XCTAssertEqual(
            resolution,
            .init(
                connectionID: "connection-1",
                sessionID: "temp-session",
                command: "run tests",
                timestamp: 1_700_000_123
            )
        )
        XCTAssertNil(
            coordinator.resolvePendingCommand(
                for: "connection-1",
                knownSessionIDs: ["existing-session", "temp-session"],
                incomingEventSessionID: "temp-session"
            )
        )
    }
}

private extension PendingSessionCoordinatorTests {
    func makeSession(id: String, createdAt: Int, lastActiveAt: Int) -> SessionInfo {
        .init(
            id: id,
            agentType: .codex,
            workDir: "/tmp/repo",
            state: .thinking,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt
        )
    }
}
