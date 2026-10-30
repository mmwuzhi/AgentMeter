import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

/// The session rows' latest-turn marks: which event is a session's latest
/// turn, when a newer prompt or event supersedes it, how the row's state
/// wins over it, and when it goes by itself.
final class SessionTurnResultTests: XCTestCase {
    /// Every row fixture is observed then.
    private let observedAt = Date(timeIntervalSince1970: 1_793_275_200)
    private let utc = TimeZone(identifier: "UTC")!
    private let american = Locale(identifier: "en_US")

    private func event(_ id: String, _ kind: AgentMeterEventKind = .taskCompleted, session: String? = "s1",
                       ago: TimeInterval, body: String = "Session s1\n12m run") -> AgentMeterEvent {
        let at = observedAt.addingTimeInterval(-ago)
        return AgentMeterEvent(
            id: id, kind: kind, occurredAt: at, discoveredAt: at.addingTimeInterval(2),
            subject: AgentMeterEventSubject(provider: "claude", sessionID: session, taskKey: id, projectPath: "/tmp/p"),
            content: AgentMeterEventContent(title: "Finished · p", body: body),
            producerVersion: "task-outcome/1")
    }

    private func agent(pid: Int = 501, parent: Int = 1, status: AgentStatusState? = .idle, stateAge: TimeInterval? = 300,
                       session: String? = "s1", project: String = "AgentMeter",
                       provider: Provider = .claude) -> ActiveAgent {
        ActiveAgent(
            provider: provider, pid: pid, parentPID: parent, command: "claude", elapsedSeconds: 600,
            observedAt: observedAt, cwd: "/Users/me/\(project)",
            session: session.map {
                ActiveAgentSession(id: $0, projectPath: "/Users/me/\(project)", projectName: project, branch: nil,
                                   lastUpdatedAt: observedAt.addingTimeInterval(-300), source: "test")
            },
            status: status,
            statusUpdatedAt: stateAge.map { observedAt.addingTimeInterval(-$0) },
            statusSource: status == nil ? nil : .registry)
    }

    private func finished(ago: TimeInterval, detail: String? = "12m run") -> SessionTurnResult {
        SessionTurnResult(outcome: .finished, endedAt: observedAt.addingTimeInterval(-ago), detail: detail)
    }

    // MARK: - Which event is the latest turn's

    func testTheNewestFinishedOrFailedEventIsTheSessionsResult() {
        let results = SessionTurnResults.newestBySession([
            event("old", ago: 900),
            event("new", .taskFailed, ago: 120, body: "Session s1\nRate limit · after 3m"),
            event("b", session: "s2", ago: 60),
        ])
        XCTAssertEqual(results["s1"], SessionTurnResult(outcome: .failed, endedAt: observedAt.addingTimeInterval(-120),
                                                        detail: "Rate limit · after 3m"))
        XCTAssertEqual(results["s2"]?.outcome, .finished, "each session on its own")
        XCTAssertEqual(results.count, 2)
    }

    func testOccurrenceDecidesNotTheOrderTheLogReturnsThemIn() {
        let a = event("a", .taskFailed, ago: 900)
        let b = event("b", ago: 60)
        XCTAssertEqual(SessionTurnResults.newestBySession([a, b]), SessionTurnResults.newestBySession([b, a]))
        XCTAssertEqual(SessionTurnResults.newestBySession([a, b])["s1"]?.outcome, .finished)
    }

    func testANewerWaitInterruptionOrUnconfirmedEndLeavesNothingToShow() {
        for kind in [AgentMeterEventKind.taskWaiting, .taskInterrupted, .taskUnknown] {
            let results = SessionTurnResults.newestBySession([event("done", ago: 900), event("later", kind, ago: 60)])
            XCTAssertNil(results["s1"], "\(kind) after an end belongs to a later turn")
        }
        // A wait is never a result of its own, however recent.
        XCTAssertTrue(SessionTurnResults.newestBySession([event("w", .taskWaiting, ago: 10)]).isEmpty)
    }

    func testAWaitStampedJustAfterItsOwnTasksEndDoesNotHideIt() {
        // The wait's time is its start plus the delay; a carried-over
        // registry reading can put it a few ms after the task's `Stop`.
        var done = event("task_completed|s1|p1|0", ago: 60)
        done.subject.taskKey = "p1"
        var wait = event("task_waiting|s1|p1|0|1", .taskWaiting, ago: 59.99)
        wait.subject.taskKey = "p1"
        XCTAssertEqual(SessionTurnResults.newestBySession([done, wait])["s1"]?.outcome, .finished)
        // Another task's wait is the later turn's and still hides it.
        var other = event("task_waiting|s1|p2|0|1", .taskWaiting, ago: 30)
        other.subject.taskKey = "p2"
        XCTAssertNil(SessionTurnResults.newestBySession([done, wait, other])["s1"])
    }

    func testAnEventWithoutASessionOrOfAnotherKindIsIgnored() {
        let rule = AgentMeterEvent(
            id: "r", kind: AgentMeterEventKind("rule_burn"), occurredAt: observedAt, discoveredAt: observedAt,
            subject: AgentMeterEventSubject(sessionID: "s1"), content: AgentMeterEventContent(title: "t", body: "b"),
            producerVersion: "x")
        let results = SessionTurnResults.newestBySession([event("done", ago: 900), rule, event("n", session: nil, ago: 5),
                                                          event("e", session: "", ago: 5)])
        XCTAssertEqual(results.keys.sorted(), ["s1"])
        XCTAssertEqual(results["s1"]?.endedAt, observedAt.addingTimeInterval(-900))
    }

    func testTheDetailIsTheBodysSecondLineSanitized() {
        XCTAssertEqual(SessionTurnResults.detail("Session s1\n12m run"), "12m run")
        XCTAssertEqual(SessionTurnResults.detail("p · Claude Code · s1\nFollow-up · 3m run · 1 background shell still running"),
                       "Follow-up · 3m run · 1 background shell still running")
        XCTAssertNil(SessionTurnResults.detail("one line only"))
        XCTAssertNil(SessionTurnResults.detail("Session s1\n"))
        XCTAssertEqual(SessionTurnResults.detail("Session s1\n12m\u{202E} run"), SessionLabel.title("12m\u{202E} run"))
    }

    // MARK: - A newer prompt supersedes it

    func testAPromptAfterTheTurnEndedHidesItsResult() {
        let results = ["s1": finished(ago: 600), "s2": finished(ago: 600), "s3": finished(ago: 600)]
        let current = SessionTurnResults.current(results, turnStarts: [
            "s1": observedAt.addingTimeInterval(-60),  // the next turn began
            "s2": observedAt.addingTimeInterval(-1_200),  // the turn's own prompt
        ])
        XCTAssertNil(current["s1"], "Finished, then the next prompt: no longer the latest turn")
        XCTAssertEqual(current["s2"], results["s2"])
        XCTAssertEqual(current["s3"], results["s3"], "a ledger swept away takes nothing with it")
    }

    func testSameMillisecondCountsAsTheSameTurn() {
        let end = observedAt.addingTimeInterval(-600)
        let result = SessionTurnResult(outcome: .finished, endedAt: HistoryTime.date(ms: HistoryTime.ms(end)), detail: nil)
        // The ledger keeps fractions of a millisecond; the event whole ones.
        let start = end.addingTimeInterval(0.0004)
        XCTAssertEqual(SessionTurnResults.current(["s1": result], turnStarts: ["s1": start]).count, 1)
        XCTAssertTrue(SessionTurnResults.current(["s1": result], turnStarts: ["s1": end.addingTimeInterval(0.002)]).isEmpty)
    }

    // MARK: - The row's state wins

    func testWorkingAndWaitingRowsShowNoResult() {
        let results = ["s1": finished(ago: 120)]
        XCTAssertNil(agent(status: .working).turnMarker(in: results), "the next turn runs: Working is what is true")
        XCTAssertNil(agent(status: .waiting).turnMarker(in: results))
        XCTAssertEqual(agent(status: .idle).turnMarker(in: results), .finished(at: observedAt.addingTimeInterval(-120)))
        XCTAssertEqual(agent(status: nil, stateAge: nil).turnMarker(in: results), .finished(at: observedAt.addingTimeInterval(-120)),
                       "a row with only a transcript date")
    }

    func testAHookFailureIsTheFailedTurnWithItsOwnTime() {
        let row = agent(status: .error, stateAge: 180)
        XCTAssertEqual(row.turnMarker(in: [:]), .failed(at: observedAt.addingTimeInterval(-180)))
        XCTAssertEqual(row.turnMarker(in: ["s1": finished(ago: 4_000)]), .failed(at: observedAt.addingTimeInterval(-180)))
        XCTAssertEqual(row.activityText(marker: row.turnMarker(in: [:])), "last turn failed · 3m ago")
        XCTAssertEqual(row.activityText, "last turn failed · 3m ago", "the plain text says the same, never \"needs attention\"")
        let undated = agent(status: .error, stateAge: nil)
        XCTAssertEqual(undated.turnMarker(in: [:]), .failed(at: nil))
        XCTAssertEqual(undated.activityText(marker: .failed(at: nil)), "last turn failed")
    }

    func testAFailureOnlyTheEventSawMarksAnIdleRow() {
        // The registry's later idle stamp outranked the hook's error.
        let failed = SessionTurnResult(outcome: .failed, endedAt: observedAt.addingTimeInterval(-240), detail: "API error · after 1m")
        let row = agent(status: .idle)
        XCTAssertEqual(row.turnMarker(in: ["s1": failed]), .failed(at: observedAt.addingTimeInterval(-240)))
        XCTAssertEqual(row.activityText(marker: row.turnMarker(in: ["s1": failed])), "last turn failed · 4m ago")
    }

    func testAMarkGoesByItselfAfterTheWindow() {
        let row = agent(status: .idle)
        XCTAssertEqual(ActiveAgent.turnResultWindow, 3_600)
        XCTAssertNotNil(row.turnMarker(in: ["s1": finished(ago: 3_600)]), "an hour on the dot still shows")
        XCTAssertNil(row.turnMarker(in: ["s1": finished(ago: 3_601)]), "nothing to dismiss: it goes")
        XCTAssertEqual(row.activityText(marker: row.turnMarker(in: ["s1": finished(ago: 3_601)])), row.activityText,
                       "back to the plain idle row")
        // A turn that ended after the row's last full refresh (the row ages
        // only then, every refresh interval, which can be minutes) shows at
        // once, as "0s ago".
        let early = row.turnMarker(in: ["s1": finished(ago: -20)])
        XCTAssertEqual(row.activityText(marker: early), "last turn finished · 0s ago")
        XCTAssertNotNil(row.turnMarker(in: ["s1": finished(ago: -300)]), "a five-minute refresh interval")
    }

    func testAFailureGoesByItselfAfterTheSameHour() throws {
        let recent = agent(status: .error, stateAge: 3_600)
        XCTAssertEqual(recent.displayStatus, .error)
        XCTAssertEqual(recent.turnMarker(in: [:]), .failed(at: observedAt.addingTimeInterval(-3_600)))

        let row = agent(status: .error, stateAge: 3_601)
        XCTAssertTrue(row.hasStaleError)
        XCTAssertEqual(row.displayStatus, .idle, "not red, not first in the order")
        XCTAssertNil(row.turnMarker(in: [:]), "no cross past the hour")
        XCTAssertEqual(row.activityText(marker: row.turnMarker(in: [:])), "idle · 5m ago", "plain idle with its age")
        // The event saw the same failure: it goes at the same time.
        let failed = SessionTurnResult(outcome: .failed, endedAt: observedAt.addingTimeInterval(-3_601), detail: nil)
        XCTAssertNil(row.turnMarker(in: ["s1": failed]))
        // Its group no longer opens or counts it.
        let group = try XCTUnwrap(ActiveAgentGrouping.group([row, agent(pid: 2, session: "s2")]).first)
        XCTAssertFalse(group.needsAttention)
        XCTAssertNil(group.turnMarker(in: ["s1": failed]))
        XCTAssertEqual(group.collapsedSummary(turnResults: ["s1": failed]), "2")
        // A wait is the state now, whatever its age.
        XCTAssertEqual(agent(status: .waiting, stateAge: 5 * 3_600).displayStatus, .waiting)
    }

    func testOnlyTheRowsOwnSessionCounts() {
        // A child process (a `claude -p` run from the session's Bash) is a
        // session of its own: its end is not the parent's.
        let parent = agent(pid: 501, session: "parent")
        let child = agent(pid: 777, parent: 501, session: "child")
        let results = ["child": finished(ago: 30)]
        XCTAssertNil(parent.turnMarker(in: results))
        XCTAssertNotNil(child.turnMarker(in: results))
        // A Codex row, or a row without a session: nothing.
        XCTAssertNil(agent(session: nil).turnMarker(in: ["s1": finished(ago: 30)]))
    }

    func testTheRowSaysFinishedForTheTurnNotTheSession() {
        let row = agent(status: .idle)
        let marker = row.turnMarker(in: ["s1": finished(ago: 180)])
        XCTAssertEqual(row.activityText(marker: marker), "last turn finished · 3m ago")
        XCTAssertEqual(row.activityText(marker: nil), "idle · 5m ago")
    }

    // MARK: - Groups

    func testACollapsedGroupCountsFinishedAndFailedTurnsWhileNothingRuns() throws {
        let rows = [agent(pid: 1, session: "a"), agent(pid: 2, session: "b"), agent(pid: 3, session: "c")]
        let group = try XCTUnwrap(ActiveAgentGrouping.group(rows).first)
        let results = ["a": finished(ago: 60),
                       "b": SessionTurnResult(outcome: .failed, endedAt: observedAt.addingTimeInterval(-90), detail: nil)]
        XCTAssertEqual(group.collapsedSummary(turnResults: results), "3 · 1 failed · 1 finished")
        XCTAssertEqual(group.turnMarker(in: results), .failed(at: observedAt.addingTimeInterval(-90)),
                       "a failure before a finish in the header")
        XCTAssertEqual(group.collapsedSummary(turnResults: ["a": finished(ago: 60)]), "3 · 1 finished")
        XCTAssertEqual(group.collapsedSummary(turnResults: [:]), "3")
        XCTAssertEqual(group.collapsedSummary, "3")
        XCTAssertFalse(group.needsAttention, "a finished turn opens nothing by itself")
    }

    func testAGroupThatRunsOrWaitsKeepsItsDotAndCount() throws {
        let rows = [agent(pid: 1, status: .working, session: "a"), agent(pid: 2, session: "b")]
        let group = try XCTUnwrap(ActiveAgentGrouping.group(rows).first)
        let results = ["b": finished(ago: 60)]
        XCTAssertNil(group.turnMarker(in: results))
        XCTAssertEqual(group.collapsedSummary(turnResults: results), "2 · 1 working")
        let failing = try XCTUnwrap(ActiveAgentGrouping.group([agent(pid: 1, status: .error, stateAge: 60, session: "a"),
                                                               agent(pid: 2, session: "b")]).first)
        XCTAssertEqual(failing.collapsedSummary(turnResults: results), "2 · 1 failed")
        XCTAssertEqual(failing.turnMarker(in: results), .failed(at: observedAt.addingTimeInterval(-60)))
        XCTAssertTrue(failing.needsAttention, "a failure still opens its group, as before")
    }

    func testTheMarksChangeNoOrderAndNoCount() {
        let rows = [agent(pid: 1, session: "a", project: "x"), agent(pid: 2, session: "b", project: "y"),
                    agent(pid: 3, status: .working, session: "c", project: "z")]
        let before = ActiveAgentGrouping.group(rows)
        // The order and counts read only the rows; a result is not a row input.
        XCTAssertEqual(ActiveAgentGrouping.group(rows), before)
        XCTAssertEqual(ActiveAgentGrouping.sessionCount(before), 3)
    }

    // MARK: - Tooltip

    func testTheTooltipNamesTheTurnTheMomentAndWhatTheEventSaid() {
        let row = agent(status: .idle)
        let marker = SessionTurnMarker.finished(at: observedAt.addingTimeInterval(-180))
        let line = ActiveAgentTooltip.turnLine(marker, detail: "12m run", observedAt: observedAt, locale: american, timeZone: utc)
        XCTAssertEqual(line.replacingOccurrences(of: "\u{202F}", with: " "), "Last turn finished at 11:57 AM · 12m run")
        let text = ActiveAgentTooltip.text(for: row, marker: marker, detail: "12m run", locale: american, timeZone: utc)
        XCTAssertTrue(text.contains("Last turn finished at"), text)
        XCTAssertFalse(ActiveAgentTooltip.text(for: row, locale: american, timeZone: utc).contains("Last turn"))
        XCTAssertEqual(ActiveAgentTooltip.turnLine(.failed(at: nil), detail: nil, observedAt: observedAt,
                                                   locale: american, timeZone: utc), "Last turn failed")
    }

    func testTheTooltipTakesTheEventsDetailOnlyForTheSameTurn() {
        let result = finished(ago: 180)
        XCTAssertEqual(ActiveAgentTooltip.detail(of: result, for: .finished(at: result.endedAt)), "12m run")
        XCTAssertNil(ActiveAgentTooltip.detail(of: result, for: .finished(at: result.endedAt.addingTimeInterval(-1))))
        XCTAssertNil(ActiveAgentTooltip.detail(of: result, for: .failed(at: result.endedAt)))
        XCTAssertNil(ActiveAgentTooltip.detail(of: result, for: nil))
        let failure = SessionTurnResult(outcome: .failed, endedAt: observedAt, detail: "Rate limit · after 3m")
        XCTAssertEqual(ActiveAgentTooltip.detail(of: failure, for: .failed(at: observedAt.addingTimeInterval(-3))),
                       "Rate limit · after 3m", "the hook's time may differ from the event's")
    }

    // MARK: - Turn starts from the ledgers

    func testTheLatestPromptIsTheTurnStartWhateverTheSessionEndSays() {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        var resumed = TaskLedger(sessionID: "s1", updatedAt: base)
        resumed.task = TaskLedgerTask(key: "p2", origin: .human, startedAt: base.addingTimeInterval(100))
        resumed.task?.lastPromptAt = base.addingTimeInterval(200)
        // A `SessionEnd` from before the resume stays in the ledger.
        resumed.endedAt = base.addingTimeInterval(50)
        let empty = TaskLedger(sessionID: "s2", updatedAt: base)
        XCTAssertEqual(TaskOutcomeMonitor.turnStarts([resumed, empty]), ["s1": base.addingTimeInterval(200)])
    }

    func testTheMonitorHandsOnTurnStartsAtItsFirstPassAndWhenTheyChange() {
        final class Box<Value>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Value
            init(_ value: Value) { self.value = value }
            func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
            func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
            func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
        }
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        let ledgers = Box<[TaskLedger]>([])
        let published = Box<[[String: Date]]>([])
        let environment = TaskOutcomeMonitor.Environment(
            ledgerDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString)"),
            readLedgers: { ledgers.get() }, readRegistry: { [:] }, readPayloads: { [:] },
            transcriptVerdict: { _ in .unavailable }, sweepLedgers: { _, _ in }, now: { base.addingTimeInterval(1_000) })
        let monitor = TaskOutcomeMonitor(environment: environment, turnStarts: { starts in published.mutate { $0.append(starts) } },
                                         deliver: { _ in })
        monitor.evaluateNow()
        XCTAssertEqual(published.get(), [[:]], "an empty answer is an answer: nothing hides a result yet")
        monitor.evaluateNow()
        XCTAssertEqual(published.get().count, 1, "unchanged: not handed on again")
        var ledger = TaskLedger(sessionID: "s1", updatedAt: base)
        ledger.task = TaskLedgerTask(key: "p1", origin: .human, startedAt: base)
        ledgers.set([ledger])
        monitor.evaluateNow()
        XCTAssertEqual(published.get().last, ["s1": base])
        ledger.task?.lastPromptAt = base.addingTimeInterval(30)
        ledgers.set([ledger])
        monitor.evaluateNow()
        XCTAssertEqual(published.get().last, ["s1": base.addingTimeInterval(30)])
        XCTAssertEqual(published.get().count, 3)
    }
}
