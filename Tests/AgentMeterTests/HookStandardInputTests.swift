import AgentStatusCore
import Foundation
import XCTest

/// The helper reads its stdin through `HookStandardInput`; these feed it real
/// pipes from child processes, the way Claude Code hands hook input over.
final class HookStandardInputTests: XCTestCase {
    /// Runs a shell script with its stdout piped to the reader.
    private func readAll(
        script: String,
        limit: Int = HookStandardInput.maximumBytes
    ) throws -> (data: Data?, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = HookStandardInput.readAll(from: pipe.fileHandleForReading, limit: limit)
        // Closed before waiting: a reader that stopped early would otherwise
        // leave the writer blocked on a full pipe, and the test would hang
        // instead of failing on the status.
        try? pipe.fileHandleForReading.close()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }

    /// The slice of hook stdin the helper decodes, keyed the way its own
    /// input model is.
    private struct Input: Decodable {
        let sessionID: String?
        let cwd: String?
        let agentID: String?
        let backgroundTasks: HookBackgroundTasks?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd
            case agentID = "agent_id"
            case backgroundTasks = "background_tasks"
        }
    }

    func testAPostToolUseInputLargerThanTheOldCapComesBackWhole() throws {
        // A Read of a 400 KB file: the sampled failures ran 400 KB to 976 KB,
        // every one of them cut at 131,072 bytes.
        let (data, status) = try readAll(script: """
        printf '{"session_id":"3be19740","cwd":"/tmp/p","hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"file":{"content":"'
        head -c 409600 /dev/zero | tr '\\0' x
        printf '"}}}'
        """)

        XCTAssertEqual(status, 0)
        let input = try JSONDecoder().decode(Input.self, from: try XCTUnwrap(data))
        XCTAssertEqual(input.sessionID, "3be19740")
        XCTAssertEqual(input.cwd, "/tmp/p")
    }

    func testAStopWithALongFinalMessageStillRecordsIdle() throws {
        // Same path for the Stop input, whose `last_assistant_message` is the
        // whole final text: cut off, no `idle` is ever written.
        let (data, _) = try readAll(script: """
        printf '{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"'
        head -c 204800 /dev/zero | tr '\\0' x
        printf '","background_tasks":[]}'
        """)

        let input = try JSONDecoder().decode(Input.self, from: try XCTUnwrap(data))
        XCTAssertEqual(
            AgentStatusState.recordedState(requested: .idle, backgroundTasks: input.backgroundTasks, agentID: input.agentID),
            .idle
        )
    }

    func testEmptyInputIsEmptyAndAnOversizedOneIsDrainedAndRefused() throws {
        XCTAssertEqual(try readAll(script: "exit 0").data, Data())

        // Drained to EOF: the writer finishes normally instead of dying of
        // SIGPIPE against a reader that stopped early.
        let (data, status) = try readAll(script: "head -c 300000 /dev/zero | tr '\\0' '{'", limit: 128 * 1024)
        XCTAssertNil(data)
        XCTAssertEqual(status, 0)
    }
}
