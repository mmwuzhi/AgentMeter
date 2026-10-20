import AgentStatusCore
@testable import AgentMeter
import Foundation
import XCTest

final class TaskOutcomeAnnouncementTests: XCTestCase {
    private let launchedAt = Date(timeIntervalSince1970: 1_792_480_000)

    private func outcome(
        _ kind: TaskOutcome.Kind, ran duration: TimeInterval = 600, endingAt end: TimeInterval = 0,
        segment: Int = 0, origin: TaskLedgerTask.Origin = .human, crons: Bool = false,
        shells: Int = 0, error: String? = nil, reason: ActiveAgentWaitingReason? = nil
    ) -> TaskOutcome {
        let ended = launchedAt.addingTimeInterval(end)
        return TaskOutcome(
            kind: kind, confidence: .high, sessionID: "ffafe0d9-1111-2222-3333-444455556666", taskKey: "017d120c",
            segment: segment, origin: origin, occurredAt: ended, startedAt: ended.addingTimeInterval(-duration),
            endedAt: ended, cwd: "/Users/u/work/agentmeter", shellsStillRunning: shells, cronsArmed: crons,
            error: error, waitingReason: reason, id: "\(kind.rawValue)|x|\(segment)")
    }

    // MARK: Intent

    func testCompletedIsAnnouncedOnlyForAPersonsTaskOfAMinuteOrMore() {
        typealias Reason = TaskOutcomeAnnouncement.Reason
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed), launchedAt: launchedAt), .notify)
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, ran: 60), launchedAt: launchedAt), .notify)
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, ran: 59.9), launchedAt: launchedAt),
                       .recordOnly(reason: Reason.belowMinimumDuration))
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, origin: .report), launchedAt: launchedAt),
                       .recordOnly(reason: Reason.reportOrigin))
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, crons: true), launchedAt: launchedAt),
                       .recordOnly(reason: Reason.cronsArmed))
        // A follow-up segment is judged on its own length.
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, ran: 20, segment: 1), launchedAt: launchedAt),
                       .recordOnly(reason: Reason.belowMinimumDuration))
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, ran: 90, segment: 1), launchedAt: launchedAt), .notify)
    }

    func testFailedAndWaitingIgnoreTheMinimumInterruptedIsNeverAnnounced() {
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.failed, ran: 3), launchedAt: launchedAt), .notify)
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.waiting, ran: 60), launchedAt: launchedAt), .notify)
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.interrupted), launchedAt: launchedAt),
                       .recordOnly(reason: TaskOutcomeAnnouncement.Reason.notAnnounced))
        // Item 2: an uncertain end is never announced, whatever its length.
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.uncertain, ran: 3600, shells: 1), launchedAt: launchedAt),
                       .recordOnly(reason: TaskOutcomeAnnouncement.Reason.backgroundShellRunning))
    }

    func testOutcomesFromBeforeLaunchAreRecordedOnly() {
        for kind in [TaskOutcome.Kind.completed, .failed, .waiting] {
            XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(kind, endingAt: -121), launchedAt: launchedAt),
                           .recordOnly(reason: TaskOutcomeAnnouncement.Reason.beforeLaunch), "\(kind)")
            XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(kind, endingAt: -119), launchedAt: launchedAt),
                           .notify, "\(kind)")
        }
    }

    // MARK: Event

    func testCompletedEventNamesProjectSessionAndRun() throws {
        let label = TaskSessionLabel(project: "AgentMeter", title: "Phase 1b\nnotifications\u{0007}")
        let event = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.completed, ran: 754, shells: 1),
                                                                 label: label, discoveredAt: launchedAt))
        XCTAssertEqual(event.kind, .taskCompleted)
        XCTAssertEqual(event.id, "completed|x|0")
        XCTAssertEqual(event.content.title, "AgentMeter finished")
        // Item 3: the title (often Claude's summary of the prompt) stays out
        // by default; the short session id names the session.
        XCTAssertEqual(event.content.body, "Session ffafe0d9\n12m run · 1 background shell still running")
        let titled = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.completed, ran: 754, shells: 1),
                                                                  label: label, discoveredAt: launchedAt, showsSessionTitle: true))
        XCTAssertEqual(titled.content.body, "Phase 1b notifications\n12m run · 1 background shell still running",
                       "sanitized single line when shown")
        XCTAssertEqual(event.content.notificationIdentifier, "agentmeter.task.ffafe0d9-1111-2222-3333-444455556666.017d120c")
        XCTAssertEqual(event.content.threadIdentifier, "agentmeter.task./Users/u/work/agentmeter")
        XCTAssertEqual(event.subject, AgentMeterEventSubject(
            provider: "claude", sessionID: "ffafe0d9-1111-2222-3333-444455556666", taskKey: "017d120c",
            projectPath: "/Users/u/work/agentmeter"))
        XCTAssertEqual(event.producerVersion, "task-outcome/1")
        XCTAssertEqual(event.occurredAt, launchedAt)
    }

    func testEventFallsBackToFolderAndShortSessionID() throws {
        let event = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.completed, ran: 3700, segment: 2),
                                                                 label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(event.content.title, "agentmeter finished")
        XCTAssertEqual(event.content.body, "Session ffafe0d9\nFollow-up · 1h 1m run")
    }

    func testFailedWaitingAndInterruptedWording() throws {
        let failed = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.failed, ran: 125, error: "rate_limit"),
                                                                  label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(failed.kind, .taskFailed)
        XCTAssertEqual(failed.content.title, "agentmeter failed")
        XCTAssertEqual(failed.content.body, "Session ffafe0d9\nRate limit · after 2m")
        let unknown = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.failed, error: "brand_new_kind"),
                                                                   label: nil, discoveredAt: launchedAt))
        XCTAssertTrue(unknown.content.body.hasSuffix("API error · after 10m"))

        let waiting = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.waiting, ran: 60, reason: .input),
                                                                   label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(waiting.kind, .taskWaiting)
        XCTAssertEqual(waiting.content.title, "agentmeter needs input")
        XCTAssertEqual(waiting.content.body, "Session ffafe0d9\nWaiting for your answer · 1m")
        XCTAssertEqual(waiting.content.notificationIdentifier,
                       try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.completed), label: nil, discoveredAt: launchedAt))
                        .content.notificationIdentifier,
                       "a wait and the end of the same task replace each other")

        let decision = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.waiting, ran: 60, reason: .dialog),
                                                                    label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(decision.content.body, "Session ffafe0d9\nWaiting for your decision · 1m")

        let uncertain = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.uncertain, ran: 125, shells: 2),
                                                                     label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(uncertain.kind, .taskUnknown)
        XCTAssertEqual(uncertain.content.title, "agentmeter task status unconfirmed")
        XCTAssertEqual(uncertain.content.body, "Session ffafe0d9\n2 background tasks running at the last check · after 2m")
        // The shell may have ended since with no hook to say so: what was
        // seen, when, never that it still runs.
        XCTAssertFalse((uncertain.content.title + uncertain.content.body).contains("still running"))

        let interrupted = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.interrupted, ran: 45),
                                                                       label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(interrupted.kind, .taskInterrupted)
        XCTAssertEqual(interrupted.content.body, "Session ffafe0d9\nStopped after 45s")
        XCTAssertNil(TaskOutcomeAnnouncement.event(for: outcome(.unresolved), label: nil, discoveredAt: launchedAt))
    }

    func testDurationFormat() {
        XCTAssertEqual(TaskOutcomeAnnouncement.format(0), "0s")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(59.4), "59s")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(60), "1m")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(3599), "59m")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(7200), "2h")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(7260), "2h 1m")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(-5), "0s")
    }
}

final class TranscriptTailClassifierTests: XCTestCase {
    private func lines(_ records: [String]) -> Data { Data((records.joined(separator: "\n") + "\n").utf8) }

    /// C3 (REPL Esc during a tool, then Claude Code's bookkeeping records).
    func testMarkerFollowedByBookkeepingIsInterrupted() {
        let tail = lines([
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"The user doesn't want to proceed"}]}}"#,
            #"{"type":"attachment"}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
            #"{"type":"last-prompt"}"#, #"{"type":"ai-title"}"#, #"{"type":"cost-state"}"#,
            #"{"type":"file-history-snapshot"}"#, #"{"type":"cost-state"}"#,
        ])
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: tail, startsMidFile: false), .interrupted)
    }

    func testStringMarkerAndOtherEndings() {
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: lines([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"The keeper"}]}}"#,
            #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
            #"{"type":"cost-state"}"#,
        ]), startsMidFile: false), .interrupted)
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: lines([
            #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Sure."}],"stop_reason":"end_turn"}}"#,
        ]), startsMidFile: false), .other, "a later answer wins")
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: lines([
            #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[]}}"#,
        ]), startsMidFile: false), .interrupted, "meta and sidechain records are not the turn's")
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: lines([
            #"{"type":"user","message":{"content":"Please say [Request interrupted by user]"}}"#,
        ]), startsMidFile: false), .other)
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: Data(), startsMidFile: false), .other)
    }

    /// The 64 KB window starts mid-line: that partial line must not count.
    func testPartialFirstLineIsSkipped() {
        let partial = Data(#"interrupted by user]"}}"#.utf8) + lines([#"{"type":"cost-state"}"#])
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: partial, startsMidFile: true), .other)
    }

    func testReadsOnlyTheTailOfARealFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeter-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        let filler = String(repeating: #"{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}"# + "\n", count: 2_000)
        try Data((filler + #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"# + "\n"
                  + #"{"type":"cost-state"}"# + "\n").utf8).write(to: file)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0,
                             TranscriptTailClassifier.tailBytes)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: file.path), .interrupted)

        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: nil), .unavailable)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: dir.appendingPathComponent("missing.jsonl").path), .unavailable)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: "relative/s.jsonl"), .unavailable)
        let other = dir.appendingPathComponent("s.txt")
        try Data().write(to: other)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: other.path), .unavailable)
        let link = dir.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: link.path), .unavailable)
    }
}
