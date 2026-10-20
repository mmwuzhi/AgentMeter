import AgentStatusCore
@testable import AgentMeter
import Foundation
import XCTest

/// Scenario tests for `TaskOutcomeDetector`, replaying the hook and registry
/// timelines measured in POC C1–C3 and C1d (Claude Code 2.1.301) plus the
/// cases those runs did not reach. Times are seconds after `LedgerScript.origin`.
final class TaskOutcomeDetectorTests: XCTestCase {
    private typealias Reading = TaskOutcomeRegistryReading

    private func reading(_ status: ClaudeSessionRegistryEntry.Status, at seconds: TimeInterval, waitingFor: String? = nil) -> Reading {
        Reading(status: status, waitingFor: waitingFor, statusUpdatedAt: LedgerScript.at(seconds))
    }

    private func evaluate(
        _ script: LedgerScript, at seconds: TimeInterval, registry: Reading?, payload: AgentStatusPayload? = nil,
        transcript: TaskTranscriptVerdict = .unavailable, timing: TaskOutcomeDetector.Timing = .standard
    ) -> TaskOutcomeEvaluation {
        let now = LedgerScript.at(seconds)
        let evaluation = TaskOutcomeDetector.evaluate(
            script.ledger!, registry: registry, payload: payload, now: now,
            timing: timing, transcript: { transcript })
        // A next check at or before now would make the monitor spin at its
        // minimum interval: every rule must name a time still ahead.
        if let next = evaluation.nextCheck {
            XCTAssertGreaterThan(next, now, "next check not ahead at \(seconds)")
        }
        return evaluation
    }

    private func kinds(_ evaluation: TaskOutcomeEvaluation) -> [TaskOutcome.Kind] {
        evaluation.outcomes.map(\.kind)
    }

    // MARK: Completed

    /// Plain turn: Stop with nothing in flight, registry idle 30 ms later,
    /// finished `confirmDelay` after that.
    func testCompletesOnceRegistryHasStayedIdle() throws {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 90)
        let idle = reading(.idle, at: 90.03)
        XCTAssertEqual(kinds(evaluate(script, at: 90.5, registry: reading(.busy, at: 0))), [], "registry not caught up")
        let early = evaluate(script, at: 91, registry: idle)
        XCTAssertEqual(kinds(early), [])
        XCTAssertEqual(early.nextCheck?.timeIntervalSince1970 ?? 0, LedgerScript.at(92.03).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(kinds(evaluate(script, at: 92.02, registry: idle)), [])
        let done = evaluate(script, at: 92.04, registry: idle)
        let outcome = try XCTUnwrap(done.outcomes.first)
        XCTAssertEqual(outcome.kind, .completed)
        XCTAssertEqual(outcome.confidence, .high)
        XCTAssertEqual(outcome.occurredAt, LedgerScript.at(90))
        XCTAssertEqual(outcome.duration, 90, accuracy: 0.001)
        XCTAssertEqual(outcome.id, "task_completed|\(script.sessionID)|p1|0")
        XCTAssertEqual(outcome.shellsStillRunning, 0)
        XCTAssertEqual(evaluate(script, at: 3600, registry: idle).outcomes.map(\.id), [outcome.id], "same answer later: stable id")
    }

    /// The REPL reports idle-with-a-shell as `shell`; a dev server from an
    /// earlier task does not hold the task, and the banner says it runs.
    func testEarlierTasksShellDoesNotHoldCompletion() throws {
        var script = LedgerScript()
        script.human("old", at: 0)
        script.launch("bdev", by: nil, at: 1)
        script.stop(at: 2, [("shell", "bdev")])
        script.human("p2", at: 700)
        script.stop(at: 800, [("shell", "bdev")])
        let outcome = try XCTUnwrap(evaluate(script, at: 803, registry: reading(.shell, at: 800.04)).outcomes.first)
        XCTAssertEqual(outcome.kind, .completed)
        XCTAssertEqual(outcome.confidence, .high)
        XCTAssertEqual(outcome.shellsStillRunning, 1)
    }

    /// A Stop hook that blocks continues the turn: the registry stays busy
    /// past the first Stop, and only the final Stop completes (C10 has not
    /// been measured; this is the conservative reading of it).
    func testBusyRegistryAfterStopHoldsUntilNextStop() {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 100)
        XCTAssertEqual(kinds(evaluate(script, at: 130, registry: reading(.busy, at: 100.1))), [])
        script.apply(.stop(backgroundTasks: [], cronsArmed: false, stopHookActive: true), at: 140)
        XCTAssertEqual(kinds(evaluate(script, at: 143, registry: reading(.idle, at: 140.05))), [.completed])
    }

    /// Without a registry entry a quiet window stands in, and any tool call
    /// after the Stop (payload rewritten to working) restarts it.
    func testWithoutRegistryQuietWindowAndActivity() throws {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 100)
        XCTAssertEqual(kinds(evaluate(script, at: 104, registry: nil)), [])
        let stopPayload = AgentStatusPayload(state: .idle, sessionID: script.sessionID, updatedAt: LedgerScript.at(100))
        XCTAssertEqual(evaluate(script, at: 105, registry: nil, payload: stopPayload).outcomes.first?.confidence, .medium)
        let busyPayload = AgentStatusPayload(state: .working, sessionID: script.sessionID, updatedAt: LedgerScript.at(103))
        let held = evaluate(script, at: 105, registry: nil, payload: busyPayload)
        XCTAssertEqual(kinds(held), [])
        XCTAssertEqual(held.nextCheck, LedgerScript.at(108))
        // Review finding 3: once that later window has passed, it completes
        // instead of asking to be checked again in the past.
        XCTAssertEqual(evaluate(script, at: 108, registry: nil, payload: busyPayload).outcomes.first?.confidence, .medium)
    }

    /// An idle registry that has not moved since before the Stop is not
    /// trusted forever: a quiet window stands in after the grace.
    func testStaleIdleRegistryFallsBackAfterGrace() {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 100)
        let stale = reading(.idle, at: -5)
        XCTAssertEqual(kinds(evaluate(script, at: 109, registry: stale)), [])
        XCTAssertEqual(evaluate(script, at: 110, registry: stale).outcomes.first?.confidence, .medium)
        // Tool activity after the Stop restarts the window, which then closes
        // (it must not stay open, or the monitor would spin).
        let working = AgentStatusPayload(state: .working, sessionID: script.sessionID, updatedAt: LedgerScript.at(105))
        XCTAssertEqual(kinds(evaluate(script, at: 114, registry: stale, payload: working)), [])
        XCTAssertEqual(kinds(evaluate(script, at: 115, registry: stale, payload: working)), [.completed])
    }

    /// Review finding 1: Claude Code keeps the busy stamp of the turn's start
    /// while it stays busy (C2), so a Stop hook that continues the turn shows
    /// busy stamped before the Stop. That holds the task, however long.
    func testBusyStampedBeforeStopHoldsIndefinitely() {
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 100)
        let busyFromStart = reading(.busy, at: 0.05)
        for second in [100.2, 105, 110, 130, 600, 3600] {
            XCTAssertEqual(kinds(evaluate(script, at: second, registry: busyFromStart)), [], "at \(second)")
        }
        XCTAssertEqual(evaluate(script, at: 100.2, registry: busyFromStart).nextCheck?.timeIntervalSince1970 ?? 0,
                       LedgerScript.at(100.7).timeIntervalSince1970, accuracy: 0.001, "catching up: fast poll")
        XCTAssertEqual(evaluate(script, at: 600, registry: busyFromStart).nextCheck, LedgerScript.at(602), "then the running poll")
        script.apply(.stop(backgroundTasks: [], cronsArmed: false, stopHookActive: true), at: 700)
        XCTAssertEqual(kinds(evaluate(script, at: 703, registry: reading(.idle, at: 700.05))), [.completed])
    }

    // MARK: Background agents (C1, C2)

    /// C1 (REPL, `c1b`): UPS → Stop[subagent] → <agent-message → Stop[] →
    /// one completion, timed from the human prompt.
    func testBackgroundSubagentCompletesOnceAfterReport() throws {
        var script = LedgerScript()
        script.human("prompt-one", at: 10)
        script.stop(at: 15, [("subagent", "agent-one")])
        for second in stride(from: 16.0, through: 19.0, by: 1) {
            XCTAssertEqual(kinds(evaluate(script, at: second, registry: reading(.busy, at: 10.01))), [], "paused at \(second)")
        }
        XCTAssertNil(evaluate(script, at: 17, registry: reading(.busy, at: 10.01)).nextCheck, "paused: only a file change matters")
        script.report("report-one", at: 20)
        script.stop(at: 22)
        let outcome = try XCTUnwrap(evaluate(script, at: 25, registry: reading(.idle, at: 22.01)).outcomes.first)
        XCTAssertEqual(outcome.taskKey, "prompt-one")
        XCTAssertEqual(outcome.segment, 0)
        XCTAssertEqual(outcome.duration, 22 - 10, accuracy: 0.001)
    }

    /// C2 (SDK, `c2s`): a Workflow pauses the task the same way.
    func testWorkflowPausesUntilItsReport() {
        var script = LedgerScript()
        script.human("prompt-two", at: 0.1)
        script.stop(at: 5, [("workflow", "workflow-two")])
        // Registry busy throughout the pause, then idle 10 ms after the last Stop.
        XCTAssertEqual(kinds(evaluate(script, at: 30, registry: reading(.busy, at: 0.08))), [])
        script.report("report-two", at: 31)
        script.stop(at: 35)
        XCTAssertEqual(kinds(evaluate(script, at: 38, registry: reading(.idle, at: 35.01))), [.completed])
    }

    // MARK: C1a — the early-completion counterexample

    /// C1a (REPL, `c1a`): the subagent backgrounds `sleep 40`, hands back,
    /// and the main Stops with only that shell left. The old rule ("shells do
    /// not block") announced Completed here, ~35 s before the subagent was
    /// revived and reported. Now nothing is announced until the real end,
    /// and the one completion is the task's, at the final Stop.
    func testC1aSubagentShellDoesNotCompleteEarly() throws {
        var script = LedgerScript()
        script.human("prompt-three", at: 10)
        script.stop(at: 15, [("subagent", "a0000000000000001")])
        script.launch("b00000002", by: "a0000000000000001", at: 19)
        script.report("report-three-a", at: 22)
        script.stop(at: 24, [("shell", "b00000002")])
        XCTAssertTrue(script.task?.stop?.isUncertain == true)

        // Registry: still busy (24.03), then the REPL's `shell` while the
        // shell runs (27.07), idle when it ends (62.10), busy as the subagent
        // is revived (62.17).
        var timeline: [(TimeInterval, Reading)] = [
            (24.5, reading(.busy, at: 23.95)),
            (25.5, reading(.busy, at: 23.95)),
        ]
        for (second, registry) in timeline {
            XCTAssertEqual(kinds(evaluate(script, at: second, registry: registry)), [], "at \(second)")
        }
        script.report("report-three-b", at: 24.05)
        script.stop(at: 27, [("shell", "b00000002")])
        timeline = stride(from: 27.1, to: 62.10, by: 0.5).map { ($0, reading(.shell, at: 26.95)) }
        timeline += [(62.12, reading(.idle, at: 62.03)), (62.6, reading(.busy, at: 62.06)), (63.5, reading(.busy, at: 62.06))]
        for (second, registry) in timeline {
            XCTAssertEqual(kinds(evaluate(script, at: second, registry: registry)), [], "no completion at \(second)")
        }
        script.report("report-three-c", at: 64)
        XCTAssertEqual(kinds(evaluate(script, at: 64.5, registry: reading(.busy, at: 62.06))), [])
        script.stop(at: 65)
        XCTAssertEqual(kinds(evaluate(script, at: 66.9, registry: reading(.idle, at: 64.95))), [], "confirm delay")
        let outcome = try XCTUnwrap(evaluate(script, at: 67.1, registry: reading(.idle, at: 64.95)).outcomes.first)
        XCTAssertEqual(outcome.kind, .completed)
        XCTAssertEqual(outcome.confidence, .high)
        XCTAssertEqual(outcome.segment, 0, "never ended in between: no reopen")
        XCTAssertEqual(outcome.id, "task_completed|\(script.sessionID)|prompt-three|0")
        XCTAssertEqual(outcome.duration, 65 - 10, accuracy: 0.001)
    }

    /// C1d (SDK path, the one VS Code uses): main and subagent each leave a
    /// shell; the registry is plain `idle` while they run, and stays idle
    /// while the revived subagent works. Still one completion, at the end.
    func testC1dSdkPathShellsOfBothOwners() throws {
        var script = LedgerScript()
        script.human("prompt-four", at: 0.1)
        script.launch("b00000003", by: nil, at: 2)
        script.stop(at: 4, [("shell", "b00000003"), ("subagent", "a0000000000000002")])
        script.launch("b00000004", by: "a0000000000000002", at: 4.5)
        script.report("report-four-a", at: 5.2)
        script.stop(at: 6, [("shell", "b00000003"), ("shell", "b00000004")])
        for second in stride(from: 6.5, to: 35, by: 1) {
            XCTAssertEqual(kinds(evaluate(script, at: second, registry: reading(.idle, at: 6.01))), [], "at \(second)")
        }
        script.report("report-four-b", at: 35)
        script.stop(at: 38, [("shell", "b00000003")])
        XCTAssertTrue(script.task?.stop?.isUncertain == true, "the main agent's own shell, started by this task")
        for second in stride(from: 38.5, to: 58, by: 1) {
            XCTAssertEqual(kinds(evaluate(script, at: second, registry: reading(.idle, at: 38.01))), [], "at \(second)")
        }
        script.report("report-four-c", at: 58)
        script.stop(at: 60)
        let outcome = try XCTUnwrap(evaluate(script, at: 62.1, registry: reading(.idle, at: 60.03)).outcomes.first)
        XCTAssertEqual(outcome.segment, 0)
        XCTAssertEqual(outcome.duration, 60 - 0.1, accuracy: 0.001)
    }

    /// Item 2 (2026-10-20): a shell this task started that never wakes it (a
    /// server, or a subagent never revived) is never called Completed. After
    /// `uncertainWindow` the uncertain state is recorded once, as unknown.
    func testUncertainEndIsBounded() throws {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.stop(at: 10, [("subagent", "a1")])
        script.launch("bserver", by: "a1", at: 20)
        script.report("r", at: 30)
        script.stop(at: 100, [("shell", "bserver")])
        let window = TaskOutcomeDetector.Timing.standard.uncertainWindow
        let idle = reading(.idle, at: 100.05)
        let before = evaluate(script, at: 100 + window - 1, registry: idle)
        XCTAssertEqual(kinds(before), [])
        XCTAssertNotNil(before.nextCheck)
        let outcome = try XCTUnwrap(evaluate(script, at: 100 + window, registry: idle).outcomes.first)
        XCTAssertEqual(outcome.kind, .uncertain)
        XCTAssertEqual(outcome.kind.eventKind, .taskUnknown)
        XCTAssertEqual(outcome.confidence, .medium)
        XCTAssertEqual(outcome.shellsStillRunning, 1)
        XCTAssertEqual(outcome.occurredAt, LedgerScript.at(100 + window), "recorded at the window's end")
        XCTAssertEqual(outcome.duration, 100, accuracy: 0.001, "the main agent stopped at the Stop")
        XCTAssertEqual(outcome.id, "task_unknown|\(script.sessionID)|p|0|w\(HistoryTime.ms(LedgerScript.at(100)))")
        XCTAssertNil(evaluate(script, at: 100 + window + 3600, registry: idle).outcomes.first { $0.kind == .completed },
                     "never Completed while the shell is the task's")
        XCTAssertLessThan(window, NotificationManager.defaultMaximumDeliveryDelay, "inside the freshness gate")

        // A tool call during the window (a revived subagent at work) extends it.
        let working = AgentStatusPayload(state: .working, sessionID: script.sessionID, updatedAt: LedgerScript.at(300))
        XCTAssertEqual(kinds(evaluate(script, at: 100 + window, registry: idle, payload: working)), [])
        // A busy registry (the report reaching the main agent) holds it.
        XCTAssertEqual(kinds(evaluate(script, at: 100 + window, registry: reading(.busy, at: 650))), [])
    }

    /// Review finding 2: a report after the window ran out joins the same
    /// segment; the task's real end is still announced, under its own id.
    func testReportAfterUncertainWindowStillAnnouncesRealEnd() throws {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.launch("b1", by: nil, at: 5)
        script.stop(at: 100, [("shell", "b1")])
        let window = TaskOutcomeDetector.Timing.standard.uncertainWindow
        let expired = try XCTUnwrap(evaluate(script, at: 100 + window, registry: reading(.idle, at: 100.03)).outcomes.first)
        XCTAssertEqual(expired.kind, .uncertain)
        script.report("late", at: 100 + window + 60)
        XCTAssertEqual(script.task?.segment, 0)
        script.stop(at: 100 + window + 1200)
        let end = try XCTUnwrap(evaluate(script, at: 100 + window + 1203, registry: reading(.idle, at: 100 + window + 1200.03)).outcomes.first)
        XCTAssertEqual(end.kind, .completed)
        XCTAssertNotEqual(end.id, expired.id)
        XCTAssertEqual(end.id, "task_completed|\(script.sessionID)|p|0")
        XCTAssertEqual(end.duration, 100 + window + 1200, accuracy: 0.001)
    }

    /// The session ending stops the watch on an uncertain task at once,
    /// without calling it finished (nothing says the work was done).
    func testSessionEndClosesUncertainEndWithoutOutcome() throws {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.launch("b1", by: "agent", at: 5)
        script.stop(at: 100, [("shell", "b1")])
        script.apply(.sessionEnd(reason: "clear"), at: 120)
        let outcome = try XCTUnwrap(evaluate(script, at: 120.5, registry: nil).outcomes.first)
        XCTAssertEqual(outcome.kind, .unresolved)
        XCTAssertNil(outcome.kind.eventKind, "nothing recorded")
        XCTAssertTrue(outcome.id.hasSuffix("|e\(HistoryTime.ms(LedgerScript.at(100)))"))
    }

    /// Item 2: a shell the ledger never saw launching (started before the
    /// ledger existed) holds the task that first sees it, conservatively.
    func testUnattributedShellIsUncertain() {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.stop(at: 100, [("shell", "bnever")])
        let idle = reading(.idle, at: 100.03)
        XCTAssertEqual(kinds(evaluate(script, at: 103, registry: idle)), [])
        XCTAssertEqual(kinds(evaluate(script, at: 3600, registry: idle)), [.uncertain])
        // The next task is not held by it.
        script.human("q", at: 4000)
        script.stop(at: 4100, [("shell", "bnever")])
        XCTAssertEqual(kinds(evaluate(script, at: 4103, registry: reading(.idle, at: 4100.03))), [.completed])
    }

    /// Known limit (2026-10-20): the task's own shell ends and nothing wakes
    /// the main agent (no report, no Stop). No hook fires when a background
    /// shell ends (C1a, C1d: only the owner's wake-up did), the SDK registry
    /// stays `idle` throughout (C1d), and the REPL's `shell` → `idle` edge
    /// came 60 ms before a revival in C1a, so it says the shells ended, not
    /// that the task did. The task stays uncertain: one unknown after the
    /// window, never Completed, and no polling once that is settled.
    func testOwnShellEndingWithoutWakeStaysUnknown() {
        let window = TaskOutcomeDetector.Timing.standard.uncertainWindow
        for (label, whileRunning, afterEnd) in [
            ("REPL", reading(.shell, at: 100.04), reading(.idle, at: 400)),
            ("SDK", reading(.idle, at: 100.04), reading(.idle, at: 100.04)),
        ] {
            var script = LedgerScript()
            script.human("p", at: 0)
            script.launch("bmine", by: nil, at: 5)
            script.stop(at: 100, [("shell", "bmine")])
            XCTAssertEqual(kinds(evaluate(script, at: 200, registry: whileRunning)), [], label)
            // The shell ends at 400; no report, no Stop follows.
            for second in [401.0, 402, 500, 100 + window - 1] {
                XCTAssertEqual(kinds(evaluate(script, at: second, registry: afterEnd)), [], "\(label) at \(second)")
            }
            for second in [100 + window, 3600, 86_400] {
                let evaluation = evaluate(script, at: second, registry: afterEnd)
                XCTAssertEqual(kinds(evaluation), [.uncertain], "\(label) at \(second)")
                XCTAssertNil(evaluation.nextCheck, "\(label): settled, nothing to poll for")
            }
        }
    }

    // MARK: Reopen

    /// The main agent's own shell from this task finishing after the window
    /// (or anything after a real end) reopens the task as a new segment with
    /// its own outcome id.
    func testReportAfterCompletionReopensWithNewID() throws {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.stop(at: 100)
        let first = try XCTUnwrap(evaluate(script, at: 103, registry: reading(.idle, at: 100.03)).outcomes.first)
        script.report("r", at: 400)
        XCTAssertEqual(kinds(evaluate(script, at: 401, registry: reading(.busy, at: 400.01))), [])
        script.stop(at: 520)
        let second = try XCTUnwrap(evaluate(script, at: 523, registry: reading(.idle, at: 520.03)).outcomes.first)
        XCTAssertEqual(second.segment, 1)
        XCTAssertTrue(second.isReopened)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.duration, 120, accuracy: 0.001, "the follow-up's own length")
    }

    // MARK: Failed

    func testFailureConfirmedByRegistry() throws {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.apply(.stopFailure(error: "rate_limit"), at: 30)
        XCTAssertEqual(kinds(evaluate(script, at: 31, registry: reading(.idle, at: 30.05))), [])
        let outcome = try XCTUnwrap(evaluate(script, at: 32.1, registry: reading(.idle, at: 30.05)).outcomes.first)
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertEqual(outcome.confidence, .high)
        XCTAssertEqual(outcome.error, "rate_limit")
        XCTAssertEqual(outcome.id, "task_failed|\(script.sessionID)|p|0")
    }

    /// StopFailure has not been seen in a real session: a registry that
    /// stays busy after it (background agents) delays the call, and without a
    /// registry it waits a quiet window.
    func testFailureIsConservativeWhenUnconfirmed() {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.apply(.stopFailure(error: nil), at: 30)
        XCTAssertEqual(kinds(evaluate(script, at: 59, registry: reading(.busy, at: 30.2))), [])
        XCTAssertEqual(evaluate(script, at: 60, registry: reading(.busy, at: 30.2)).outcomes.first?.confidence, .medium)
        // Busy with the turn's own stamp (not re-stamped): the same 30 s cap.
        XCTAssertEqual(kinds(evaluate(script, at: 59, registry: reading(.busy, at: 0.05))), [])
        XCTAssertEqual(kinds(evaluate(script, at: 60, registry: reading(.busy, at: 0.05))), [.failed])
        XCTAssertEqual(kinds(evaluate(script, at: 39, registry: nil)), [])
        XCTAssertEqual(kinds(evaluate(script, at: 40, registry: nil)), [.failed])
        // A report or prompt after the failure moves the ledger: nothing to call.
        script.report("r", at: 45)
        XCTAssertEqual(kinds(evaluate(script, at: 100, registry: reading(.busy, at: 45))), [])
    }

    // MARK: Interrupted (C3)

    /// Esc: no Stop, registry busy → idle; the transcript's last message is
    /// the marker (followed by bookkeeping records, which the classifier
    /// skips).
    func testEscIsInterruptedWithMarker() throws {
        var script = LedgerScript()
        script.human("0f6257a7", at: 0.08)
        XCTAssertEqual(kinds(evaluate(script, at: 5, registry: reading(.busy, at: 0.05))), [])
        let idle = reading(.idle, at: 7.40)
        XCTAssertEqual(kinds(evaluate(script, at: 8, registry: idle, transcript: .interrupted)), [], "grace")
        let outcome = try XCTUnwrap(evaluate(script, at: 9.5, registry: idle, transcript: .interrupted).outcomes.first)
        XCTAssertEqual(outcome.kind, .interrupted)
        XCTAssertEqual(outcome.occurredAt, LedgerScript.at(7.40))
        XCTAssertTrue(outcome.id.hasPrefix("task_interrupted|\(script.sessionID)|0f6257a7|0|"))
    }

    /// Idle without a Stop and without the marker is left unresolved: not an
    /// interruption, and not a completion either.
    func testIdleWithoutStopOrMarkerIsUnresolved() {
        var script = LedgerScript()
        script.human("p", at: 0)
        XCTAssertEqual(kinds(evaluate(script, at: 10, registry: reading(.idle, at: 5), transcript: .other)), [.unresolved])
        XCTAssertEqual(kinds(evaluate(script, at: 10, registry: reading(.idle, at: 5), transcript: .unavailable)), [.unresolved])
        // Registry idle from before the prompt: not this turn's. It is polled
        // for a while, then left alone instead of polled until the next prompt.
        let unmoved = evaluate(script, at: 5, registry: reading(.idle, at: -5), transcript: .interrupted)
        XCTAssertEqual(kinds(unmoved), [])
        XCTAssertEqual(unmoved.nextCheck, LedgerScript.at(10))
        XCTAssertEqual(kinds(evaluate(script, at: 10, registry: reading(.idle, at: -5), transcript: .interrupted)), [.unresolved])
        // No registry: no Esc signal at all.
        XCTAssertEqual(kinds(evaluate(script, at: 10, registry: nil, transcript: .interrupted)), [])
    }

    /// The transcript is read only for a turn that looks interrupted.
    func testTranscriptReadOnlyWhenNeeded() {
        var script = LedgerScript()
        script.human("p", at: 0)
        var reads = 0
        _ = TaskOutcomeDetector.evaluate(script.ledger!, registry: reading(.busy, at: 0.1), payload: nil,
                                         now: LedgerScript.at(30), transcript: { reads += 1; return .other })
        script.stop(at: 40)
        _ = TaskOutcomeDetector.evaluate(script.ledger!, registry: reading(.idle, at: 40.1), payload: nil,
                                         now: LedgerScript.at(50), transcript: { reads += 1; return .other })
        XCTAssertEqual(reads, 0)
    }

    // MARK: Waiting

    func testWaitingAfterSixtySeconds() throws {
        var script = LedgerScript()
        script.human("p", at: 0)
        let waiting = reading(.waiting, at: 10, waitingFor: "permission prompt")
        let early = evaluate(script, at: 69.9, registry: waiting)
        XCTAssertEqual(kinds(early), [])
        XCTAssertEqual(early.nextCheck, LedgerScript.at(70))
        let outcome = try XCTUnwrap(evaluate(script, at: 70, registry: waiting).outcomes.first)
        XCTAssertEqual(outcome.kind, .waiting)
        XCTAssertEqual(outcome.waitingReason, .permission)
        XCTAssertEqual(outcome.occurredAt, LedgerScript.at(70))
        XCTAssertEqual(outcome.id, "task_waiting|\(script.sessionID)|p|0|\(HistoryTime.ms(LedgerScript.at(0)))")
        // Answered within the minute: nothing.
        XCTAssertEqual(kinds(evaluate(script, at: 70, registry: reading(.busy, at: 50))), [])
        // Review finding 8: one per turn. A re-stamped or second wait in the
        // same turn is the same occurrence (deduplicated downstream)...
        let again = evaluate(script, at: 200, registry: reading(.waiting, at: 130, waitingFor: "input needed"))
        XCTAssertEqual(again.outcomes.first?.waitingReason, .input)
        XCTAssertEqual(again.outcomes.first?.id, outcome.id)
        // ...a wait in the next turn is not.
        script.stop(at: 210, [("subagent", "a")])
        script.report("r", at: 300)
        let next = evaluate(script, at: 400, registry: reading(.waiting, at: 310))
        XCTAssertEqual(next.outcomes.first?.id, "task_waiting|\(script.sessionID)|p|0|\(HistoryTime.ms(LedgerScript.at(300)))")
    }

    func testWaitingSkipsDialogsAndEndedTasks() {
        var script = LedgerScript()
        script.human("p", at: 0)
        // Item 1: mid-turn, `dialog open` is Claude Code's own decision dialog
        // ("Session paused": fallback model, usage credits) and counts.
        let decision = evaluate(script, at: 500, registry: reading(.waiting, at: 10, waitingFor: "dialog open"))
        XCTAssertEqual(kinds(decision), [.waiting])
        XCTAssertEqual(decision.outcomes.first?.waitingReason, .dialog)
        // Permission and question waits never read `dialog open`.
        XCTAssertEqual(evaluate(script, at: 500, registry: reading(.waiting, at: 10, waitingFor: "permission prompt")).outcomes.first?.waitingReason, .permission)
        XCTAssertEqual(evaluate(script, at: 500, registry: reading(.waiting, at: 10, waitingFor: "input needed")).outcomes.first?.waitingReason, .input)
        // Unknown wording still counts as waiting on the user.
        XCTAssertEqual(kinds(evaluate(script, at: 500, registry: reading(.waiting, at: 10, waitingFor: "something new"))), [.waiting])
        // A background agent's permission prompt while paused still counts.
        script.stop(at: 20, [("subagent", "a")])
        XCTAssertEqual(kinds(evaluate(script, at: 500, registry: reading(.waiting, at: 30))), [.waiting])
        // Between turns `dialog open` is a command UI the user opened: skipped.
        XCTAssertEqual(kinds(evaluate(script, at: 500, registry: reading(.waiting, at: 30, waitingFor: "dialog open"))), [])
        script.report("r", at: 40)
        script.stop(at: 50)
        XCTAssertEqual(kinds(evaluate(script, at: 500, registry: reading(.waiting, at: 60))), [], "task over")
    }

    /// Without a registry: the permission notice, still the payload's last
    /// word, after 120 s.
    func testWaitingWithoutRegistryNeedsTwoMinutes() {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.apply(.waitingNotice, at: 16)
        let payload = AgentStatusPayload(state: .waiting, sessionID: script.sessionID, updatedAt: LedgerScript.at(16))
        XCTAssertEqual(kinds(evaluate(script, at: 135, registry: nil, payload: payload)), [])
        let outcome = evaluate(script, at: 136, registry: nil, payload: payload).outcomes.first
        XCTAssertEqual(outcome?.kind, .waiting)
        XCTAssertEqual(outcome?.confidence, .medium)
        let answered = AgentStatusPayload(state: .working, sessionID: script.sessionID, updatedAt: LedgerScript.at(40))
        XCTAssertEqual(kinds(evaluate(script, at: 200, registry: nil, payload: answered)), [])
    }

    // MARK: Polling

    func testRunningTurnPollsRegistry() {
        var script = LedgerScript()
        script.human("p", at: 0)
        XCTAssertEqual(evaluate(script, at: 10, registry: reading(.busy, at: 0.05)).nextCheck, LedgerScript.at(12))
        XCTAssertNil(evaluate(script, at: 10, registry: nil).nextCheck)
    }
}
