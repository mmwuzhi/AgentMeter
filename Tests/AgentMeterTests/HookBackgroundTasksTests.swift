import AgentStatusCore
import Foundation
import XCTest

/// The hook helper's `idle` command decides between idle and working from the
/// `Stop` input's `background_tasks`, and its `error` command whether the
/// failure is the session's from `agent_id`; these feed it hook-shaped input.
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

    func testArtifactSubscriptionDoesNotKeepTheSessionWorking() throws {
        // The Tinycast case: the turn's last call published an artifact, Claude
        // Code armed its live-updates subscription, and the Stop 18 s later
        // listed it. It watches for as long as the tab is open, so the Stop
        // that would have returned the row to idle never came.
        let alone = try tasks("""
        {"hook_event_name":"Stop","background_tasks":[
          {"id":"b00000001","type":"monitor","status":"running",
           "description":"live updates for artifact https://claude.ai/artifact/example-fixture (watching)"}],
         "session_crons":[]}
        """)
        XCTAssertEqual(alone, HookBackgroundTasks(total: 0, subagents: 0))
        XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: alone), .idle)

        // Real work beside it still counts, and only the real work does.
        let beside = try tasks("""
        {"hook_event_name":"Stop","background_tasks":[
          {"id":"b00000001","type":"monitor","status":"running",
           "description":"live updates for artifact https://claude.ai/artifact/example-fixture (watching)"},
          {"id":"a0000000000000003","type":"subagent","status":"running",
           "description":"Check sample files","agent_type":"general-purpose"}]}
        """)
        XCTAssertEqual(beside, HookBackgroundTasks(total: 1, subagents: 1))
        XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: beside), .working)
    }

    func testMonitorWaitingOnRealWorkStillKeepsTheSessionWorking() throws {
        // Same task kind as the subscription; only the description tells them apart.
        let tasks = try tasks("""
        {"hook_event_name":"Stop","background_tasks":[
          {"id":"bq3n8","type":"monitor","status":"running","description":"Wait for the release CI run"}]}
        """)
        XCTAssertEqual(tasks, HookBackgroundTasks(total: 1, subagents: 0))
        XCTAssertEqual(AgentStatusState.resolvedStopState(backgroundTasks: tasks), .working)
    }

    func testOnlyTheMainTurnsOwnFailureMarksTheSession() {
        // `StopFailure` inside a subagent carries `agent_id` beside the
        // parent's session id; the main agent gets that failure back as a
        // tool result and carries on.
        XCTAssertEqual(AgentStatusState.recordedState(requested: .error, backgroundTasks: nil, agentID: nil), .error)
        XCTAssertEqual(AgentStatusState.recordedState(requested: .error, backgroundTasks: nil, agentID: ""), .error,
                       "an empty id names no subagent")
        XCTAssertNil(AgentStatusState.recordedState(requested: .error, backgroundTasks: nil, agentID: "a0000000000000004"))

        // Every other command records what it always did, subagent or not:
        // a subagent's tool calls are what keep the parent `working`.
        XCTAssertEqual(AgentStatusState.recordedState(requested: .working, backgroundTasks: nil, agentID: "a0000000000000004"), .working)
        XCTAssertEqual(AgentStatusState.recordedState(requested: .waiting, backgroundTasks: nil, agentID: "a0000000000000004"), .waiting)
        XCTAssertEqual(AgentStatusState.recordedState(requested: .idle, backgroundTasks: HookBackgroundTasks(total: 1, subagents: 1), agentID: nil), .working)
        XCTAssertEqual(AgentStatusState.recordedState(requested: .idle, backgroundTasks: HookBackgroundTasks(total: 0, subagents: 0), agentID: nil), .idle)
        XCTAssertEqual(AgentStatusState.recordedState(requested: .idle, backgroundTasks: nil, agentID: nil), .idle)
    }
}
