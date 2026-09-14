import AgentStatusCore
import Foundation
import XCTest

/// The hook helper's `idle` command decides between idle and working from the
/// `Stop` input's `background_tasks`; these feed it Stop-shaped stdin JSON.
final class HookBackgroundTasksTests: XCTestCase {
    /// The slice of hook stdin the helper decodes for this decision, keyed the
    /// way the helper's own input model is.
    private struct StopInput: Decodable {
        let backgroundTasks: HookBackgroundTasks?

        enum CodingKeys: String, CodingKey {
            case backgroundTasks = "background_tasks"
        }
    }

    private func tasks(_ json: String) throws -> HookBackgroundTasks? {
        try JSONDecoder().decode(StopInput.self, from: Data(json.utf8)).backgroundTasks
    }

    func testInFlightSubagentResolvesToWorking() throws {
        let tasks = try tasks("""
        {"session_id":"b26e035f","hook_event_name":"Stop","stop_hook_active":false,
         "last_assistant_message":"Launched the investigation in the background.",
         "background_tasks":[{"id":"a0000000000000003","type":"subagent","status":"running",
           "description":"Investigate weekly run-out bound","agent_type":"general-purpose"}],
         "session_crons":[]}
        """)

        XCTAssertEqual(tasks, HookBackgroundTasks(total: 1, subagents: 1))
        XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: tasks), .working)
    }

    func testShellTaskResolvesToWorking() throws {
        let tasks = try tasks("""
        {"hook_event_name":"Stop","background_tasks":[
          {"id":"task-001","type":"shell","status":"running","description":"tail logs",
           "command":"tail -f /var/log/syslog"}]}
        """)

        XCTAssertEqual(tasks, HookBackgroundTasks(total: 1, subagents: 0))
        XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: tasks), .working)
    }

    func testEmptyOrAbsentBackgroundTasksResolveToIdle() throws {
        let empty = try tasks(#"{"hook_event_name":"Stop","background_tasks":[]}"#)
        XCTAssertEqual(empty, HookBackgroundTasks(total: 0, subagents: 0))
        XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: empty), .idle)

        // Older Claude Code, or a task registry that is not reachable: no key.
        XCTAssertNil(try tasks(#"{"hook_event_name":"Stop"}"#))
        XCTAssertNil(try tasks(#"{"hook_event_name":"Stop","background_tasks":null}"#))
        XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: nil), .idle)
    }

    func testMalformedEntriesAreSkippedWithoutFailingTheDecode() throws {
        // Non-object entries are dropped; objects count even with a missing or
        // non-string `type`, which only decides the wording.
        let mixed = try tasks("""
        {"background_tasks":[42, "shell", null, ["subagent"], {"type":"subagent"}, {"type":7}, {"status":"running"}]}
        """)
        XCTAssertEqual(mixed, HookBackgroundTasks(total: 3, subagents: 1))
        XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: mixed), .working)

        // A value that is not an array at all is no tasks, and must not throw:
        // a throw would abort the whole stdin decode and the write with it.
        for json in [
            #"{"background_tasks":"nope"}"#,
            #"{"background_tasks":{"id":"x","type":"subagent"}}"#,
            #"{"background_tasks":3}"#,
        ] {
            let tasks = try tasks(json)
            XCTAssertEqual(tasks, HookBackgroundTasks(total: 0, subagents: 0), json)
            XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: tasks), .idle, json)
        }
    }
}
