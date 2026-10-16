import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

/// `~/.claude/sessions/<pid>.json` as Claude Code writes it, read from a
/// temporary directory; the real registry is never touched.
final class ClaudeSessionRegistryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }

    /// The 2.1.300 layout, with the fields AgentMeter never reads included so
    /// the decoder is seen to leave them alone.
    private func document(
        pid: Int,
        status: String = "idle",
        waitingFor: String? = nil,
        startedAt: Int = 1_792_109_597_966,
        statusUpdatedAt: Int = 1_792_136_521_167
    ) -> String {
        let waiting = waitingFor.map { ",\"waitingFor\":\"\($0)\"" } ?? ""
        return """
        {"pid":\(pid),"sessionId":"3be19740-6d4f-4622-8cfb-64c5487e92cb","cwd":"/tmp/project",\
        "startedAt":\(startedAt),"procStart":"Fri Oct 16 00:13:17 2026","version":"2.1.300",\
        "peerProtocol":1,"peerFeatures":["notify_idle"],"kind":"interactive","entrypoint":"claude-vscode",\
        "pidDomain":"darwin","messagingSocketPath":"/tmp/cc-socks/\(pid).sock","name":"project-02",\
        "nameSource":"derived","updatedAt":\(statusUpdatedAt),"status":"\(status)"\(waiting),\
        "statusUpdatedAt":\(statusUpdatedAt)}
        """
    }

    func testDecodeReadsTheFieldsAgentMeterUsesAndIgnoresTheRest() throws {
        let entry = try XCTUnwrap(ClaudeSessionRegistry.decode(
            Data(document(pid: 4242, status: "waiting", waitingFor: "permission prompt").utf8)))

        XCTAssertEqual(entry.pid, 4242)
        XCTAssertEqual(entry.sessionID, "3be19740-6d4f-4622-8cfb-64c5487e92cb")
        XCTAssertEqual(entry.cwd, "/tmp/project")
        XCTAssertEqual(entry.startedAt, Date(timeIntervalSince1970: 1_792_109_597.966))
        XCTAssertEqual(entry.status, .waiting)
        XCTAssertEqual(entry.agentState, .waiting)
        XCTAssertEqual(entry.waitingFor, "permission prompt")
        XCTAssertEqual(entry.statusUpdatedAt, Date(timeIntervalSince1970: 1_792_136_521.167))
    }

    func testEveryKnownStatusMapsAndAnUnknownOneReadsAsNothing() throws {
        func state(_ status: String) throws -> AgentStatusState? {
            try XCTUnwrap(ClaudeSessionRegistry.decode(Data(document(pid: 1, status: status).utf8))).agentState
        }
        XCTAssertEqual(try state("busy"), .working)
        XCTAssertEqual(try state("waiting"), .waiting)
        XCTAssertEqual(try state("idle"), .idle)
        XCTAssertEqual(try state("shell"), .idle)
        // A status a later Claude Code may add is not a state AgentMeter can
        // show; the entry still decodes, and the row falls back to the hook.
        XCTAssertNil(try state("compacting"))
    }

    func testMissingAndMistypedFieldsDecodeAsAbsentAndOnlyThePIDIsRequired() {
        let bare = ClaudeSessionRegistry.decode(Data(#"{"pid":7}"#.utf8))
        XCTAssertEqual(bare?.pid, 7)
        XCTAssertNil(bare?.sessionID)
        XCTAssertNil(bare?.status)
        XCTAssertNil(bare?.startedAt)
        XCTAssertNil(bare?.statusUpdatedAt)

        let mistyped = ClaudeSessionRegistry.decode(Data("""
        {"pid":7,"sessionId":12,"cwd":["x"],"startedAt":"yesterday","status":true,"waitingFor":9,"statusUpdatedAt":null}
        """.utf8))
        XCTAssertEqual(mistyped?.pid, 7)
        XCTAssertNil(mistyped?.sessionID)
        XCTAssertNil(mistyped?.cwd)
        XCTAssertNil(mistyped?.startedAt)
        XCTAssertNil(mistyped?.status)
        XCTAssertNil(mistyped?.waitingFor)

        XCTAssertNil(ClaudeSessionRegistry.decode(Data(#"{"sessionId":"a","status":"busy"}"#.utf8)), "no pid")
        XCTAssertNil(ClaudeSessionRegistry.decode(Data(#"{"pid":0}"#.utf8)))
        XCTAssertNil(ClaudeSessionRegistry.decode(Data(#"{"pid":true}"#.utf8)))
        XCTAssertNil(ClaudeSessionRegistry.decode(Data(#"[{"pid":7}]"#.utf8)))
        XCTAssertNil(ClaudeSessionRegistry.decode(Data()))
    }

    func testWaitingForIsCappedAndATimestampOutOfRangeIsDropped() {
        let long = String(repeating: "x", count: 500)
        let entry = ClaudeSessionRegistry.decode(Data("""
        {"pid":7,"waitingFor":"\(long)","startedAt":-5,"statusUpdatedAt":5e15}
        """.utf8))
        XCTAssertEqual(entry?.waitingFor?.count, ClaudeSessionRegistry.waitingForMaximumLength)
        XCTAssertNil(entry?.startedAt)
        XCTAssertNil(entry?.statusUpdatedAt)
    }

    func testReadAllKeepsTheGoodEntriesAndSkipsEverythingElse() throws {
        try write("100.json", document(pid: 100, status: "busy"))
        try write("200.json", document(pid: 200, status: "idle"))
        // The messaging-socket secret beside each entry: never opened.
        try write("100.4ff919bb6851859219ce7cb3481018867fcd0468d97aae0e8726c49f4a52e79e.key", "secret")
        // Corrupt, and a write caught halfway.
        try write("300.json", "{not json")
        try write("400.json", String(document(pid: 400, status: "busy").prefix(80)))
        // Not a registry entry at all.
        try write("notes.json", document(pid: 500))
        try write("600.json", document(pid: 601), "a file whose own pid disagrees with its name")

        let entries = ClaudeSessionRegistry.readAll(in: directory)

        XCTAssertEqual(Set(entries.keys), [100, 200])
        XCTAssertEqual(entries[100]?.agentState, .working)
        XCTAssertEqual(entries[200]?.agentState, .idle)
    }

    private func write(_ name: String, _ contents: String, _ note: String) throws {
        try write(name, contents)
    }

    func testReadAllSkipsOversizedFilesAndSymlinks() throws {
        try write("100.json", document(pid: 100))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("200.json"),
            withDestinationURL: directory.appendingPathComponent("100.json"))
        let padding = String(repeating: " ", count: ClaudeSessionRegistry.maximumFileBytes + 1)
        try write("300.json", document(pid: 300) + padding)

        XCTAssertEqual(Set(ClaudeSessionRegistry.readAll(in: directory).keys), [100])
    }

    func testReadAllOfAMissingDirectoryIsEmpty() {
        let missing = directory.appendingPathComponent("absent", isDirectory: true)
        XCTAssertTrue(ClaudeSessionRegistry.readAll(in: missing).isEmpty)
    }

    func testEntryLookupGuardsAgainstAnEarlierHolderOfThePID() throws {
        let now = Date(timeIntervalSince1970: 1_792_200_000)
        let processStart = now.addingTimeInterval(-600)
        func entry(startedAt: Date?) -> ClaudeSessionRegistryEntry {
            ClaudeSessionRegistryEntry(
                pid: 100, sessionID: "s", cwd: "/tmp/p", startedAt: startedAt,
                status: .busy, waitingFor: nil, statusUpdatedAt: now)
        }
        func lookup(_ entry: ClaudeSessionRegistryEntry) -> ClaudeSessionRegistryEntry? {
            ClaudeSessionRegistry.entry(for: 100, processStartedAt: processStart, observedAt: now, in: [100: entry])
        }

        // Registered four seconds after the process started: the live one.
        XCTAssertNotNil(lookup(entry(startedAt: processStart.addingTimeInterval(4))))
        // `ps` ages are whole seconds; a hair before the process is still it.
        XCTAssertNotNil(lookup(entry(startedAt: processStart.addingTimeInterval(-ClaudeSessionRegistry.startedAtTolerance))))
        // A file left by the PID's previous holder, started an hour earlier.
        XCTAssertNil(lookup(entry(startedAt: processStart.addingTimeInterval(-3_600))))
        // Without a start time the entry cannot be placed in a PID lifetime.
        XCTAssertNil(lookup(entry(startedAt: nil)))
        // A start in the future is garbage.
        XCTAssertNil(lookup(entry(startedAt: now.addingTimeInterval(3_600))))
        XCTAssertNil(ClaudeSessionRegistry.entry(for: 999, processStartedAt: processStart, observedAt: now,
                                                 in: [100: entry(startedAt: processStart)]))
    }
}
