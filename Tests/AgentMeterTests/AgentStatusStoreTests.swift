import AgentStatusCore
import Foundation
import XCTest

final class AgentStatusStoreTests: XCTestCase {
    private var sessionID = "agentmeter-test-\(UUID().uuidString)"

    override func tearDown() {
        AgentStatusStore.remove(sessionID: sessionID)
        super.tearDown()
    }

    func testWriteReadRemoveRoundTrip() throws {
        let payload = AgentStatusPayload(
            state: .waiting,
            sessionID: sessionID,
            message: "need you",
            cwd: "/tmp/x",
            processAncestry: [123, 45]
        )
        try AgentStatusStore.write(payload)
        XCTAssertEqual(AgentStatusStore.read(sessionID: sessionID)?.state, .waiting)
        XCTAssertEqual(AgentStatusStore.read(sessionID: sessionID)?.processAncestry, [123, 45])
        XCTAssertTrue(AgentStatusStore.remove(sessionID: sessionID))
        XCTAssertNil(AgentStatusStore.read(sessionID: sessionID))
    }

    func testSessionIDCannotEscapeStatusDirectory() throws {
        sessionID = "../../agentmeter-test-\(UUID().uuidString)"
        let url = try AgentStatusStore.write(
            AgentStatusPayload(state: .idle, sessionID: sessionID)
        )
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, AgentStatusStore.directory.standardizedFileURL)
    }

    func testSweepStaleDropsOldRecord() throws {
        try AgentStatusStore.write(
            AgentStatusPayload(
                state: .idle,
                sessionID: sessionID,
                updatedAt: Date(timeIntervalSinceNow: -3600)
            )
        )
        AgentStatusStore.sweepStale(olderThan: 60)
        XCTAssertNil(AgentStatusStore.read(sessionID: sessionID))
    }
}
