import AgentStatusCore
@testable import AgentMeter
import Foundation
import UserNotifications
import XCTest

/// Detector → tracker → announcement → `NotificationManager.submit` → the
/// center stub, the way `AppDelegate` wires them, on scripted timelines.
/// Counts banners, not outcomes: what the user would see.
@MainActor
final class TaskOutcomeDeliveryTests: XCTestCase {
    private typealias Reading = TaskOutcomeRegistryReading

    private final class Harness {
        let center: AuthorizationCenterStub
        let manager: NotificationManager
        let store: AgentMeterEventStore
        var tracker = TaskOutcomeTracker()
        let launchedAt: Date
        let clock: EventTestClock

        @MainActor
        init(store: AgentMeterEventStore, clock: EventTestClock, launchedAt: Date,
             preferences: AgentMeterNotificationPreferences = AgentMeterNotificationPreferences()) {
            self.center = AuthorizationCenterStub(result: .success(true), status: .authorized)
            self.store = store
            self.clock = clock
            self.launchedAt = launchedAt
            self.manager = NotificationManager(
                authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" }, eventStore: store,
                preferences: { preferences }, now: { clock.now })
        }

        /// One monitor pass at `seconds` (moving the clock there).
        @MainActor
        @discardableResult
        func pass(_ script: LedgerScript, at seconds: TimeInterval, registry: Reading?,
                  transcript: TaskTranscriptVerdict = .unavailable) async -> [AgentMeterEventSubmission] {
            let now = LedgerScript.at(seconds)
            clock.advance(now.timeIntervalSince(clock.now))
            let result = tracker.evaluate(
                ledgers: [script.ledger!], registry: registry.map { [script.sessionID: $0] } ?? [:],
                payloads: [:], now: now, transcript: { _ in transcript })
            var submissions: [AgentMeterEventSubmission] = []
            for outcome in result.outcomes {
                guard let event = TaskOutcomeAnnouncement.event(
                    for: outcome, label: TaskSessionLabel(project: "AgentMeter", title: "Phase 1b"), discoveredAt: now,
                    showsSessionTitle: false)
                else { continue }
                submissions.append(await manager.submit(
                    event, intent: TaskOutcomeAnnouncement.intent(for: outcome, launchedAt: launchedAt)))
            }
            return submissions
        }
    }

    private func reading(_ status: ClaudeSessionRegistryEntry.Status, at seconds: TimeInterval, waitingFor: String? = nil) -> Reading {
        Reading(status: status, waitingFor: waitingFor, statusUpdatedAt: LedgerScript.at(seconds))
    }

    private func delivery(_ submission: AgentMeterEventSubmission?) -> AgentMeterEventDelivery? {
        if case let .recorded(event)? = submission { return event.delivery }
        return nil
    }

    private func harness(store: AgentMeterEventStore? = nil, launchedAt seconds: TimeInterval = 0,
                         preferences: AgentMeterNotificationPreferences = AgentMeterNotificationPreferences()) -> Harness {
        let clock = EventTestClock(LedgerScript.at(seconds))
        return Harness(store: store ?? .inMemory(clock: clock.function), clock: clock,
                       launchedAt: LedgerScript.at(seconds), preferences: preferences)
    }

    /// What names the session in the notification rides on the outcome:
    /// the ledger's transcript, and how the registry last said the process
    /// was started, kept after a headless run's entry is gone.
    func testOutcomesCarryTheTranscriptAndTheLaunchTheRegistryLastSaid() throws {
        var tracker = TaskOutcomeTracker()
        var script = LedgerScript()
        script.human("p1", at: 1)
        script.stop(at: 120)
        let headless = Reading(status: .idle, statusUpdatedAt: LedgerScript.at(120.05), launch: .headless)
        let first = tracker.evaluate(ledgers: [script.ledger!], registry: [script.sessionID: headless], payloads: [:],
                                     now: LedgerScript.at(120.5), transcript: { _ in .unavailable })
        XCTAssertTrue(first.outcomes.isEmpty, "not confirmed yet")
        // The process exits right after its last Stop: the entry is gone.
        let later = tracker.evaluate(ledgers: [script.ledger!], registry: [:], payloads: [:],
                                     now: LedgerScript.at(130), transcript: { _ in .unavailable })
        let outcome = try XCTUnwrap(later.outcomes.first)
        XCTAssertEqual(outcome.kind, .completed)
        XCTAssertEqual(outcome.sessionID, script.sessionID, "the main session's id, from the hooks")
        XCTAssertEqual(outcome.launch, .headless)
        XCTAssertEqual(outcome.transcriptPath, "/tmp/t.jsonl")
    }

    /// The C1a shape stretched to a task worth announcing: polled every
    /// second the way the monitor does, it yields exactly one banner, at the
    /// real end, never at the shell-only Stop.
    func testC1aShapeYieldsOneBannerAtTheRealEnd() async {
        let h = harness()
        var script = LedgerScript()
        script.human("prompt-three", at: 1)
        script.stop(at: 30, [("subagent", "a0000000000000001")])
        script.launch("b00000002", by: "a0000000000000001", at: 40)
        script.report("report-three-a", at: 50)
        script.stop(at: 52, [("shell", "b00000002")])
        for second in stride(from: 52.5, through: 240, by: 1) {
            let submissions = await h.pass(script, at: second, registry: reading(.idle, at: 52.05))
            XCTAssertEqual(submissions.count, 0, "nothing while the subagent's shell runs (\(second))")
        }
        script.report("report-three-c", at: 241)
        await h.pass(script, at: 241.5, registry: reading(.busy, at: 240.9))
        script.stop(at: 243)
        await h.pass(script, at: 244, registry: reading(.idle, at: 243.04))
        let final = await h.pass(script, at: 245.1, registry: reading(.idle, at: 243.04))
        XCTAssertEqual(delivery(final.first)?.state, .posted)
        for second in stride(from: 246.0, through: 400, by: 5) {
            await h.pass(script, at: second, registry: reading(.idle, at: 243.04))
        }
        XCTAssertEqual(h.center.posted.count, 1)
        XCTAssertEqual(h.center.posted.first?.identifier, "agentmeter.task.\(script.sessionID).prompt-three")
        XCTAssertEqual(h.center.posted.first?.content.body, "Session 00000000\n4m run")
        let events = await h.store.events()
        XCTAssertEqual(events.map(\.id), ["task_completed|\(script.sessionID)|prompt-three|0"])
    }

    /// Known limit, end to end: the task's own shell ends without waking the
    /// main agent. Two hours of passes record one unknown and post nothing;
    /// the old task is never announced, and the next task is unaffected.
    func testOwnShellEndingWithoutWakeRecordsOneUnknownAndNoBanner() async {
        let h = harness()
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.launch("bmine", by: nil, at: 5)
        script.stop(at: 100, [("shell", "bmine")])
        var recorded: [AgentMeterEventSubmission] = []
        for second in stride(from: 101.0, through: 7300, by: 30) {
            recorded += await h.pass(script, at: second, registry: reading(.idle, at: 100.04))
        }
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(delivery(recorded.first)?.reason, TaskOutcomeAnnouncement.Reason.backgroundShellRunning)
        XCTAssertEqual(h.center.posted.count, 0)

        // The user moves on: the next task completes and is announced as usual.
        script.human("p2", at: 7400)
        script.stop(at: 7500)
        await h.pass(script, at: 7503, registry: reading(.idle, at: 7500.03))
        XCTAssertEqual(h.center.posted.map(\.identifier), ["agentmeter.task.\(script.sessionID).p2"])
        let events = await h.store.events()
        XCTAssertEqual(Set(events.map(\.kind)), [.taskUnknown, .taskCompleted])
        XCTAssertFalse(events.contains { $0.kind == .taskCompleted && $0.subject.taskKey == "p1" }, "p1 never called finished")
    }

    /// Restart: a new run (new tracker, new store instance on the same file)
    /// re-derives the outcome, and the store's id dedup keeps it silent. One
    /// that the earlier run never saw (AgentMeter was not running) is
    /// recorded as `beforeLaunch`, not shown.
    func testRestartNeverRepeatsABanner() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeter-1b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 100)

        let firstClock = EventTestClock(LedgerScript.at(0))
        let first = Harness(store: AgentMeterEventStore(fileURL: file, clock: firstClock.function),
                            clock: firstClock, launchedAt: LedgerScript.at(0))
        await first.pass(script, at: 103, registry: reading(.idle, at: 100.03))
        XCTAssertEqual(first.center.posted.count, 1)

        // Relaunch mid-quiet-window of nothing: same ledger, fresh memory.
        let secondClock = EventTestClock(LedgerScript.at(110))
        let second = Harness(store: AgentMeterEventStore(fileURL: file, clock: secondClock.function),
                             clock: secondClock, launchedAt: LedgerScript.at(110))
        let again = await second.pass(script, at: 111, registry: reading(.idle, at: 100.03))
        guard case .duplicate? = again.first else { return XCTFail("expected the stored event back, got \(again)") }
        XCTAssertEqual(second.center.posted.count, 0)

        // A task that ended while no AgentMeter ran.
        var missed = LedgerScript(sessionID: "aa56fe87-0000")
        missed.human("m1", at: 0)
        missed.stop(at: 200)
        let thirdClock = EventTestClock(LedgerScript.at(900))
        let third = Harness(store: AgentMeterEventStore(fileURL: file, clock: thirdClock.function),
                            clock: thirdClock, launchedAt: LedgerScript.at(900))
        let late = await third.pass(missed, at: 901, registry: reading(.idle, at: 200.03))
        XCTAssertEqual(delivery(late.first), .suppressed(TaskOutcomeAnnouncement.Reason.beforeLaunch, at: LedgerScript.at(901)))
        XCTAssertEqual(third.center.posted.count, 0)
    }

    /// The same submission twice (a ledger rewritten with nothing new) is one
    /// banner: the tracker hands an outcome on once per run.
    func testRepeatedPassesHandOnceAndDuplicateEventsAreRefused() async {
        let h = harness()
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 100)
        let first = await h.pass(script, at: 103, registry: reading(.idle, at: 100.03))
        let second = await h.pass(script, at: 104, registry: reading(.idle, at: 100.03))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0)
        // A second tracker in the same run (two monitors) still cannot post it twice.
        h.tracker = TaskOutcomeTracker()
        let third = await h.pass(script, at: 105, registry: reading(.idle, at: 100.03))
        guard case .duplicate? = third.first else { return XCTFail("expected duplicate") }
        XCTAssertEqual(h.center.posted.count, 1)
    }

    /// Waiting after a minute, then the task's end: two banners under one
    /// identifier, so Notification Center keeps only the latest.
    func testWaitingThenCompletionReplaceEachOther() async {
        let h = harness()
        var script = LedgerScript()
        script.human("p1", at: 0)
        await h.pass(script, at: 30, registry: reading(.waiting, at: 20, waitingFor: "permission prompt"))
        XCTAssertEqual(h.center.posted.count, 0, "answered within the minute would be silent")
        await h.pass(script, at: 80, registry: reading(.waiting, at: 20, waitingFor: "permission prompt"))
        XCTAssertEqual(h.center.posted.map(\.content.title), ["Needs input · AgentMeter"])
        script.stop(at: 200)
        await h.pass(script, at: 203, registry: reading(.idle, at: 200.03))
        XCTAssertEqual(h.center.posted.map(\.content.title), ["Needs input · AgentMeter", "Finished · AgentMeter"])
        XCTAssertEqual(Set(h.center.posted.map(\.identifier)).count, 1)
        XCTAssertEqual(h.center.delivered.count, 1)
        XCTAssertEqual(h.center.delivered.values.first?.content.title, "Finished · AgentMeter")
    }

    /// Reopen: a short follow-up is recorded silently; a long one is
    /// announced and replaces the first banner.
    func testReopenedFollowUpsAreJudgedOnTheirOwnLength() async {
        let h = harness()
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.stop(at: 100)
        await h.pass(script, at: 103, registry: reading(.idle, at: 100.03))
        script.report("r1", at: 300)
        script.stop(at: 302)
        let short = await h.pass(script, at: 305, registry: reading(.idle, at: 302.03))
        XCTAssertEqual(delivery(short.first)?.reason, TaskOutcomeAnnouncement.Reason.belowMinimumDuration)
        script.report("r2", at: 500)
        script.stop(at: 640)
        let long = await h.pass(script, at: 643, registry: reading(.idle, at: 640.03))
        XCTAssertEqual(delivery(long.first)?.state, .posted)
        XCTAssertEqual(h.center.posted.map(\.content.body), ["Session 00000000\n1m run", "Session 00000000\nFollow-up · 2m run"])
        XCTAssertEqual(h.center.delivered.count, 1)
    }

    /// Esc is recorded for the history, never shown; failure is shown at
    /// once whatever the task's length; a kind switched off is recorded as
    /// such.
    func testInterruptedFailedAndSwitchedOffKinds() async {
        let h = harness(preferences: AgentMeterNotificationPreferences(taskWaiting: false))
        var esc = LedgerScript(sessionID: "esc")
        esc.human("e1", at: 0)
        let interrupted = await h.pass(esc, at: 10, registry: reading(.idle, at: 7), transcript: .interrupted)
        XCTAssertEqual(delivery(interrupted.first)?.reason, TaskOutcomeAnnouncement.Reason.notAnnounced)

        var failing = LedgerScript(sessionID: "fail")
        failing.human("f1", at: 0)
        failing.apply(.stopFailure(error: "overloaded"), at: 5)
        let failed = await h.pass(failing, at: 7.1, registry: reading(.idle, at: 5.05))
        XCTAssertEqual(delivery(failed.first)?.state, .posted)
        XCTAssertEqual(h.center.posted.last?.content.body, "Session fail\nAPI overloaded · after 5s")

        var waiting = LedgerScript(sessionID: "wait")
        waiting.human("w1", at: 0)
        let switchedOff = await h.pass(waiting, at: 100, registry: reading(.waiting, at: 10))
        XCTAssertEqual(delivery(switchedOff.first)?.reason, AgentMeterEventDelivery.Suppression.disabledByUser)
        XCTAssertEqual(h.center.posted.count, 1)
        let unread = await h.store.unreadCount()
        XCTAssertEqual(unread, 3, "every recorded outcome stays unread until read")
    }

    /// Item 2: an uncertain end that runs out its window is recorded as
    /// unknown, never announced as finished; the task's real end, when its
    /// shell finally wakes it, is the one banner.
    func testUncertainWindowExpiryIsRecordedNotAnnounced() async {
        let h = harness()
        var script = LedgerScript()
        script.human("p1", at: 0)
        script.launch("bserver", by: nil, at: 5)
        script.stop(at: 100, [("shell", "bserver")])
        let window = TaskOutcomeDetector.Timing.standard.uncertainWindow
        for second in stride(from: 101.0, to: 100 + window, by: 30) {
            await h.pass(script, at: second, registry: reading(.idle, at: 100.03))
        }
        XCTAssertEqual(h.center.posted.count, 0)
        let expired = await h.pass(script, at: 100 + window + 0.5, registry: reading(.idle, at: 100.03))
        XCTAssertEqual(delivery(expired.first)?.reason, TaskOutcomeAnnouncement.Reason.backgroundShellRunning)
        if case let .recorded(event)? = expired.first { XCTAssertEqual(event.kind, .taskUnknown) } else { XCTFail("not recorded") }
        XCTAssertEqual(h.center.posted.count, 0)

        // The shell wakes the task after the window; its real end is the banner.
        script.report("late", at: 100 + window + 30)
        script.stop(at: 100 + window + 300)
        let end = await h.pass(script, at: 100 + window + 303, registry: reading(.idle, at: 100 + window + 300.03))
        XCTAssertEqual(delivery(end.first)?.state, .posted)
        XCTAssertEqual(h.center.posted.count, 1)
        XCTAssertEqual(h.center.posted.last?.content.title, "Finished · AgentMeter")
        XCTAssertEqual(h.center.posted.last?.content.body, "Session 00000000\n16m run")
    }
}

/// The monitor's own plumbing: the directory watch wakes it, the registry
/// is reduced to live sessions, the sweep keeps live ledgers.
final class TaskOutcomeMonitorTests: XCTestCase {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
        func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
    }

    func testLedgerWriteWakesTheMonitor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeter-watch-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let registry = Box<[String: TaskOutcomeRegistryReading]>([:])
        let delivered = Box<[TaskOutcome]>([])
        let sweeps = Box(0)
        let arrived = expectation(description: "completion delivered")
        arrived.assertForOverFulfill = false
        let environment = TaskOutcomeMonitor.Environment(
            ledgerDirectory: dir,
            readLedgers: { TaskLedgerStore.readAll(in: dir).map(\.ledger) },
            readRegistry: { registry.get() },
            readPayloads: { [:] },
            transcriptVerdict: { _ in .unavailable },
            sweepLedgers: { _, _ in sweeps.mutate { $0 += 1 } },
            now: { Date() })
        let monitor = TaskOutcomeMonitor(environment: environment) { outcomes in
            delivered.mutate { $0 += outcomes }
            arrived.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }
        // Let the first pass open the watch on the (new) directory.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        let stopAt = Date().addingTimeInterval(-10)
        registry.set(["s1": TaskOutcomeRegistryReading(status: .idle, statusUpdatedAt: stopAt.addingTimeInterval(0.05))])
        try TaskLedgerStore.apply(TaskLedgerEvent(kind: .prompt(promptID: "p1", shape: .human),
                                                  at: stopAt.addingTimeInterval(-120)), sessionID: "s1", in: dir)
        try TaskLedgerStore.apply(TaskLedgerEvent(kind: .stop(backgroundTasks: [], cronsArmed: false, stopHookActive: false),
                                                  at: stopAt), sessionID: "s1", in: dir)
        // The idle fallback is 30 s; only the watch can deliver within 5 s.
        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(delivered.get().map(\.kind), [.completed])
        XCTAssertEqual(sweeps.get(), 1, "swept once at start, hourly after")
        monitor.evaluateNow()
        XCTAssertEqual(delivered.get().count, 1, "handed on once")
    }

    func testLiveRegistryKeepsLiveNewestEntryPerSession() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ pid: Int, _ session: String?, _ status: ClaudeSessionRegistryEntry.Status, _ updated: TimeInterval,
                   started: TimeInterval = 999_000) -> ClaudeSessionRegistryEntry {
            ClaudeSessionRegistryEntry(pid: pid, sessionID: session, cwd: nil, startedAt: Date(timeIntervalSince1970: started),
                                       status: status, waitingFor: nil, statusUpdatedAt: Date(timeIntervalSince1970: updated))
        }
        let processStart: (Int) -> Date? = { pid in
            switch pid {
            case 3: return nil  // gone
            case 6: return Date(timeIntervalSince1970: 999_500)  // a later process reusing the PID
            default: return Date(timeIntervalSince1970: 998_999)
            }
        }
        let live = TaskOutcomeMonitor.liveRegistry(
            [1: entry(1, "a", .idle, 10), 2: entry(2, "a", .busy, 20), 3: entry(3, "b", .busy, 30),
             4: entry(4, "c", .idle, 40), 5: entry(5, nil, .busy, 50), 6: entry(6, "d", .busy, 60)],
            processStart: processStart, now: now)
        XCTAssertEqual(live["a"]?.status, .busy, "two processes on one session: the newest status")
        XCTAssertNil(live["b"], "dead process")
        XCTAssertEqual(live["c"]?.status, .idle)
        XCTAssertNil(live["d"], "review finding 5: the PID belongs to a newer process now")
        XCTAssertEqual(live.count, 2)
        // The kernel's start time for a process that exists: this one.
        let own = TaskOutcomeMonitor.processStartDate(Int(getpid()))
        XCTAssertNotNil(own)
        XCTAssertLessThanOrEqual(own ?? .distantFuture, Date())
        XCTAssertNil(TaskOutcomeMonitor.processStartDate(0))
    }

    /// A helper registered under the session's id (a `claude -p` the user
    /// ran from inside it) never makes the user's own session headless,
    /// whichever entry was written last.
    func testASessionIsHeadlessOnlyWhenEveryLiveEntryIs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ pid: Int, _ session: String, kind: String?, entrypoint: String?, updated: TimeInterval) -> ClaudeSessionRegistryEntry {
            ClaudeSessionRegistryEntry(pid: pid, sessionID: session, cwd: nil, startedAt: Date(timeIntervalSince1970: 999_000),
                                       status: .idle, waitingFor: nil, statusUpdatedAt: Date(timeIntervalSince1970: updated),
                                       kind: kind, entrypoint: entrypoint)
        }
        let live = TaskOutcomeMonitor.liveRegistry(
            [1: entry(1, "editor", kind: "interactive", entrypoint: "claude-vscode", updated: 10),
             2: entry(2, "editor", kind: "print", entrypoint: "sdk-cli", updated: 20),
             3: entry(3, "script", kind: "print", entrypoint: "sdk-cli", updated: 30),
             4: entry(4, "script", kind: nil, entrypoint: "sdk-ts", updated: 40),
             5: entry(5, "mixed", kind: "print", entrypoint: "sdk-cli", updated: 50),
             6: entry(6, "mixed", kind: "some-future-kind", entrypoint: nil, updated: 60)],
            processStart: { _ in Date(timeIntervalSince1970: 998_999) }, now: now)
        XCTAssertEqual(live["editor"]?.launch, .interactive, "the helper's entry is the newest, and still")
        XCTAssertEqual(live["editor"]?.statusUpdatedAt, Date(timeIntervalSince1970: 20), "status: the newest, as before")
        XCTAssertEqual(live["script"]?.launch, .headless, "every entry an SDK run")
        XCTAssertNil(live["mixed"]?.launch, "one entry unknown: no hint")

        // Once seen interactive, the tracker keeps it so after the editor's
        // entry goes and only the helper's is left.
        var script = LedgerScript()
        script.human("p1", at: 1)
        script.stop(at: 120)
        var tracker = TaskOutcomeTracker()
        _ = tracker.evaluate(ledgers: [script.ledger!],
                             registry: [script.sessionID: TaskOutcomeRegistryReading(
                                status: .busy, statusUpdatedAt: LedgerScript.at(1.05), launch: .interactive)],
                             payloads: [:], now: LedgerScript.at(60), transcript: { _ in .unavailable })
        let helperOnly = TaskOutcomeRegistryReading(status: .idle, statusUpdatedAt: LedgerScript.at(120.05), launch: .headless)
        var outcomes: [TaskOutcome] = []
        for second in [120.5, 123.0] {
            outcomes += tracker.evaluate(ledgers: [script.ledger!], registry: [script.sessionID: helperOnly], payloads: [:],
                                         now: LedgerScript.at(second), transcript: { _ in .unavailable }).outcomes
        }
        XCTAssertEqual(outcomes.map(\.kind), [.completed])
        XCTAssertEqual(outcomes.first?.launch, .interactive)
    }

    /// Review finding 7: one pass that misses a session's registry file (a
    /// read mid-rewrite) does not count as "no registry" and end a held task.
    func testTrackerRidesOverAMissedRegistryRead() {
        var script = LedgerScript()
        script.human("p", at: 0)
        script.stop(at: 100)
        var tracker = TaskOutcomeTracker()
        let busy = TaskOutcomeRegistryReading(status: .busy, statusUpdatedAt: LedgerScript.at(0.05))
        func pass(_ seconds: TimeInterval, _ registry: TaskOutcomeRegistryReading?) -> [TaskOutcome.Kind] {
            tracker.evaluate(ledgers: [script.ledger!], registry: registry.map { [script.sessionID: $0] } ?? [:],
                             payloads: [:], now: LedgerScript.at(seconds), transcript: { _ in .unavailable }).outcomes.map(\.kind)
        }
        XCTAssertEqual(pass(104, busy), [])
        XCTAssertEqual(pass(106, nil), [], "missed once: the last reading stands in")
        XCTAssertEqual(pass(106.5, busy), [])
        XCTAssertEqual(pass(109, nil), [], "within the carry-over of the 106.5 reading")
        XCTAssertEqual(pass(110, nil), [.completed], "gone for good: the quiet window applies")
    }

    /// Review finding 8: a `waiting` re-stamped mid-wait keeps its first
    /// stamp, so the delay is not restarted (and the id is per turn anyway).
    func testTrackerKeepsTheFirstStampOfAWait() {
        var script = LedgerScript()
        script.human("p", at: 0)
        var tracker = TaskOutcomeTracker()
        func pass(_ seconds: TimeInterval, _ stamp: TimeInterval) -> [TaskOutcome] {
            tracker.evaluate(ledgers: [script.ledger!],
                             registry: [script.sessionID: TaskOutcomeRegistryReading(status: .waiting, statusUpdatedAt: LedgerScript.at(stamp))],
                             payloads: [:], now: LedgerScript.at(seconds), transcript: { _ in .unavailable }).outcomes
        }
        XCTAssertEqual(pass(20, 10).count, 0)
        XCTAssertEqual(pass(50, 45).count, 0, "re-stamped at 45")
        let outcome = pass(70, 45).first
        XCTAssertEqual(outcome?.kind, .waiting, "60 s from the first stamp, not the re-stamp")
        XCTAssertEqual(outcome?.startedAt, LedgerScript.at(10))
    }

    func testLiveSweepKeepsLiveAndRecentLedgers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeter-sweep-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for session in ["old-dead", "old-live", "new-dead"] {
            try TaskLedgerStore.apply(TaskLedgerEvent(kind: .prompt(promptID: "p", shape: .human), at: Date()),
                                      sessionID: session, in: dir)
        }
        let old = Date().addingTimeInterval(-2 * 86_400)
        for session in ["old-dead", "old-live"] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: TaskLedgerStore.fileURL(forSession: session, in: dir).path)
        }
        TaskOutcomeMonitor.sweepLedgers(in: dir, before: Date().addingTimeInterval(-TaskOutcomeMonitor.ledgerRetention),
                                        liveSessions: ["old-live"])
        XCTAssertEqual(Set(TaskLedgerStore.readAll(in: dir).map(\.ledger.sessionID)), ["old-live", "new-dead"])
    }
}
