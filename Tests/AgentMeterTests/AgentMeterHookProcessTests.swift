import AgentStatusCore
import Foundation
import XCTest

/// Runs the built `agentmeter-hook` executable on hook-shaped stdin, with its
/// home redirected (`CFFIXED_USER_HOME`) into a temporary directory, and
/// checks what it leaves behind: the status payload (unchanged behaviour),
/// the turn ledger, and the exit status.
final class AgentMeterHookProcessTests: XCTestCase {
    private var home: URL!
    private var helper: URL!
    private let session = "00000000-0000-4000-8000-000000000003"

    override func setUpWithError() throws {
        // SwiftPM builds the executable next to the test bundle.
        let candidate = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AgentMeterHook")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("AgentMeterHook not built next to the tests")
        }
        helper = candidate
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeter-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private var statusDirectory: URL {
        home.appendingPathComponent("Library/Application Support/AgentMeter/agent-status", isDirectory: true)
    }

    @discardableResult
    private func run(_ command: String, _ json: String, environment extra: [String: String] = [:]) throws -> Int32 {
        let process = Process()
        process.executableURL = helper
        process.arguments = [command]
        process.environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path, "PATH": "/usr/bin:/bin"]
            .merging(extra) { _, new in new }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(json.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func payload() throws -> [String: Any]? {
        let url = statusDirectory.appendingPathComponent("\(session).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func ledger() -> TaskLedger? {
        TaskLedgerStore.read(sessionID: session, in: statusDirectory.appendingPathComponent("turns"))
    }

    private func input(_ fields: String) -> String {
        #"{"session_id":"\#(session)","cwd":"/tmp/proj","transcript_path":"/tmp/t.jsonl",\#(fields)}"#
    }

    func testPayloadUnchangedAndLedgerFollowsAPausedTask() throws {
        XCTAssertEqual(try run("working", input(#""hook_event_name":"UserPromptSubmit","prompt_id":"prompt-three","prompt":"Fix it""#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "working")
        XCTAssertNil(try payload()?["pendingBackgroundTasks"])
        XCTAssertEqual(ledger()?.task?.key, "prompt-three")

        XCTAssertEqual(try run("idle", input(#""hook_event_name":"Stop","stop_hook_active":false,"session_crons":[],"last_assistant_message":"Launched.","background_tasks":[{"id":"a0000000000000001","type":"subagent","status":"running","description":"Sleep"}]"#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "working", "a pause, as before")
        XCTAssertEqual(try payload()?["pendingBackgroundTasks"] as? Int, 1)
        XCTAssertEqual(try payload()?["pendingSubagents"] as? Int, 1)
        XCTAssertEqual(ledger()?.task?.stop?.blocking, 1)

        // A subagent's background shell: payload as for any tool call, ledger notes the owner.
        XCTAssertEqual(try run("working", input(#""hook_event_name":"PostToolUse","agent_id":"a0000000000000001","tool_name":"Bash","tool_input":{"command":"sleep 40","run_in_background":true},"tool_response":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"backgroundTaskId":"b00000002"}"#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "working")
        XCTAssertEqual(ledger()?.backgroundLaunches.map(\.taskID), ["b00000002"])
        XCTAssertEqual(ledger()?.backgroundLaunches.first?.agentID, "a0000000000000001")

        XCTAssertEqual(try run("working", input(#""hook_event_name":"UserPromptSubmit","prompt_id":"report-three-a","prompt":"<agent-message from=\"a0000000000000001\">\n[Subagent hand-back]""#)), 0)
        XCTAssertEqual(try run("idle", input(#""hook_event_name":"Stop","background_tasks":[{"id":"b00000002","type":"shell","status":"running"}]"#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "working")
        XCTAssertEqual(try payload()?["pendingBackgroundTasks"] as? Int, 1)
        XCTAssertEqual(try payload()?["pendingSubagents"] as? Int, 0)
        XCTAssertEqual(ledger()?.task?.key, "prompt-three", "the report joined the human prompt's task")
        XCTAssertEqual(ledger()?.task?.stop?.uncertainShells, 1, "C1a: the subagent's shell may bring it back")

        // Nothing from the prompt or the tool's output lands on disk.
        let raw = try String(contentsOf: TaskLedgerStore.fileURL(forSession: session, in: statusDirectory.appendingPathComponent("turns")), encoding: .utf8)
        for fragment in ["Fix it", "hand-back", "sleep 40", "Launched."] {
            XCTAssertFalse(raw.contains(fragment), fragment)
        }
    }

    /// Claude Code's own say in the hook's environment, 2026-10-29: a
    /// `claude -p` run from another session's `Bash` saw "0", the editor
    /// session that ran it "1".
    func testTheTaskKeepsWhetherClaudeCodeCountedTheSessionAttended() throws {
        let prompt = input(#""hook_event_name":"UserPromptSubmit","prompt_id":"5c0a77e1","prompt":"Replay step 3""#)
        let stop = input(#""hook_event_name":"Stop","background_tasks":[]"#)
        XCTAssertEqual(try run("working", prompt, environment: ["CLAUDE_CODE_SESSION_ATTENDED": "0"]), 0)
        XCTAssertEqual(ledger()?.task?.attended, false)
        XCTAssertEqual(try run("idle", stop, environment: ["CLAUDE_CODE_SESSION_ATTENDED": "0"]), 0)
        XCTAssertEqual(ledger()?.task?.attended, false)
        XCTAssertEqual(try payload()?["state"] as? String, "idle", "the payload is written as before")

        // A person resumes the session: a new task, with its own value.
        XCTAssertEqual(try run("working", input(#""hook_event_name":"UserPromptSubmit","prompt_id":"81d2e0f4","prompt":"Go on""#),
                               environment: ["CLAUDE_CODE_SESSION_ATTENDED": "1"]), 0)
        XCTAssertEqual(ledger()?.task?.key, "81d2e0f4")
        XCTAssertEqual(ledger()?.task?.attended, true)
    }

    func testABackgroundSessionCountsAsAPersonsRun() throws {
        let environment = ["CLAUDE_CODE_SESSION_ATTENDED": "0", "CLAUDE_CODE_SESSION_KIND": "bg"]
        XCTAssertEqual(try run("working", input(#""hook_event_name":"UserPromptSubmit","prompt_id":"5c0a77e1","prompt":"Fix the tests""#),
                               environment: environment), 0)
        XCTAssertEqual(ledger()?.task?.attended, true)
    }

    func testABuildThatDoesNotSayLeavesItUnknown() throws {
        XCTAssertEqual(try run("working", input(#""hook_event_name":"UserPromptSubmit","prompt_id":"5c0a77e1","prompt":"Hi""#)), 0)
        XCTAssertNil(ledger()?.task?.attended)
        XCTAssertEqual(try run("idle", input(#""hook_event_name":"Stop","background_tasks":[]"#),
                               environment: ["CLAUDE_CODE_SESSION_ATTENDED": "yes"]), 0)
        XCTAssertNil(ledger()?.task?.attended, "only 1 and 0 are values")
        XCTAssertNotNil(ledger()?.task?.stop)
    }

    func testMalformedNewFieldsNeverCostThePayloadWrite() throws {
        XCTAssertEqual(try run("working", input(#""hook_event_name":5,"prompt_id":["x"],"prompt":{"a":1},"transcript_path":7,"tool_response":"plain text","session_crons":{"a":1},"stop_hook_active":"yes""#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "working")
        XCTAssertNil(ledger(), "no event name the ledger knows")
        XCTAssertEqual(try run("working", input(#""hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":[1,2]"#)), 0)
        XCTAssertEqual(try run("idle", input(#""hook_event_name":"Stop","background_tasks":"nope""#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "idle")
        XCTAssertEqual(try run("working", "{not json"), 64, "invalid JSON still exits 64")
    }

    func testFailuresAndSessionEnd() throws {
        try run("working", input(#""hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"go""#))
        // A subagent's failure writes nothing, as before.
        XCTAssertEqual(try run("error", input(#""hook_event_name":"StopFailure","agent_id":"sub","error":"rate_limit""#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "working")
        XCTAssertNil(ledger()?.task?.failure)
        XCTAssertEqual(try run("error", input(#""hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests""#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "error")
        XCTAssertEqual(try payload()?["message"] as? String, "429 Too Many Requests", "payload message unchanged")
        XCTAssertEqual(ledger()?.task?.failure?.error, "rate_limit")
        XCTAssertEqual(try run("waiting", input(#""hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#)), 0)
        XCTAssertEqual(try payload()?["state"] as? String, "waiting")
        XCTAssertEqual(try run("remove", input(#""hook_event_name":"SessionEnd","reason":"prompt_input_exit""#)), 0)
        XCTAssertNil(try payload(), "payload removed, as before")
        XCTAssertEqual(ledger()?.endReason, "prompt_input_exit", "the ledger stays for the detector")
        let mode = try FileManager.default.attributesOfItem(
            atPath: TaskLedgerStore.fileURL(forSession: session, in: statusDirectory.appendingPathComponent("turns")).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
