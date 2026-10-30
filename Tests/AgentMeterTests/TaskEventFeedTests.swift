@testable import AgentMeter
import Foundation
import UserNotifications
import XCTest

/// `TaskEventFeed` against the real event store (in memory or on disk), the
/// notification center stub and a stub process lookup: nothing here reaches
/// the real notification center, a real app or the user's defaults.
@MainActor
final class TaskEventFeedTests: XCTestCase {
    typealias Reason = TaskOutcomeAnnouncement.Reason

    private struct Rig {
        let feed: TaskEventFeed
        let manager: NotificationManager
        let model: AppViewModel
        let store: AgentMeterEventStore
        let center: AuthorizationCenterStub
        let recorder: RoutingRecorder
        let clock: EventTestClock
    }

    private func rig(store: AgentMeterEventStore? = nil, clock: EventTestClock = EventTestClock(),
                     lookup: ((RoutingRecorder, Date) -> TaskSessionLookup)? = nil) -> Rig {
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let store = store ?? .inMemory(clock: clock.function)
        let manager = NotificationManager(authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" },
                                          eventStore: store, now: { clock.now })
        let model = AppViewModel(snapshot: nil, storedLifetimeSpend: [])
        let recorder = RoutingRecorder()
        let feed = TaskEventFeed(manager: manager, model: model,
                                 lookup: lookup?(recorder, clock.now) ?? stubLookup(now: clock.now, recorder: recorder),
                                 log: { _ in })
        manager.onEventsChanged = { [weak feed] in feed?.scheduleReload() }
        manager.onEventResponse = { [weak feed] event, _ in
            await feed?.handleNotificationResponse(event) ?? true
        }
        return Rig(feed: feed, manager: manager, model: model, store: store, center: center, recorder: recorder,
                   clock: clock)
    }

    private func event(_ id: String, _ kind: AgentMeterEventKind = .taskCompleted, task: String? = nil,
                       session: String = "ffafe0d9-aaaa", at clock: EventTestClock,
                       detail: String = "12m run") -> AgentMeterEvent {
        AgentMeterEvent(
            id: id, kind: kind, occurredAt: clock.now, discoveredAt: clock.now,
            subject: AgentMeterEventSubject(provider: "claude", sessionID: session, taskKey: task ?? id,
                                            projectPath: "/Users/u/work/agentmeter"),
            content: AgentMeterEventContent(title: "Finished · agentmeter", body: "Session ffafe0d9\n\(detail)"),
            producerVersion: "task-outcome/1")
    }

    private func settle(_ condition: () -> Bool, _ message: String = "never settled") async {
        for _ in 0..<3_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - Latest turn results

    func testNothingIsShownUntilBothTheLogAndTheLedgersWereRead() async {
        let rig = rig()
        await rig.manager.submit(event("done", at: rig.clock))
        await rig.feed.reloadNow()
        XCTAssertTrue(rig.model.sessionTurnResults.isEmpty, "a prompt the ledger saw since may supersede it")
        rig.feed.turnStartsChanged([:])
        XCTAssertEqual(rig.model.sessionTurnResults["ffafe0d9-aaaa"],
                       SessionTurnResult(outcome: .finished, endedAt: rig.clock.now, detail: "12m run"))

        let other = self.rig(clock: rig.clock)
        other.feed.turnStartsChanged([:])
        XCTAssertTrue(other.model.sessionTurnResults.isEmpty, "the ledgers alone show nothing either")
    }

    func testFinishedThenTheNextPromptThenTheNextEnd() async {
        let rig = rig()
        rig.feed.turnStartsChanged(["ffafe0d9-aaaa": rig.clock.now.addingTimeInterval(-720)])
        await rig.manager.submit(event("t1", task: "p1", at: rig.clock))
        await settle { rig.model.sessionTurnResults["ffafe0d9-aaaa"]?.outcome == .finished }

        // The next prompt, a minute later: the result belongs to the turn before.
        rig.clock.advance(60)
        rig.feed.turnStartsChanged(["ffafe0d9-aaaa": rig.clock.now])
        XCTAssertNil(rig.model.sessionTurnResults["ffafe0d9-aaaa"], "never a stale Finished next to the new turn")

        // That turn fails.
        rig.clock.advance(180)
        await rig.manager.submit(event("t2", .taskFailed, task: "p2", at: rig.clock, detail: "Rate limit · after 3m"))
        await settle { rig.model.sessionTurnResults["ffafe0d9-aaaa"]?.outcome == .failed }
        XCTAssertEqual(rig.model.sessionTurnResults["ffafe0d9-aaaa"]?.detail, "Rate limit · after 3m")
    }

    func testAWaitOrAnInterruptionAfterAnEndHidesIt() async {
        let rig = rig()
        rig.feed.turnStartsChanged([:])
        await rig.manager.submit(event("t1", at: rig.clock))
        await settle { rig.model.sessionTurnResults.count == 1 }
        rig.clock.advance(300)
        await rig.manager.submit(event("i2", .taskInterrupted, task: "p2", at: rig.clock), intent: .recordOnly(reason: Reason.notAnnounced))
        await settle({ rig.model.sessionTurnResults.isEmpty }, "the user's own Esc ended the latest turn")
    }

    func testEveryOutcomeCountsWhateverItsBannerDid() async {
        // A short task, a headless run: no banner by design, but the turn
        // did end the way it says.
        let rig = rig()
        rig.feed.turnStartsChanged([:])
        await rig.manager.submit(event("short", session: "a", at: rig.clock), intent: .recordOnly(reason: Reason.belowMinimumDuration))
        await rig.manager.submit(event("headless", session: "b", at: rig.clock), intent: .recordOnly(reason: Reason.headlessRun))
        await settle { rig.model.sessionTurnResults.count == 2 }
        XCTAssertTrue(rig.center.posted.isEmpty, "the rows post nothing: banners keep their own rules")
    }

    func testTheResultsComeBackAfterARestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeter-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let clock = EventTestClock()
        func store() -> AgentMeterEventStore {
            AgentMeterEventStore(fileURL: dir.appendingPathComponent(AgentMeterEventStore.fileName), clock: clock.function)
        }
        let first = rig(store: store(), clock: clock)
        first.feed.turnStartsChanged([:])
        await first.manager.submit(event("t1", at: clock))
        await settle { first.model.sessionTurnResults.count == 1 }

        // A new process: the log and the ledgers say the same as before.
        let second = rig(store: store(), clock: clock)
        await second.feed.reloadNow()
        second.feed.turnStartsChanged([:])
        XCTAssertEqual(second.model.sessionTurnResults, first.model.sessionTurnResults)
        // A prompt the ledger kept while AgentMeter was not running.
        second.feed.turnStartsChanged(["ffafe0d9-aaaa": clock.now.addingTimeInterval(1)])
        XCTAssertTrue(second.model.sessionTurnResults.isEmpty)
    }

    func testChangesInABurstReloadOnce() async {
        let rig = rig()
        rig.feed.turnStartsChanged([:])
        for index in 0..<5 { await rig.manager.submit(event("e\(index)", session: "s\(index)", at: rig.clock)) }
        await settle { rig.model.sessionTurnResults.count == 5 }
        XCTAssertLessThanOrEqual(rig.feed.reloadCount, 3, "a burst is read once or twice, not once per event")
    }

    // MARK: - A tap on a banner

    func testClosingABannerDoesNothing() async {
        let rig = rig()
        var shown = 0
        rig.feed.showSessions = { shown += 1 }
        await rig.manager.submit(event("done", at: rig.clock))
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDismissActionIdentifier)
        XCTAssertEqual(shown, 0)
        XCTAssertTrue(rig.recorder.focused.isEmpty && rig.recorder.activated.isEmpty)
        let stored = await rig.store.event(id: "done")
        XCTAssertNil(stored?.readAt)
    }

    func testATapBringsTheSessionsTerminalTabForward() async {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            stubLookup(starts: [77: observed.addingTimeInterval(-60)], parents: [77: 500],
                       hosts: [77: itermHost], now: now, recorder: recorder)
        })
        rig.model.activeAgents = [session(pid: 77, tty: "ttys002", observed: observed)]
        var shown = 0
        rig.feed.showSessions = { shown += 1 }
        await rig.manager.submit(event("done", at: rig.clock))
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(rig.recorder.focused, [77])
        XCTAssertEqual(shown, 0, "it came forward: nothing else opens")
        let stored = await rig.store.event(id: "done")
        XCTAssertNotNil(stored?.readAt, "the tap is kept as history")
    }

    func testAnEditorSessionGetsOnlyItsAppBroughtForward() async {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            stubLookup(starts: [2114: observed.addingTimeInterval(-600)], parents: [2114: 13395, 13395: 6986],
                       hosts: [2114: vscodeHost], now: now, recorder: recorder)
        })
        rig.model.activeAgents = [session(pid: 2114, tty: nil, observed: observed, elapsed: 600)]
        await rig.manager.submit(event("done", at: rig.clock))
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(rig.recorder.activated, [6986])
        XCTAssertTrue(rig.recorder.focused.isEmpty)
    }

    func testARunningSessionThatCannotComeForwardOpensTheSessions() async {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            stubLookup(starts: [2114: observed.addingTimeInterval(-600)], parents: [2114: 13395, 13395: 6986],
                       hosts: [2114: vscodeHost], now: now, recorder: recorder)
        })
        rig.recorder.activateSucceeds = false
        rig.model.activeAgents = [session(pid: 2114, tty: nil, observed: observed, elapsed: 600)]
        var shown = 0
        rig.feed.showSessions = { shown += 1 }
        await rig.manager.submit(event("done", at: rig.clock))
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(rig.recorder.activated, [6986])
        XCTAssertEqual(shown, 1, "its row in the menu says what it is doing")
    }

    func testAnEndedSessionOpensNothing() async {
        let rig = rig()
        var shown = 0
        rig.feed.showSessions = { shown += 1 }
        await rig.manager.submit(event("done", at: rig.clock))
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(shown, 0, "no row to show for a session that has ended")
        XCTAssertTrue(rig.recorder.focused.isEmpty)
        XCTAssertTrue(rig.recorder.activated.isEmpty, "nothing is brought forward on a guess")
    }

    /// A live row whose start (`observed - elapsed`) matches the stub kernel's.
    private func session(pid: Int, tty: String?, observed: Date, elapsed: TimeInterval = 60) -> ActiveAgent {
        ActiveAgent(
            provider: .claude, pid: pid, parentPID: 500, command: "claude", elapsedSeconds: elapsed, observedAt: observed,
            tty: tty, cwd: "/Users/u/work/agentmeter",
            session: ActiveAgentSession(id: "ffafe0d9-aaaa", projectPath: "/Users/u/work/agentmeter", projectName: nil,
                                        branch: nil, lastUpdatedAt: nil, source: "test"))
    }
}
