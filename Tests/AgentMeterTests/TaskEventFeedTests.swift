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

        await rig.feed.markRead(item)
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

        await rig.feed.markRead(item)
        await settle { rig.model.taskEvents.unreadCount == 0 }
        XCTAssertEqual(try snapshot(rig).handled.first?.status, .unconfirmed, "read is not finished")
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

    /// A live session in iTerm2 (pid 77) or in VS Code's extension host
    /// (pid 2114), as the rows report it.
    private func liveRow(_ pid: Int, session: String = "ffafe0d9-aaaa", tty: String? = nil,
                         observed: Date) -> ActiveAgent {
        ActiveAgent(provider: .claude, pid: pid, parentPID: 500, command: "claude", elapsedSeconds: 60,
                    observedAt: observed, tty: tty, cwd: "/Users/u/work/agentmeter",
                    session: ActiveAgentSession(id: session, projectPath: "/Users/u/work/agentmeter", projectName: nil,
                                                branch: nil, lastUpdatedAt: nil, source: "test"))
    }

    func testATapThatCannotReachTheSessionReadsTheTaskAndOpensTheListToSayWhy() async throws {
        let rig = rig()
        await rig.manager.submit(event("wait", .taskWaiting, task: "p1", at: rig.clock))
        rig.clock.advance(600)
        await rig.manager.submit(event("done", .taskCompleted, task: "p1", at: rig.clock))
        await rig.manager.submit(event("other", .taskFailed, task: "p2", at: rig.clock))
        // An earlier segment of the task, too short to announce.
        await rig.manager.submit(event("short", task: "p1", at: rig.clock), intent: .recordOnly(reason: Reason.belowMinimumDuration))
        await settle { rig.model.taskEvents.unreadCount == 2 }

        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDismissActionIdentifier)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 2, "closing a banner is not reading it")
        XCTAssertNil(rig.model.taskEventNotice)

        var shown = 0
        rig.feed.showList = { shown += 1 }
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        // No live process in the stub: the session has ended.
        let notice = try XCTUnwrap(rig.model.taskEventNotice, "the click was never routed")
        XCTAssertEqual(notice.reason, .ended)
        XCTAssertEqual(notice.message, "Session has ended")
        XCTAssertEqual(notice.itemID, "ffafe0d9-aaaa|p1")
        XCTAssertFalse(notice.item.isUnread, "kept in place as read")
        XCTAssertEqual(shown, 1, "the menu opens to say why")
        XCTAssertTrue(rig.model.taskEventsExpanded, "on the list, not on its collapsed header")
        await settle { rig.model.taskEvents.unreadCount == 1 }
        for id in ["done", "wait"] {
            let stored = await rig.store.event(id: id)
            XCTAssertNotNil(stored?.readAt, "the tap reads the whole task: \(id)")
        }
        let other = await rig.store.event(id: "other")
        XCTAssertNil(other?.readAt, "another task stays unread")
        let short = await rig.store.event(id: "short")
        XCTAssertNil(short?.readAt, "a history-only event is never read on anyone's behalf")
        XCTAssertTrue(rig.recorder.focused.isEmpty)
        XCTAssertTrue(rig.recorder.activated.isEmpty, "nothing is brought forward on a guess")
        XCTAssertEqual(try snapshot(rig).handled.first?.status, .completed, "reading keeps the status")
    }

    func testWithTheListHiddenTasksAreStillRecordedAndPostedButATapOpensNoMenu() async throws {
        let defaults = defaults()
        defaults.set(false, forKey: TaskEventListVisibility.key)
        let rig = rig(defaults: defaults)
        await rig.manager.submit(event("done", at: rig.clock))
        XCTAssertEqual(rig.center.posted.count, 1, "banners are not the list's business")
        await settle { rig.model.taskEvents.unreadCount == 1 }
        XCTAssertEqual(StatusItemController.unreadBadge(rig.model.taskEvents, carriesList: true,
                                                        listShown: TaskEventListVisibility.isShown(in: defaults)), 0,
                       "recorded and counted, but no badge")

        var shown = 0
        rig.feed.showList = { shown += 1 }
        await rig.manager.handleEventResponse(eventID: "done", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(shown, 0, "no popover with nothing to show")
        XCTAssertNil(rig.model.taskEventNotice)
        XCTAssertFalse(rig.model.taskEventsExpanded)
        await settle({ rig.model.taskEvents.unreadCount == 0 }, "the tap still reads the task")

        // Back on: everything as it stands.
        defaults.set(true, forKey: TaskEventListVisibility.key)
        XCTAssertEqual(try snapshot(rig).handled.map(\.id), ["ffafe0d9-aaaa|done"])
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

    func testAnEditorSessionGetsItsAppBroughtForwardAndIsRead() async throws {
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
            XCTAssertNil(rig.model.taskEventNotice, "the app came forward, as the tooltip said: \(item.id)")
            guard case .appOnly? = item.sessionID.flatMap({ rig.model.taskEventRoutes[$0] }) else {
                return XCTFail("the click's route is kept for the tooltip: \(item.id)")
            }
        }
        XCTAssertTrue(rig.recorder.focused.isEmpty, "no tab to select in an editor")
        XCTAssertEqual(rig.recorder.activated, [vscodeHost.pid, vscodeHost.pid], "the app only, on each click")
        await settle { rig.model.taskEvents.unreadCount == 0 }

        // The banner of a VS Code session does the same, and opens no menu.
        await rig.manager.submit(event("later", task: "p3", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 1 }
        var shown = 0
        rig.feed.showList = { shown += 1 }
        await rig.manager.handleEventResponse(eventID: "later", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(rig.recorder.activated.count, 3)
        XCTAssertEqual(shown, 0)
        XCTAssertNil(rig.model.taskEventNotice)
        XCTAssertFalse(rig.model.taskEventsExpanded, "a click that worked leaves the list as it was")
        await settle { rig.model.taskEvents.unreadCount == 0 }
    }

    func testAnAppThatDoesNotComeForwardIsSaidUnderTheRowAndTheTaskIsRead() async throws {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            recorder.activateSucceeds = false
            return stubLookup(starts: [2114: observed.addingTimeInterval(-60)], parents: [2114: 6986],
                              hosts: [2114: vscodeHost], now: now, recorder: recorder)
        })
        rig.model.activeAgents = [liveRow(2114, observed: observed)]
        await rig.manager.submit(event("done", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 1 }
        await rig.feed.open(try XCTUnwrap(try snapshot(rig).unread.first))
        XCTAssertEqual(rig.recorder.activated, [vscodeHost.pid])
        XCTAssertEqual(rig.model.taskEventNotice?.reason, .activationFailed)
        XCTAssertEqual(rig.model.taskEventNotice?.message, "Couldn't bring Visual Studio Code forward")
        await settle { rig.model.taskEvents.unreadCount == 0 }
    }

    func testNothingToOpenIsSaidUnderTheRowAndTheTaskIsRead() async throws {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            // 90 runs in no app (ssh, a tmux server); 10 and 11 both claim
            // the second session from unrelated windows.
            stubLookup(starts: [90: observed.addingTimeInterval(-60), 10: observed.addingTimeInterval(-60),
                                11: observed.addingTimeInterval(-60)],
                       parents: [90: 89, 10: 13395, 11: 12890], hosts: [10: vscodeHost, 11: vscodeHost],
                       now: now, recorder: recorder)
        })
        rig.model.activeAgents = [liveRow(90, session: "noapp-1", observed: observed),
                                  liveRow(10, session: "twice-2", observed: observed),
                                  liveRow(11, session: "twice-2", observed: observed)]
        await rig.manager.submit(event("a", task: "p1", session: "noapp-1", at: rig.clock))
        await rig.manager.submit(event("b", task: "p2", session: "twice-2", at: rig.clock))
        await rig.manager.submit(event("c", task: "p3", session: "gone-3", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 3 }
        let expected = ["noapp-1|p1": ("Not in an app AgentMeter can bring forward", TaskEventNotice.Reason.unhosted),
                        "twice-2|p2": ("More than one process has this session", .ambiguous),
                        "gone-3|p3": ("Session has ended", .ended)]
        for item in try snapshot(rig).unread {
            await rig.feed.open(item)
            let notice = try XCTUnwrap(rig.model.taskEventNotice, item.id)
            XCTAssertEqual(notice.itemID, item.id)
            XCTAssertEqual(notice.message, expected[item.id]?.0)
            XCTAssertEqual(notice.reason, expected[item.id]?.1)
        }
        XCTAssertTrue(rig.recorder.focused.isEmpty)
        XCTAssertTrue(rig.recorder.activated.isEmpty, "nothing is brought forward on a guess")
        await settle { rig.model.taskEvents.unreadCount == 0 }
    }

    func testTheListStartsCollapsedAndCollapsesAgainWhenThePopoverCloses() async throws {
        let rig = rig()
        XCTAssertFalse(rig.model.taskEventsExpanded, "collapsed by default")
        await rig.manager.submit(event("a", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 1 }
        XCTAssertFalse(rig.model.taskEventsExpanded, "something unread does not open it")
        rig.model.taskEventsExpanded = true
        await rig.feed.open(try XCTUnwrap(try snapshot(rig).unread.first))
        XCTAssertTrue(rig.model.taskEventsExpanded, "a row click leaves it open")
        rig.model.resetTaskEventsPresentation()
        XCTAssertFalse(rig.model.taskEventsExpanded, "closing the popover collapses it")
    }

    func testTheLineGoesWithTheNextClickAndWhenThePopoverCloses() async throws {
        let rig = rig()
        for id in ["a", "b", "c", "d"] { await rig.manager.submit(event(id, at: rig.clock)) }
        await settle { rig.model.taskEvents.unreadCount == 4 }
        let items = try snapshot(rig).unread
        await rig.feed.open(items[0])
        XCTAssertEqual(rig.model.taskEventNotice?.itemID, items[0].id)
        await rig.feed.open(items[1])
        XCTAssertEqual(rig.model.taskEventNotice?.itemID, items[1].id, "one line, under the last click")
        await rig.feed.markRead(items[2])
        XCTAssertNil(rig.model.taskEventNotice, "the check mark is a click too")
        await rig.feed.open(items[3])
        XCTAssertNotNil(rig.model.taskEventNotice)
        await rig.feed.markAllRead([])
        XCTAssertNil(rig.model.taskEventNotice)
        await rig.feed.open(items[0])
        rig.model.taskEventRoutes["x"] = .ended
        rig.model.resetTaskEventsPresentation()
        XCTAssertNil(rig.model.taskEventNotice, "closing the popover clears it")
        XCTAssertTrue(rig.model.taskEventRoutes.isEmpty)
    }

    func testThePointerOnARowLooksUpWhereItsClickGoesAndActivatesNothing() async throws {
        let observed = Date(timeIntervalSince1970: 1_792_458_306)
        let rig = rig(lookup: { recorder, now in
            stubLookup(starts: [77: observed.addingTimeInterval(-60)], parents: [77: 500],
                       hosts: [77: itermHost], now: now, recorder: recorder)
        })
        rig.model.activeAgents = [liveRow(77, tty: "ttys002", observed: observed)]
        await rig.manager.submit(event("done", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 1 }
        let item = try XCTUnwrap(try snapshot(rig).unread.first)
        await rig.feed.preview(item)
        await rig.feed.preview(item)
        guard case let .terminalTab(process)? = rig.model.taskEventRoutes["ffafe0d9-aaaa"] else {
            return XCTFail("no route for the tooltip")
        }
        XCTAssertEqual(process.host, itermHost)
        XCTAssertEqual(rig.recorder.hostLookups, 1, "once per session while the popover is open")
        XCTAssertTrue(rig.recorder.focused.isEmpty, "looking is not clicking")
        XCTAssertTrue(rig.recorder.activated.isEmpty)
        XCTAssertEqual(rig.model.taskEvents.unreadCount, 1, "and reads nothing")
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

    func testAFailedFocusIsSaidUnderTheRowNotRetried() async throws {
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
        XCTAssertTrue(rig.recorder.activated.isEmpty, "no app instead of the tab")
        XCTAssertEqual(rig.model.taskEventNotice?.reason, .focusFailed)
        XCTAssertEqual(rig.model.taskEventNotice?.message, "Couldn't switch to the iTerm2 tab")
        await settle { rig.model.taskEvents.unreadCount == 0 }
    }

    // MARK: - Mark all, restart, overflow

    func testMarkAllReadCoversOnlyWhatWasShown() async throws {
        let rig = rig()
        await rig.manager.submit(event("a", at: rig.clock))
        await rig.manager.submit(event("b", at: rig.clock))
        await settle { rig.model.taskEvents.unreadCount == 2 }
        let shown = try snapshot(rig).unread
        await rig.manager.submit(event("c", at: rig.clock))
        await rig.feed.markAllRead(shown)
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
        await first.feed.markRead(try XCTUnwrap(try snapshot(first).unread.first { $0.id.hasSuffix("|p2") }))
        await settle { first.model.taskEvents.unreadCount == 2 }

        let second = rig(store: AgentMeterEventStore(fileURL: url, clock: clock.function), clock: clock)
        XCTAssertEqual(second.model.taskEvents, .loading)
        await second.feed.reloadNow()
        XCTAssertEqual(Set(try snapshot(second).unread.map(\.status)), [.completed, .unconfirmed])
        XCTAssertEqual(try snapshot(second).handled.map(\.id), ["ffafe0d9-aaaa|p2"])
        XCTAssertTrue(second.center.posted.isEmpty, "nothing posted again")
    }

    func testTheRecordedTitleNamesTheTaskAfterARestart() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        let first = rig(store: AgentMeterEventStore(fileURL: url, clock: clock.function), clock: clock)
        var titled = event("a", at: clock)
        titled.subject.sessionTitle = "Fix the quota pacing tooltip"
        await first.manager.submit(titled)
        await first.manager.submit(event("b", task: "p2", at: clock))
        await settle { first.model.taskEvents.unreadCount == 2 }

        let second = rig(store: AgentMeterEventStore(fileURL: url, clock: clock.function), clock: clock)
        await second.feed.reloadNow()
        let items = try snapshot(second).unread
        XCTAssertEqual(items.first { $0.id.hasSuffix("|a") }?.storedSessionTitle, "Fix the quota pacing tooltip")
        XCTAssertNil(items.first { $0.id.hasSuffix("|p2") }?.storedSessionTitle)
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
