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
        // The store is the real one under Application Support, beside the live
        // sessions' states. Sweeping relative to today deleted every one of them
        // older than a minute on each `swift test`; a clock set to 1970 leaves
        // nothing but this record old enough to go.
        let ancient = Date(timeIntervalSince1970: 0)
        try AgentStatusStore.write(
            AgentStatusPayload(
                state: .idle,
                sessionID: sessionID,
                updatedAt: ancient
            )
        )
        AgentStatusStore.sweepStale(olderThan: 60, now: ancient.addingTimeInterval(3_600))
        XCTAssertNil(AgentStatusStore.read(sessionID: sessionID))
    }

    func testLegacyPayloadWithoutPendingBackgroundTasksDecodes() throws {
        // A file written by a helper that predates the field: no
        // `pendingBackgroundTasks` key at all. An app update must still read it.
        let legacy = """
        {
          "cwd" : "/tmp/x",
          "processAncestry" : [ 123, 45 ],
          "sessionID" : "\(sessionID)",
          "state" : "idle",
          "updatedAt" : "2025-01-01T00:00:00Z"
        }
        """
        try FileManager.default.createDirectory(at: AgentStatusStore.directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: AgentStatusStore.fileURL(forSession: sessionID))

        let payload = AgentStatusStore.read(sessionID: sessionID)

        XCTAssertEqual(payload?.state, .idle)
        XCTAssertEqual(payload?.processAncestry, [123, 45])
        XCTAssertNil(payload?.pendingBackgroundTasks)
        XCTAssertNil(payload?.pendingSubagents)
    }

    func testWriteReadRoundTripKeepsPendingBackgroundTasks() throws {
        try AgentStatusStore.write(
            AgentStatusPayload(
                state: .working,
                sessionID: sessionID,
                pendingBackgroundTasks: 2,
                pendingSubagents: 1
            )
        )
        XCTAssertEqual(AgentStatusStore.read(sessionID: sessionID)?.pendingBackgroundTasks, 2)
        XCTAssertEqual(AgentStatusStore.read(sessionID: sessionID)?.pendingSubagents, 1)

        // Absent stays absent: a `working` from PreToolUse carries no count.
        try AgentStatusStore.write(AgentStatusPayload(state: .working, sessionID: sessionID))
        XCTAssertNil(AgentStatusStore.read(sessionID: sessionID)?.pendingBackgroundTasks)
        XCTAssertNil(AgentStatusStore.read(sessionID: sessionID)?.pendingSubagents)

        // A negative count cannot come from an array walk; it is normalized, not stored.
        try AgentStatusStore.write(
            AgentStatusPayload(state: .idle, sessionID: sessionID, pendingBackgroundTasks: -1, pendingSubagents: -1)
        )
        XCTAssertEqual(AgentStatusStore.read(sessionID: sessionID)?.pendingBackgroundTasks, 0)
        XCTAssertEqual(AgentStatusStore.read(sessionID: sessionID)?.pendingSubagents, 0)
    }
}
