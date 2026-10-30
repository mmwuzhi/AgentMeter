import AgentStatusCore
import Foundation
import XCTest

/// Builds a ledger the way the hook helper does: one `TaskLedgerReducer`
/// step per event, times in seconds after a fixed origin.
struct LedgerScript {
    static let origin = Date(timeIntervalSince1970: 1_792_476_000)
    let sessionID: String
    private(set) var ledger: TaskLedger?

    init(sessionID: String = "00000000-0000-4000-8000-000000000003") {
        self.sessionID = sessionID
    }

    static func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    mutating func apply(_ kind: TaskLedgerEvent.Kind, at seconds: TimeInterval, cwd: String? = "/tmp/project",
                        attended: Bool? = nil) {
        let event = TaskLedgerEvent(kind: kind, at: Self.at(seconds), cwd: cwd, transcriptPath: "/tmp/t.jsonl",
                                    attended: attended)
        if let next = TaskLedgerReducer.apply(event, to: ledger, sessionID: sessionID) { ledger = next }
    }

    mutating func human(_ promptID: String, at seconds: TimeInterval) {
        apply(.prompt(promptID: promptID, shape: .human), at: seconds)
    }

    mutating func report(_ promptID: String, at seconds: TimeInterval, tag: TaskLedgerPromptShape = .report) {
        apply(.prompt(promptID: promptID, shape: tag), at: seconds)
    }

    mutating func stop(at seconds: TimeInterval, _ tasks: [(String, String)] = [], crons: Bool = false) {
        apply(.stop(backgroundTasks: tasks.map { HookBackgroundTaskList.Entry(type: $0.0, id: $0.1) },
                    cronsArmed: crons, stopHookActive: false), at: seconds)
    }

    mutating func launch(_ taskID: String, by agentID: String?, at seconds: TimeInterval) {
        apply(.backgroundLaunch(taskID: taskID, agentID: agentID), at: seconds)
    }

    var task: TaskLedgerTask? { ledger?.task }
}

final class TaskLedgerTests: XCTestCase {
    // MARK: Prompt shape

    func testPromptShapes() {
        XCTAssertEqual(TaskLedgerPromptShape.classify("Fix the build"), .human)
        XCTAssertEqual(TaskLedgerPromptShape.classify(nil), .human)
        XCTAssertEqual(TaskLedgerPromptShape.classify("<task-notification>\n<task-id>b00000002</task-id>"), .report)
        XCTAssertEqual(TaskLedgerPromptShape.classify("<agent-message from=\"a0000000000000001\">"), .report)
        XCTAssertEqual(TaskLedgerPromptShape.classify("  \n<task-notification>"), .report)
        XCTAssertEqual(TaskLedgerPromptShape.classify("<div class=x>hello</div>"), .tagged)
        XCTAssertEqual(TaskLedgerPromptShape.classify("<task-notifications>"), .tagged)
        XCTAssertEqual(TaskLedgerPromptShape.classify("<Task-notification>"), .human)
        XCTAssertEqual(TaskLedgerPromptShape.classify("<task-notification"), .human, "no delimiter after the name")
        XCTAssertEqual(TaskLedgerPromptShape.classify("< not a tag"), .human)
        XCTAssertEqual(TaskLedgerPromptShape.classify("a <task-notification> later"), .human)
    }

    // MARK: Hook input mapping

    private func event(
        _ name: String?, agent: String? = nil, promptID: String? = nil, prompt: String? = nil,
        tasks: HookBackgroundTaskList? = nil, crons: Int? = nil, error: String? = nil,
        notification: String? = nil, reason: String? = nil, backgroundTaskID: String? = nil
    ) -> TaskLedgerEvent.Kind? {
        TaskLedgerEvent.from(
            hookEventName: name, agentID: agent, promptID: promptID, prompt: prompt, backgroundTasks: tasks,
            sessionCronCount: crons, stopHookActive: nil, error: error, notificationType: notification,
            reason: reason, backgroundTaskID: backgroundTaskID, cwd: nil, transcriptPath: nil,
            at: LedgerScript.at(0))?.kind
    }

    func testOnlyMainThreadTurnEventsReachTheLedger() {
        XCTAssertEqual(event("UserPromptSubmit", promptID: "prompt-three-0bad"), .prompt(promptID: "prompt-three-0bad", shape: .human))
        XCTAssertEqual(event("Stop", crons: 1), .stop(backgroundTasks: [], cronsArmed: true, stopHookActive: false))
        XCTAssertEqual(event("StopFailure", error: "rate_limit"), .stopFailure(error: "rate_limit"))
        XCTAssertEqual(event("SessionEnd", reason: "prompt_input_exit"), .sessionEnd(reason: "prompt_input_exit"))
        // A subagent's turn events are not the session's.
        XCTAssertNil(event("Stop", agent: "a0000000000000001"))
        XCTAssertNil(event("StopFailure", agent: "a0000000000000001", error: "rate_limit"))
        XCTAssertNil(event("UserPromptSubmit", agent: "a0000000000000001"))
        // An empty agent_id is the main thread.
        XCTAssertNotNil(event("Stop", agent: ""))
        // Tool calls only when they leave a shell behind, from any agent.
        XCTAssertNil(event("PreToolUse"))
        XCTAssertNil(event("PostToolUse"))
        XCTAssertEqual(event("PostToolUse", agent: "a0000000000000002", backgroundTaskID: "b00000004"),
                       .backgroundLaunch(taskID: "b00000004", agentID: "a0000000000000002"))
        // Waiting notices from any agent; other notifications not at all.
        XCTAssertEqual(event("Notification", agent: "x", notification: "permission_prompt"), .waitingNotice)
        XCTAssertEqual(event("Notification", notification: "elicitation_dialog"), .waitingNotice)
        XCTAssertNil(event("Notification", notification: "idle_prompt"))
        XCTAssertNil(event(nil))
        XCTAssertNil(event("SubagentStop"))
    }

    func testOnlyTokensAreKept() {
        // Prompt ids, error kinds and task ids are ids: anything else is dropped.
        XCTAssertEqual(event("UserPromptSubmit", promptID: "has space"), .prompt(promptID: nil, shape: .human))
        XCTAssertEqual(event("StopFailure", error: "Rate limited: try again in 3 minutes"), .stopFailure(error: nil))
        XCTAssertNil(event("PostToolUse", backgroundTaskID: "../../etc"))
        XCTAssertEqual(event("UserPromptSubmit", promptID: String(repeating: "a", count: 129)), .prompt(promptID: nil, shape: .human))
    }

    func testBackgroundTaskListKeepsIdsAndCountsLikeBefore() throws {
        let json = """
        [{"id":"b00000003","type":"shell","status":"running","command":"sleep 50"},
         {"id":"a0000000000000002","type":"subagent","status":"running","agent_type":"general-purpose"},
         {"id":"x","type":"monitor","description":"live updates for artifact https://claude.ai/a (comments)"},
         7, "junk", {"type":5}]
        """
        let list = try JSONDecoder().decode(HookBackgroundTaskList.self, from: Data(json.utf8))
        XCTAssertEqual(list.entries, [
            .init(type: "shell", id: "b00000003"),
            .init(type: "subagent", id: "a0000000000000002"),
            .init(type: nil, id: nil),
        ])
        XCTAssertEqual(HookBackgroundTasks(list), HookBackgroundTasks(total: 3, subagents: 1))
        XCTAssertEqual(try JSONDecoder().decode(HookBackgroundTasks.self, from: Data(json.utf8)),
                       HookBackgroundTasks(total: 3, subagents: 1))
        XCTAssertEqual(try JSONDecoder().decode(HookBackgroundTaskList.self, from: Data("{}".utf8)).entries, [])
    }

    // MARK: Reducer

    func testHumanPromptOpensTaskKeyedByPromptID() {
        var script = LedgerScript()
        script.human("prompt-three", at: 27)
        XCTAssertEqual(script.task?.key, "prompt-three")
        XCTAssertEqual(script.task?.origin, .human)
        XCTAssertEqual(script.task?.startedAt, LedgerScript.at(27))
        XCTAssertTrue(script.task?.isRunning == true)
        XCTAssertEqual(script.ledger?.sequence, 1)
    }

    func testMissingPromptIDFallsBackToSessionAndTime() {
        var script = LedgerScript(sessionID: "s1")
        script.apply(.prompt(promptID: nil, shape: .human), at: 1.5)
        XCTAssertEqual(script.task?.key, "s1|\(Int64((LedgerScript.at(1.5).timeIntervalSince1970 * 1000).rounded()))")
    }

    /// C1: Stop with a running subagent pauses the task; the report joins it
    /// under the first prompt's key although its prompt_id differs.
    func testReportsJoinThePausedTask() {
        var script = LedgerScript()
        script.human("prompt-three", at: 27)
        script.stop(at: 30.8, [("subagent", "a0000000000000001")])
        XCTAssertEqual(script.task?.stop?.blocking, 1)
        XCTAssertTrue(script.task?.stop?.isPaused == true)
        XCTAssertTrue(script.task?.hadBackgroundAgents == true)
        script.report("report-three-a", at: 39.4)
        XCTAssertEqual(script.task?.key, "prompt-three")
        XCTAssertEqual(script.task?.segment, 0)
        XCTAssertEqual(script.task?.reports, 1)
        XCTAssertTrue(script.task?.isRunning == true)
        script.stop(at: 42)
        XCTAssertTrue(script.task?.hasEnded == true)
    }

    /// A pasted `<div>` is a person's prompt unless the task waits on
    /// background work.
    func testTaggedPromptJoinsOnlyWhileAwaitingBackground() {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 5)
        script.report("p2", at: 10, tag: .tagged)
        XCTAssertEqual(script.task?.key, "p2", "after a real end it is a new task")
        XCTAssertEqual(script.task?.origin, .human)

        script.stop(at: 15, [("workflow", "workflow-two")])
        script.report("p3", at: 20, tag: .tagged)
        XCTAssertEqual(script.task?.key, "p2")
        XCTAssertEqual(script.task?.reports, 1)
    }

    /// Review finding 6: after an uncertain end, a `<tag` prompt counts as a
    /// report only within the observation window; past it, it is a person's.
    func testTaggedJoinExpiresWithTheUncertainWindow() {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.launch("b1", by: nil, at: 1)
        script.stop(at: 10, [("shell", "b1")])
        script.report("t1", at: 10 + TaskLedgerReducer.taggedJoinWindow, tag: .tagged)
        XCTAssertEqual(script.task?.key, "p1", "inside the window")
        script.stop(at: 700, [("shell", "b1")])
        script.report("t2", at: 701 + TaskLedgerReducer.taggedJoinWindow, tag: .tagged)
        XCTAssertEqual(script.task?.key, "t2", "past the window: a new task")
        // Claude Code's own report tags always join.
        script.stop(at: 2000, [("shell", "b2")])
        script.report("r", at: 2000 + 5 * TaskLedgerReducer.taggedJoinWindow)
        XCTAssertEqual(script.task?.key, "t2")
    }

    /// Review finding 10: a subagent's notice or launch (possibly from its
    /// own worktree) does not move the session's directory.
    func testLocationComesFromMainThreadEventsOnly() {
        var script = LedgerScript()
        script.apply(.prompt(promptID: "p", shape: .human), at: 0, cwd: "/repo")
        script.apply(.backgroundLaunch(taskID: "b1", agentID: "a1"), at: 1, cwd: "/repo/.claude/worktrees/agent-1")
        script.apply(.waitingNotice, at: 2, cwd: "/repo/.claude/worktrees/agent-1")
        XCTAssertEqual(script.ledger?.cwd, "/repo")
        script.apply(.stop(backgroundTasks: [], cronsArmed: false, stopHookActive: false), at: 3, cwd: "/repo2")
        XCTAssertEqual(script.ledger?.cwd, "/repo2")
    }

    /// A human prompt always opens a new task, even mid-pause.
    func testHumanPromptReplacesPausedTask() {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 5, [("subagent", "a1")])
        script.human("p2", at: 6)
        XCTAssertEqual(script.task?.key, "p2")
        XCTAssertEqual(script.task?.hadBackgroundAgents, false)
    }

    /// A report after the task really ended reopens it as a new segment.
    func testReportAfterEndReopensTask() {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 100)
        script.report("r1", at: 400)
        XCTAssertEqual(script.task?.key, "p1")
        XCTAssertEqual(script.task?.segment, 1)
        XCTAssertEqual(script.task?.segmentStartedAt, LedgerScript.at(400))
        XCTAssertEqual(script.task?.startedAt, LedgerScript.at(0))

        script.apply(.stopFailure(error: "rate_limit"), at: 410)
        XCTAssertTrue(script.task?.hasEnded == true)
        script.report("r2", at: 420)
        XCTAssertEqual(script.task?.segment, 2, "a failure is an end too")
    }

    /// A background agent finished while the main agent
    /// still worked, so the `Stop` listed nothing, and its hand-back followed
    /// soon after it. It stays in the same run because the end was not confirmed yet. Past the window
    /// it is a follow-up as before.
    func testReportQueuedBehindTheEndContinuesTheRun() {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 2472.69)
        XCTAssertTrue(script.task?.hasEnded == true)
        script.report("r1", at: 2472.734)
        XCTAssertEqual(script.task?.key, "p1")
        XCTAssertEqual(script.task?.segment, 0)
        XCTAssertEqual(script.task?.reports, 1)
        XCTAssertTrue(script.task?.isRunning == true)
        script.stop(at: 2474.94)
        XCTAssertEqual(script.task?.segment, 0)
        XCTAssertEqual(script.task?.startedAt, LedgerScript.at(0))

        script.report("r2", at: 2474.94 + TaskLedgerReducer.queuedReportWindow)
        XCTAssertEqual(script.task?.segment, 0, "at the window's edge")
        script.stop(at: 2480)
        script.report("r3", at: 2480 + TaskLedgerReducer.queuedReportWindow + 0.01)
        XCTAssertEqual(script.task?.segment, 1, "past the window: a follow-up")

        // Review finding: joining after a failure would clear it, and the
        // run's later end would be announced as Finished.
        script.apply(.stopFailure(error: "rate_limit"), at: 2500)
        script.report("r4", at: 2500.05)
        XCTAssertEqual(script.task?.segment, 2, "a failure is never continued")
    }

    /// `CLAUDE_CODE_SESSION_ATTENDED`, as the helper reads it: Claude Code's
    /// "1" and "0", nothing else.
    func testAttendedComesOnlyFromClaudeCodesOwnValues() {
        XCTAssertEqual(TaskLedgerEvent.attended(environmentValue: "1"), true)
        XCTAssertEqual(TaskLedgerEvent.attended(environmentValue: "0"), false)
        for other in [nil, "", "true", "false", "yes", "2", "01"] {
            XCTAssertNil(TaskLedgerEvent.attended(environmentValue: other), other ?? "nil")
        }
        // Claude Code's background sessions say "0", but a person started them.
        for kind in ["bg", "daemon", "daemon-worker"] {
            XCTAssertEqual(TaskLedgerEvent.attended(environmentValue: "0", sessionKind: kind), true, kind)
        }
        XCTAssertEqual(TaskLedgerEvent.attended(environmentValue: "0", sessionKind: "interactive"), false)
        XCTAssertEqual(TaskLedgerEvent.attended(environmentValue: "0", sessionKind: "BG"), false, "exact names only")
        XCTAssertEqual(TaskLedgerEvent.attended(environmentValue: "1", sessionKind: "bg"), true)
        XCTAssertNil(TaskLedgerEvent.attended(environmentValue: nil, sessionKind: "bg"), "no value, no say")
    }

    /// The task keeps the first value its main-thread events carry: a new
    /// task starts unknown, so a session resumed by a person (or by a
    /// script) gets the new process's value with its new prompt.
    func testEachTaskKeepsWhetherItsSessionWasAttended() {
        var script = LedgerScript()
        script.apply(.prompt(promptID: "p1", shape: .human), at: 0, attended: false)
        XCTAssertEqual(script.task?.attended, false)
        script.apply(.stop(backgroundTasks: [HookBackgroundTaskList.Entry(type: "subagent", id: "a1")],
                           cronsArmed: false, stopHookActive: false), at: 10, attended: nil)
        script.apply(.prompt(promptID: "r1", shape: .report), at: 20, attended: true)
        XCTAssertEqual(script.task?.key, "p1")
        XCTAssertEqual(script.task?.attended, false, "a report joins the task and keeps its value")
        script.apply(.stop(backgroundTasks: [], cronsArmed: false, stopHookActive: false), at: 30, attended: true)
        XCTAssertEqual(script.task?.attended, false)

        script.apply(.prompt(promptID: "p2", shape: .human), at: 40, attended: true)
        XCTAssertEqual(script.task?.key, "p2")
        XCTAssertEqual(script.task?.attended, true, "a new task, the new process's value")

        // A subagent's notice or launch never sets it.
        script.apply(.prompt(promptID: "p3", shape: .human), at: 50)
        XCTAssertNil(script.task?.attended)
        script.apply(.waitingNotice, at: 51, attended: false)
        script.apply(.backgroundLaunch(taskID: "b1", agentID: "a2"), at: 52, attended: false)
        XCTAssertNil(script.task?.attended)
        // A task an older helper opened takes the first value a later event has.
        script.apply(.stop(backgroundTasks: [], cronsArmed: false, stopHookActive: false), at: 60, attended: false)
        XCTAssertEqual(script.task?.attended, false)
    }

    /// Ledgers the installed helper wrote before carry no value, and an older
    /// app reading a new ledger ignores the key: same format version.
    func testLedgersWithoutTheFlagStillReadAndTheFlagRoundTrips() throws {
        let old = #"{"version":1,"sessionID":"s","sequence":2,"updatedAt":1792476010,"backgroundLaunches":[],"task":{"key":"p","origin":"human","startedAt":1792476000,"segment":0,"segmentStartedAt":1792476000,"lastPromptAt":1792476000,"reports":0,"hadBackgroundAgents":false,"stop":{"at":1792476010,"blocking":0,"settledShells":0,"uncertainShells":0,"otherTasks":0,"cronsArmed":false,"stopHookActive":false}}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let read = try decoder.decode(TaskLedger.self, from: Data(old.utf8))
        XCTAssertNil(read.task?.attended)
        XCTAssertNotNil(read.task?.stop)
        var marked = read
        marked.task?.attended = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        XCTAssertEqual(try decoder.decode(TaskLedger.self, from: encoder.encode(marked)).task?.attended, false)
        XCTAssertEqual(TaskLedger.formatVersion, 1)
    }

    /// A report with no task to join opens one that no person asked for.
    func testReportWithoutTaskOpensReportOriginTask() {
        var script = LedgerScript()
        script.report("r1", at: 0)
        XCTAssertEqual(script.task?.key, "r1")
        XCTAssertEqual(script.task?.origin, .report)
    }

    /// C1a / C1d: whose a shell is decides whether it can still bring the
    /// task back. This task's shells (main's or a subagent's) can; an earlier
    /// task's cannot; one never seen launching can only after background
    /// agents ran.
    func testShellsAreClassifiedByTheTaskThatStartedThem() {
        var script = LedgerScript()
        script.human("old", at: 0)
        script.launch("bdevserver", by: nil, at: 1)
        script.stop(at: 2, [("shell", "bdevserver")])
        XCTAssertEqual(script.task?.stop?.uncertainShells, 1, "started by this task")

        script.human("new", at: 10)
        script.launch("b00000003", by: nil, at: 12)
        script.stop(at: 14, [("shell", "b00000003"), ("subagent", "a0000000000000002")])
        script.launch("b00000004", by: "a0000000000000002", at: 15)
        script.report("r1", at: 16)
        script.stop(at: 17, [("shell", "bdevserver"), ("shell", "b00000003"), ("shell", "b00000004"),
                             ("shell", "bunknown"), ("monitor", "m1"), ("teammate", "t1")])
        let stop = script.task?.stop
        XCTAssertEqual(stop?.blocking, 0)
        XCTAssertEqual(stop?.settledShells, 1, "the earlier task's dev server")
        XCTAssertEqual(stop?.uncertainShells, 4, "main's and the subagent's shells, plus two unknown after an agent")
        XCTAssertEqual(stop?.otherTasks, 1)
        XCTAssertTrue(stop?.isUncertain == true)
        XCTAssertFalse(script.task?.hasEnded == true)

        // No launch on record and no agents ran: still assumed this task's
        // (conservative), and remembered as seen here, so the next task finds
        // it settled.
        var fresh = LedgerScript()
        fresh.human("p", at: 0)
        fresh.stop(at: 1, [("shell", "bunknown")])
        XCTAssertEqual(fresh.task?.stop?.uncertainShells, 1)
        XCTAssertEqual(fresh.ledger?.backgroundLaunches.last, TaskLedgerBackgroundLaunch(
            taskID: "bunknown", agentID: nil, taskKey: "p", at: LedgerScript.at(1), observedOnly: true))
        fresh.stop(at: 2, [("shell", "bunknown")])
        XCTAssertEqual(fresh.task?.stop?.uncertainShells, 1, "same task: still uncertain")
        fresh.human("next", at: 10)
        fresh.stop(at: 20, [("shell", "bunknown")])
        XCTAssertEqual(fresh.task?.stop?.settledShells, 1, "a later task: settled")
        XCTAssertEqual(fresh.task?.stop?.uncertainShells, 0)
        // An id that is not a token is counted, not stored.
        fresh.stop(at: 21, [("shell", "../x y")])
        XCTAssertEqual(fresh.task?.stop?.uncertainShells, 1)
        XCTAssertFalse(fresh.ledger?.backgroundLaunches.contains { $0.taskID.contains("/") } ?? true)
    }

    /// Reports during an uncertain end join the same segment: the end was
    /// never final.
    func testReportDuringUncertainEndKeepsSegment() {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.launch("b1", by: nil, at: 1)
        script.stop(at: 2, [("shell", "b1")])
        script.report("r", at: 50)
        XCTAssertEqual(script.task?.segment, 0)
        XCTAssertTrue(script.task?.isRunning == true)
    }

    func testStopWithoutTaskWritesNothing() {
        XCTAssertNil(TaskLedgerReducer.apply(
            TaskLedgerEvent(kind: .stop(backgroundTasks: [], cronsArmed: false, stopHookActive: false), at: Date()),
            to: nil, sessionID: "s"))
        XCTAssertNil(TaskLedgerReducer.apply(TaskLedgerEvent(kind: .sessionEnd(reason: nil), at: Date()), to: nil, sessionID: "s"))
        XCTAssertNil(TaskLedgerReducer.apply(TaskLedgerEvent(kind: .waitingNotice, at: Date()), to: nil, sessionID: "s"))
    }

    func testLaunchListIsBoundedAndDeduplicated() {
        var script = LedgerScript()
        for index in 0..<(TaskLedgerReducer.maximumBackgroundLaunches + 10) {
            script.launch("b\(index)", by: nil, at: Double(index))
        }
        script.launch("b70", by: "agent", at: 100)
        XCTAssertEqual(script.ledger?.backgroundLaunches.count, TaskLedgerReducer.maximumBackgroundLaunches)
        XCTAssertEqual(script.ledger?.backgroundLaunches.last, TaskLedgerBackgroundLaunch(
            taskID: "b70", agentID: "agent", taskKey: nil, at: LedgerScript.at(100)))
        XCTAssertEqual(script.ledger?.backgroundLaunches.filter { $0.taskID == "b70" }.count, 1)
        XCTAssertEqual(script.ledger?.backgroundLaunches.first?.taskID, "b10", "re-launching b70 replaced it in place of dropping another")
    }

    func testWaitingNoticeClearedByNextPrompt() {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.apply(.waitingNotice, at: 5)
        XCTAssertEqual(script.task?.waitingNoticeAt, LedgerScript.at(5))
        script.stop(at: 6, [("subagent", "a")])
        script.report("r", at: 7)
        XCTAssertNil(script.task?.waitingNoticeAt)
    }

    // MARK: Store

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeter-turns-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStoreRoundTripsWithMillisecondsAndTightPermissions() throws {
        let directory = try temporaryDirectory()
        let at = Date(timeIntervalSince1970: 1_792_476_617.153)
        try TaskLedgerStore.apply(TaskLedgerEvent(kind: .prompt(promptID: "p1", shape: .human), at: at, cwd: "/w"),
                                  sessionID: "s/../1", in: directory)
        let read = try XCTUnwrap(TaskLedgerStore.read(sessionID: "s/../1", in: directory))
        XCTAssertEqual(read.sessionID, "s/../1")
        XCTAssertEqual(read.task?.startedAt.timeIntervalSince1970 ?? 0, 1_792_476_617.153, accuracy: 0.0005)
        XCTAssertEqual(read.cwd, "/w")
        let file = TaskLedgerStore.fileURL(forSession: "s/../1", in: directory)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertEqual(TaskLedgerStore.readAll(in: directory).map(\.ledger.sessionID), ["s/../1"])

        // A Stop with no change to make writes nothing; the next event builds on the file.
        try TaskLedgerStore.apply(TaskLedgerEvent(kind: .stop(backgroundTasks: [], cronsArmed: false, stopHookActive: false),
                                                  at: at.addingTimeInterval(5)), sessionID: "s/../1", in: directory)
        XCTAssertEqual(TaskLedgerStore.read(sessionID: "s/../1", in: directory)?.sequence, 2)
        XCTAssertTrue(TaskLedgerStore.remove(sessionID: "s/../1", in: directory))
        XCTAssertNil(TaskLedgerStore.read(sessionID: "s/../1", in: directory))
    }

    func testStoreIgnoresUnreadableAndNewerFiles() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("bad.json"))
        try Data(#"{"version":99,"sessionID":"n","sequence":1,"updatedAt":0,"backgroundLaunches":[]}"#.utf8)
            .write(to: directory.appendingPathComponent("n.json"))
        try TaskLedgerStore.apply(TaskLedgerEvent(kind: .prompt(promptID: "p", shape: .human), at: Date()),
                                  sessionID: "ok", in: directory)
        XCTAssertEqual(TaskLedgerStore.readAll(in: directory).map(\.ledger.sessionID), ["ok"])
        // A newer-format file is not built on either: the next write starts fresh.
        try TaskLedgerStore.apply(TaskLedgerEvent(kind: .prompt(promptID: "p", shape: .human), at: Date()),
                                  sessionID: "n", in: directory)
        XCTAssertEqual(TaskLedgerStore.read(sessionID: "n", in: directory)?.sequence, 1)
    }

    /// A ledger lock held by another writer delays this one, and past the
    /// timeout the write is dropped, never blocking the hook.
    func testLockTimeoutDropsTheWrite() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        // flock locks belong to the open file description, so a second open
        // in this process contends like another process would.
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let started = Date()
        XCTAssertThrowsError(try TaskLedgerStore.apply(
            TaskLedgerEvent(kind: .prompt(promptID: "p", shape: .human), at: Date()),
            sessionID: "s", in: directory, lockTimeout: 0.1)) { error in
            XCTAssertEqual(error as? TaskLedgerStore.StoreError, .lockUnavailable)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(TaskLedgerStore.read(sessionID: "s", in: directory))
        flock(fd, LOCK_UN)
        XCTAssertNotNil(try TaskLedgerStore.apply(
            TaskLedgerEvent(kind: .prompt(promptID: "p", shape: .human), at: Date()), sessionID: "s", in: directory))
    }

    /// Concurrent writers (a subagent's launch beside the main Stop) never
    /// lose each other's update.
    func testConcurrentWritersAllLand() throws {
        let directory = try temporaryDirectory()
        try TaskLedgerStore.apply(TaskLedgerEvent(kind: .prompt(promptID: "p", shape: .human), at: Date()),
                                  sessionID: "s", in: directory)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            _ = try? TaskLedgerStore.apply(
                TaskLedgerEvent(kind: .backgroundLaunch(taskID: "b\(index)", agentID: nil), at: Date()),
                sessionID: "s", in: directory, lockTimeout: 5)
        }
        let ledger = try XCTUnwrap(TaskLedgerStore.read(sessionID: "s", in: directory))
        XCTAssertEqual(ledger.backgroundLaunches.count, 40)
        XCTAssertEqual(ledger.sequence, 41)
    }
}
