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

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "agentmeter.tests.feed.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private struct Rig {
        let feed: TaskEventFeed
        let manager: NotificationManager
        let model: AppViewModel
        let store: AgentMeterEventStore
        let center: AuthorizationCenterStub
        let recorder: RoutingRecorder
        let clock: EventTestClock
        let defaults: UserDefaults
    }

    private func rig(store: AgentMeterEventStore? = nil, clock: EventTestClock = EventTestClock(),
                     defaults: UserDefaults? = nil, lookup: ((RoutingRecorder, Date) -> TaskSessionLookup)? = nil) -> Rig {
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let store = store ?? .inMemory(clock: clock.function)
        let manager = NotificationManager(authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" },
                                          eventStore: store, now: { clock.now })
        let model = AppViewModel(snapshot: nil, storedLifetimeSpend: [])
        let recorder = RoutingRecorder()
        let defaults = defaults ?? self.defaults()
        let feed = TaskEventFeed(manager: manager, model: model, defaults: defaults,
                                 lookup: lookup?(recorder, clock.now) ?? stubLookup(now: clock.now, recorder: recorder),
                                 log: { _ in })
        manager.onEventsChanged = { [weak feed] in feed?.scheduleReload() }
        manager.onEventResponse = { [weak feed] event, _ in
            await feed?.handleNotificationResponse(event) ?? true
        }
        return Rig(feed: feed, manager: manager, model: model, store: store, center: center, recorder: recorder,
                   clock: clock, defaults: defaults)
    }

    private func event(_ id: String, _ kind: AgentMeterEventKind = .taskCompleted, task: String? = nil,
                       session: String = "ffafe0d9-aaaa", at clock: EventTestClock) -> AgentMeterEvent {
        AgentMeterEvent(
            id: id, kind: kind, occurredAt: clock.now, discoveredAt: clock.now,
            subject: AgentMeterEventSubject(provider: "claude", sessionID: session, taskKey: task ?? id,
                                            projectPath: "/Users/u/work/agentmeter"),
            content: AgentMeterEventContent(title: "agentmeter finished", body: "Session ffafe0d9\n12m run"),
            producerVersion: "task-outcome/1")
    }

    private func settle(_ condition: () -> Bool, _ message: String = "never settled") async {
        for _ in 0..<3_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), message)
    }

    private func snapshot(_ rig: Rig) throws -> TaskEventsSnapshot {
        try XCTUnwrap(rig.model.taskEvents.snapshot, "still loading")
    }

    // MARK: - States

    func testLoadingThenNothingThenUnreadThenAllHandled() async throws {
        let rig = rig()
        XCTAssertEqual(rig.model.taskEvents, .loading, "before the log is read")
        await rig.feed.reloadNow()
        XCTAssertEqual(rig.model.taskEvents, .loaded(.empty))

        await rig.manager.submit(event("a", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 1 }
        let item = try XCTUnwrap(try snapshot(rig).unread.first)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(rig.center.posted.count, 1)

        await rig.feed.markSeen(item)
        await settle { rig.model.taskEvents.unreadCount == 0 }
        XCTAssertEqual(try snapshot(rig).handled.map(\.id), [item.id])
        XCTAssertEqual(try snapshot(rig).handled.first?.status, .completed)
        let stored = await rig.store.event(id: "a")
        XCTAssertNotNil(stored?.readAt)
    }

    func testChangesInABurstReloadOnce() async {
        let rig = rig()
        for index in 0..<20 { rig.feed.scheduleReload(); if index == 10 { await Task.yield() } }
        await settle { rig.feed.reloadCount >= 1 }
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertLessThanOrEqual(rig.feed.reloadCount, 2, "one reload, plus at most one for what came during it")
    }

    // MARK: - Unconfirmed

    func testAnUnconfirmedTaskIsListedAndStaysUnconfirmedWhenHandled() async throws {
        let rig = rig()
        let unknown = event("u", .taskUnknown, at: rig.clock)
        await rig.manager.submit(unknown, intent: .recordOnly(reason: Reason.backgroundShellRunning))
        XCTAssertTrue(rig.center.posted.isEmpty, "never posted")
        await settle { rig.model.taskEvents.unreadCount == 1 }
        let item = try XCTUnwrap(try snapshot(rig).unread.first)
        XCTAssertEqual(item.status, .unconfirmed)

        await rig.feed.markSeen(item)
        await settle { rig.model.taskEvents.unreadCount == 0 }
        XCTAssertEqual(try snapshot(rig).handled.first?.status, .unconfirmed, "handled is not finished")
        let stored = await rig.store.event(id: "u")
        XCTAssertEqual(stored?.kind, .taskUnknown)
        XCTAssertNotNil(stored?.readAt)
    }

    // MARK: - History-only events

    func testHistoryOnlyOutcomesAreNeitherCountedNorGivenAReadTime() async throws {
        let rig = rig()
        await rig.feed.reloadNow()
        for (id, reason) in [("launch", Reason.beforeLaunch), ("short", Reason.belowMinimumDuration),
                             ("report", Reason.reportOrigin), ("cron", Reason.cronsArmed)] {
            await rig.manager.submit(event(id, at: rig.clock), intent: .recordOnly(reason: reason))
        }
        await rig.manager.submit(event("esc", .taskInterrupted, at: rig.clock), intent: .recordOnly(reason: Reason.notAnnounced))
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 0)
        XCTAssertTrue(try snapshot(rig).isEmpty, "not even under seen")
        for id in ["launch", "short", "report", "cron", "esc"] {
            let stored = await rig.store.event(id: id)
            XCTAssertNil(stored?.readAt, "\(id): nobody read it, and no read time is invented")
        }
    }

    // MARK: - Clicks

    func testATapThatCannotReachTheSessionReadsNothingAndSaysSo() async throws {
        let rig = rig()
        await rig.manager.submit(event("wait", .taskWaiting, task: "p1", at: rig.clock))
        rig.clock.advance(600)
        await rig.manager.submit(event("done", .taskCompleted, task: "p1", at: rig.clock))
        await rig.manager.submit(event("other", .taskFailed, task: "p2", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 2 }

        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDismissActionIdentifier)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 2, "closing a banner is not reading it")
        XCTAssertNil(rig.model.taskEventNotice)

        var shown = 0
        rig.feed.showList = { shown += 1 }
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        await settle({ rig.model.taskEventNotice != nil }, "the click was never routed")
        // No live process in the stub: the session has ended.
        let notice = try XCTUnwrap(rig.model.taskEventNotice)
        XCTAssertEqual(notice.reason, .ended)
        XCTAssertEqual(notice.itemID, "ffafe0d9-aaaa|p1")
        XCTAssertEqual(notice.projectName, "agentmeter")
        XCTAssertEqual(Set(notice.eventIDs), ["done", "wait"])
        XCTAssertEqual(shown, 1, "the menu opens to say why")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 2, "nothing is read when the session was not reached")
        for id in ["done", "wait", "other"] {
            let stored = await rig.store.event(id: id)
            XCTAssertNil(stored?.readAt, id)
        }
        XCTAssertTrue(rig.recorder.focused.isEmpty)
        XCTAssertTrue(rig.recorder.activated.isEmpty, "nothing is brought forward on a guess")

        // Mark seen on the notice: the whole task, nothing else.
        await rig.feed.markSeen(notice)
        await settle { rig.model.taskEvents.unreadCount == 1 }
        XCTAssertNil(rig.model.taskEventNotice)
        let wait = await rig.store.event(id: "wait")
        XCTAssertNotNil(wait?.readAt)
        let other = await rig.store.event(id: "other")
        XCTAssertNil(other?.readAt, "another task stays unread")
    }

    func testATapThatReachesTheSessionReadsTheWholeTask() async throws {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            stubLookup(starts: [77: observed.addingTimeInterval(-60)], parents: [77: 500],
                       hosts: [77: itermHost], now: now, recorder: recorder)
        })
        rig.model.activeAgents = [ActiveAgent(
            provider: .claude, pid: 77, parentPID: 500, command: "claude", elapsedSeconds: 60, observedAt: observed,
            tty: "ttys002", cwd: "/Users/u/p",
            session: ActiveAgentSession(id: "ffafe0d9-aaaa", projectPath: "/Users/u/p", projectName: nil,
                                        branch: nil, lastUpdatedAt: nil, source: "test"))]
        await rig.manager.submit(event("wait", .taskWaiting, task: "p1", at: rig.clock))
        rig.clock.advance(600)
        await rig.manager.submit(event("done", task: "p1", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 1 }
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(rig.recorder.focused, [77])
        XCTAssertNil(rig.model.taskEventNotice)
        await settle { rig.model.taskEvents.unreadCount == 0 }
        for id in ["done", "wait"] {
            let stored = await rig.store.event(id: id)
            XCTAssertNotNil(stored?.readAt, id)
        }
    }

    func testAVSCodeSessionIsNeverSwitchedToAndStaysUnread() async throws {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            stubLookup(starts: [2114: observed.addingTimeInterval(-600), 42: observed.addingTimeInterval(-60)],
                       parents: [2114: 13395, 13395: 6986, 42: 40, 40: 6986],
                       hosts: [2114: vscodeHost, 42: vscodeHost], now: now, recorder: recorder)
        })
        // The extension's own session, and one in the integrated terminal.
        rig.model.activeAgents = [
            ActiveAgent(provider: .claude, pid: 2114, parentPID: 13395, command: "claude", elapsedSeconds: 600,
                        observedAt: observed, tty: nil, cwd: "/Users/u/work/agentmeter",
                        session: ActiveAgentSession(id: "ffafe0d9-aaaa", projectPath: "/Users/u/work/agentmeter",
                                                    projectName: nil, branch: nil, lastUpdatedAt: nil, source: "test")),
            ActiveAgent(provider: .claude, pid: 42, parentPID: 40, command: "claude", elapsedSeconds: 60,
                        observedAt: observed, tty: "ttys004", cwd: "/Users/u/work/agentmeter/Sources",
                        session: ActiveAgentSession(id: "bbbb-integrated", projectPath: "/Users/u/work/agentmeter",
                                                    projectName: nil, branch: nil, lastUpdatedAt: nil, source: "test")),
        ]
        await rig.manager.submit(event("done", at: rig.clock))
        await rig.manager.submit(event("term", task: "p2", session: "bbbb-integrated", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 2 }
        for item in try snapshot(rig).unread {
            await rig.feed.open(item)
            let notice = try XCTUnwrap(rig.model.taskEventNotice)
            XCTAssertEqual(notice.reason, .appOnly, item.id)
            XCTAssertEqual(notice.host, vscodeHost)
            XCTAssertEqual(notice.message,
                           "AgentMeter doesn't switch windows in Visual Studio Code, so it can't take you to this session's window.")
            XCTAssertEqual(notice.eventIDs, item.unreadEventIDs)
        }
        XCTAssertTrue(rig.recorder.focused.isEmpty, "no tab to select in an editor")
        XCTAssertTrue(rig.recorder.activated.isEmpty, "nothing is brought forward unasked")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 2, "not reached, so not read")

        let notice = try XCTUnwrap(rig.model.taskEventNotice)
        rig.feed.bringForward(notice)
        XCTAssertEqual(rig.recorder.activated, [vscodeHost.pid])
        XCTAssertNil(rig.model.taskEventNotice)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 2, "bringing the app forward is not reaching the session")
    }

    func testAReachedTapLeavesTheTasksHistoryOnlyEventsUnread() async throws {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            stubLookup(starts: [77: observed.addingTimeInterval(-60)], parents: [77: 500],
                       hosts: [77: itermHost], now: now, recorder: recorder)
        })
        rig.model.activeAgents = [ActiveAgent(
            provider: .claude, pid: 77, parentPID: 500, command: "claude", elapsedSeconds: 60, observedAt: observed,
            tty: "ttys002", cwd: "/Users/u/p",
            session: ActiveAgentSession(id: "ffafe0d9-aaaa", projectPath: "/Users/u/p", projectName: nil,
                                        branch: nil, lastUpdatedAt: nil, source: "test"))]
        // An earlier segment of the task, too short to announce.
        await rig.manager.submit(event("short", task: "p1", at: rig.clock), intent: .recordOnly(reason: Reason.belowMinimumDuration))
        rig.clock.advance(600)
        await rig.manager.submit(event("done", task: "p1", at: rig.clock))
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        let done = await rig.store.event(id: "done")
        XCTAssertNotNil(done?.readAt)
        let short = await rig.store.event(id: "short")
        XCTAssertNil(short?.readAt, "a history-only event is never read on anyone's behalf")
    }

    func testAFailedFocusIsExplainedNotRetried() async throws {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            recorder.focusSucceeds = false
            return stubLookup(starts: [77: observed.addingTimeInterval(-60)], parents: [77: 500],
                              hosts: [77: itermHost], now: now, recorder: recorder)
        })
        rig.model.activeAgents = [ActiveAgent(
            provider: .claude, pid: 77, parentPID: 500, command: "claude", elapsedSeconds: 60, observedAt: observed,
            tty: "ttys002", cwd: "/Users/u/p",
            session: ActiveAgentSession(id: "ffafe0d9-aaaa", projectPath: "/Users/u/p", projectName: nil,
                                        branch: nil, lastUpdatedAt: nil, source: "test"))]
        await rig.manager.submit(event("done", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 1 }
        await rig.feed.open(try XCTUnwrap(try snapshot(rig).unread.first))
        XCTAssertEqual(rig.recorder.focused, [77])
        XCTAssertEqual(rig.model.taskEventNotice?.reason, .focusFailed)
        XCTAssertEqual(rig.model.taskEventNotice?.message, "AgentMeter couldn't switch to this session's iTerm2 tab.")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 1, "a failed focus reads nothing")
    }

    // MARK: - Mark all, restart, overflow

    func testMarkAllHandledCoversOnlyWhatWasShown() async throws {
        let rig = rig()
        await rig.manager.submit(event("a", at: rig.clock))
        await rig.manager.submit(event("b", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 2 }
        let shown = try snapshot(rig).unread
        await rig.manager.submit(event("c", at: rig.clock))
        await rig.feed.markAllSeen(shown)
        await settle { rig.model.taskEvents.unreadCount == 1 }
        XCTAssertEqual(try snapshot(rig).unread.map(\.id), ["ffafe0d9-aaaa|c"])
    }

    func testUnreadAndHandledSurviveARestart() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        let first = rig(store: AgentMeterEventStore(fileURL: url, clock: clock.function), clock: clock)
        await first.manager.submit(event("a", at: clock))
        await first.manager.submit(event("u", .taskUnknown, task: "p9", at: clock),
                                   intent: .recordOnly(reason: Reason.backgroundShellRunning))
        await first.manager.submit(event("b", task: "p2", at: clock))
        await settle { first.model.taskEvents.unreadCount == 3 }
        await first.feed.markSeen(try XCTUnwrap(try snapshot(first).unread.first { $0.id.hasSuffix("|p2") }))
        await settle { first.model.taskEvents.unreadCount == 2 }

        let second = rig(store: AgentMeterEventStore(fileURL: url, clock: clock.function), clock: clock)
        XCTAssertEqual(second.model.taskEvents, .loading)
        await second.feed.reloadNow()
        XCTAssertEqual(Set(try snapshot(second).unread.map(\.status)), [.completed, .unconfirmed])
        XCTAssertEqual(try snapshot(second).handled.map(\.id), ["ffafe0d9-aaaa|p2"])
        XCTAssertTrue(second.center.posted.isEmpty, "nothing posted again")
    }

    func testDroppedUnreadEventsAreShownUntilAcknowledgedAndAgainWhenMoreGo() async throws {
        let clock = EventTestClock()
        var limits = AgentMeterEventStore.Limits.standard
        limits.maximumEvents = 3
        let store = AgentMeterEventStore.inMemory(limits: limits, clock: clock.function)
        let defaults = defaults()
        let rig = rig(store: store, clock: clock, defaults: defaults)
        for index in 0..<5 {
            await rig.manager.submit(event("e\(index)", at: clock))
            clock.advance(1)
        }
        await rig.feed.reloadNow()
        let notice = try XCTUnwrap(try snapshot(rig).overflow)
        XCTAssertEqual(notice.dropped, 2)
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 3, "the cap holds")

        await rig.feed.acknowledgeOverflow()
        XCTAssertNil(try snapshot(rig).overflow)
        await rig.feed.reloadNow()
        XCTAssertNil(try snapshot(rig).overflow, "acknowledged stays acknowledged")
        let restarted = TaskEventFeed(manager: rig.manager, model: AppViewModel(snapshot: nil, storedLifetimeSpend: []),
                                      defaults: defaults, lookup: stubLookup(now: clock.now, recorder: rig.recorder), log: { _ in })
        await restarted.reloadNow()

        await rig.manager.submit(event("e5", at: clock))
        await rig.feed.reloadNow()
        XCTAssertEqual(try snapshot(rig).overflow?.dropped, 1, "only the newly dropped one")
    }
}
