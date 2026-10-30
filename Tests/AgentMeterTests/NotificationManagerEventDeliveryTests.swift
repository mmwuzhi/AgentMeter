import UserNotifications
import XCTest
@testable import AgentMeter

/// The shared event path of `NotificationManager`, against the center stub:
/// nothing here reaches the real notification center.
@MainActor
final class NotificationManagerEventDeliveryTests: XCTestCase {
    private func manager(
        _ center: AuthorizationCenterStub,
        store: AgentMeterEventStore,
        clock: EventTestClock,
        bundle: String? = "com.shu.agentmeter.tests",
        preferences: AgentMeterNotificationPreferences = AgentMeterNotificationPreferences()
    ) -> NotificationManager {
        NotificationManager(
            authorizationCenter: center, bundleIdentifier: { bundle }, eventStore: store,
            preferences: { preferences }, now: { clock.now })
    }

    private func fileStore(_ dir: URL, clock: EventTestClock) -> AgentMeterEventStore {
        AgentMeterEventStore(fileURL: dir.appendingPathComponent(AgentMeterEventStore.fileName), clock: clock.function)
    }

    private func delivery(_ submission: AgentMeterEventSubmission) -> AgentMeterEventDelivery? {
        if case let .recorded(event) = submission { return event.delivery }
        return nil
    }

    // MARK: - Posting and dedup

    func testANewEventIsRecordedThenPostedOnceWithItsCategoryAndIdentity() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        let manager = manager(center, store: store, clock: clock)
        let event = makeTaskEvent("task_completed|s1|p1", at: clock.now, identifier: "agentmeter.task.s1.p1")

        let first = await manager.submit(event)
        XCTAssertEqual(delivery(first), .posted(at: clock.now))
        XCTAssertEqual(center.requestCount, 0, "already authorized: no prompt")
        XCTAssertEqual(center.posted.count, 1)
        let request = center.posted[0]
        XCTAssertEqual(request.identifier, "agentmeter.task.s1.p1")
        XCTAssertEqual(request.content.title, "project finished")
        XCTAssertEqual(request.content.body, "session · 3m")
        XCTAssertEqual(request.content.categoryIdentifier, NotificationManager.taskCategoryIdentifier)
        // Stored with a per-project thread, as builds before 2026-10-30 did:
        // posted in the app's one group all the same.
        XCTAssertEqual(request.content.threadIdentifier, "")
        XCTAssertEqual(request.content.userInfo[NotificationManager.eventIDUserInfoKey] as? String, event.id)
        XCTAssertEqual(request.content.userInfo.count, 2, "the id and kind only: a tap looks the rest up")

        let second = await manager.submit(event)
        guard case .duplicate = second else { return XCTFail("posted twice") }
        XCTAssertEqual(center.posted.count, 1)
        let stored = await store.event(id: event.id)
        XCTAssertEqual(stored?.delivery.state, .posted)
        XCTAssertTrue(stored?.isUnread == true)
    }

    func testARestartNeverPostsAnEventAgainEvenOneLeftPending() async {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let firstCenter = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let first = manager(firstCenter, store: fileStore(dir, clock: clock), clock: clock)
        await first.submit(makeTaskEvent("posted", at: clock.now))
        // The process dies after recording "died", before posting it.
        await fileStore(dir, clock: clock).record(makeTaskEvent("died", at: clock.now))
        XCTAssertEqual(firstCenter.posted.count, 1)

        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let store = fileStore(dir, clock: clock)
        let restarted = manager(center, store: store, clock: clock)
        for id in ["posted", "died"] {
            guard case let .duplicate(existing) = await restarted.submit(makeTaskEvent(id, at: clock.now)) else {
                return XCTFail("\(id) was submitted as new after the restart")
            }
            XCTAssertEqual(existing.delivery.state, id == "died" ? .interrupted : .posted, id)
        }
        XCTAssertTrue(center.posted.isEmpty)
        XCTAssertEqual(center.statusQueries, 0, "a duplicate goes nowhere near the center")
        let pending = await store.events().filter { $0.delivery.state == .pending }
        XCTAssertTrue(pending.isEmpty, "nothing stays pending across a restart")
    }

    func testABannerWithTheSameIdentifierReplacesTheDeliveredOne() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        // The "needs input" banner goes out first, then completion replaces it.
        let waitingOn = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        await waitingOn.submit(makeTaskEvent("waiting|s1|p1", kind: .taskWaiting, at: clock.now, identifier: "agentmeter.task.s1.p1"))
        await waitingOn.submit(makeTaskEvent("completed|s1|p1", at: clock.now, identifier: "agentmeter.task.s1.p1"))

        XCTAssertEqual(center.posted.count, 2)
        XCTAssertEqual(center.delivered.count, 1, "one banner per identifier")
        XCTAssertEqual(center.delivered["agentmeter.task.s1.p1"]?.content.userInfo[NotificationManager.eventIDUserInfoKey] as? String,
                       "completed|s1|p1")
    }

    func testConcurrentSubmissionsOfOneIDPostOnce() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        let results = await withTaskGroup(of: AgentMeterEventSubmission.self) { group in
            for _ in 0..<25 {
                group.addTask { await manager.submit(makeTaskEvent("same", at: clock.now)) }
            }
            var all: [AgentMeterEventSubmission] = []
            for await result in group { all.append(result) }
            return all
        }
        let recorded = results.filter { if case .recorded = $0 { true } else { false } }
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(center.posted.count, 1)
    }

    func testConcurrentDistinctSubmissionsAreAllPostedAndPersisted() async {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let manager = manager(center, store: fileStore(dir, clock: clock), clock: clock)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { await manager.submit(makeTaskEvent("e\(i)", at: clock.now)) }
                group.addTask { await manager.markEventsRead(ids: ["e\(i)"]) }
            }
        }
        XCTAssertEqual(center.posted.count, 40)
        let reloaded = await fileStore(dir, clock: clock).events()
        XCTAssertEqual(reloaded.count, 40)
        XCTAssertTrue(reloaded.allSatisfy { $0.delivery.state == .posted })
    }

    // MARK: - Permission

    func testDeniedPermissionRecordsTheEventWithoutAskingOrPosting() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .denied)
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        let manager = manager(center, store: store, clock: clock)
        let result = await manager.submit(makeTaskEvent("a", at: clock.now))
        XCTAssertEqual(delivery(result)?.state, .suppressed)
        XCTAssertEqual(delivery(result)?.reason, AgentMeterEventDelivery.Suppression.permissionDenied)
        XCTAssertEqual(center.requestCount, 0, "a denial in System Settings is not re-asked")
        XCTAssertTrue(center.posted.isEmpty)
        let unread = await store.unreadCount()
        XCTAssertEqual(unread, 1, "still recorded, still unread")
    }

    func testTheFirstEventAsksOnceAndPostsWhenAllowed() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true))
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        let first = await manager.submit(makeTaskEvent("a", at: clock.now))
        let second = await manager.submit(makeTaskEvent("b", at: clock.now))
        XCTAssertEqual(delivery(first)?.state, .posted)
        XCTAssertEqual(delivery(second)?.state, .posted)
        XCTAssertEqual(center.requestCount, 1)
        XCTAssertTrue(manager.requested)
        XCTAssertTrue(manager.authorized, "the quota path shares the answer")
    }

    func testAPromptAnsweredNoSuppressesAndIsNotAskedAgain() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(false))
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        let first = await manager.submit(makeTaskEvent("a", at: clock.now))
        let second = await manager.submit(makeTaskEvent("b", at: clock.now))
        XCTAssertEqual(delivery(first)?.reason, AgentMeterEventDelivery.Suppression.permissionDenied)
        XCTAssertEqual(delivery(second)?.reason, AgentMeterEventDelivery.Suppression.permissionDenied)
        XCTAssertEqual(center.requestCount, 1)
        XCTAssertTrue(center.posted.isEmpty)
    }

    func testAPromptThatFailsLeavesTheEventNotAuthorized() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .failure(AuthorizationError.denied))
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        let result = await manager.submit(makeTaskEvent("a", at: clock.now))
        XCTAssertEqual(delivery(result)?.reason, AgentMeterEventDelivery.Suppression.notAuthorized)
        XCTAssertEqual(center.requestCount, 1)
    }

    func testAnEventWaitsForThePromptTheQuotaPathOpened() async {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: "alertsEnabled")
        let savedThreshold = defaults.object(forKey: "alertThresholdPercent")
        defaults.set(true, forKey: "alertsEnabled")
        defaults.set(10.0, forKey: "alertThresholdPercent")
        defer {
            restoreDefault(defaults, key: "alertsEnabled", to: savedEnabled)
            restoreDefault(defaults, key: "alertThresholdPercent", to: savedThreshold)
        }
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true))
        center.holdsRequests = true
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        let low = [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 95, resetsAt: Date().addingTimeInterval(3600))]
        manager.evaluate(provider: .claude, windows: low)
        await settle { center.requestCount == 1 }

        let submission = Task { await manager.submit(makeTaskEvent("a", at: clock.now)) }
        await settle { center.statusQueries == 1 }
        XCTAssertTrue(center.posted.isEmpty, "nothing goes out before the answer")
        center.releaseRequest()
        let result = await submission.value

        XCTAssertEqual(center.requestCount, 1, "one prompt for both paths")
        XCTAssertEqual(delivery(result)?.state, .posted)
        await settle { center.posted.count == 2 }
        XCTAssertEqual(Set(center.posted.map(\.content.title)), ["Claude quota low", "project finished"])
    }

    // MARK: - Freshness, settings, intent, bundle

    func testAnEventHeldBehindALongPromptIsRecordedButNotPosted() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true))
        center.onPrompt = { clock.advance(2 * 3600) }
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        let result = await manager.submit(makeTaskEvent("a", at: clock.now))
        XCTAssertEqual(delivery(result)?.reason, AgentMeterEventDelivery.Suppression.stale)
        XCTAssertTrue(center.posted.isEmpty)
        XCTAssertTrue(manager.authorized)
    }

    func testAnEventFoundLongAfterItHappenedIsRecordedButNotPosted() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        let old = makeTaskEvent("a", at: clock.now.addingTimeInterval(-(NotificationManager.defaultMaximumDeliveryDelay + 1)))
        let result = await manager.submit(old)
        XCTAssertEqual(delivery(result)?.reason, AgentMeterEventDelivery.Suppression.stale)
        XCTAssertEqual(center.statusQueries, 0)
        XCTAssertTrue(center.posted.isEmpty)
    }

    func testKindsSwitchedOffAreRecordedUnreadWithTheReason() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        let manager = manager(center, store: store, clock: clock,
                              preferences: AgentMeterNotificationPreferences(taskCompleted: false, taskWaiting: false))
        for (id, kind) in [("c", AgentMeterEventKind.taskCompleted), ("w", .taskWaiting), ("i", .taskInterrupted),
                           ("u", .taskUnknown), ("x", AgentMeterEventKind("future_kind"))] {
            let result = await manager.submit(makeTaskEvent(id, kind: kind, at: clock.now))
            XCTAssertEqual(delivery(result)?.reason, AgentMeterEventDelivery.Suppression.disabledByUser, id)
        }
        let failed = await manager.submit(makeTaskEvent("f", kind: .taskFailed, at: clock.now))
        XCTAssertEqual(delivery(failed)?.state, .posted)
        XCTAssertEqual(center.posted.count, 1)
        let unread = await store.unreadCount()
        XCTAssertEqual(unread, 6)
    }

    func testARecordOnlyIntentKeepsTheProducersReason() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        let result = await manager.submit(makeTaskEvent("a", at: clock.now), intent: .recordOnly(reason: "beforeLaunch"))
        XCTAssertEqual(delivery(result), .suppressed("beforeLaunch", at: clock.now))
        XCTAssertEqual(center.statusQueries, 0)
        XCTAssertTrue(center.posted.isEmpty)
    }

    func testWithoutAnAppBundleNothingTouchesTheCenter() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock, bundle: nil)
        let result = await manager.submit(makeTaskEvent("a", at: clock.now))
        XCTAssertEqual(delivery(result)?.reason, AgentMeterEventDelivery.Suppression.noAppBundle)
        XCTAssertEqual(center.statusQueries, 0)
        XCTAssertEqual(center.requestCount, 0)
    }

    // MARK: - Failure

    func testARefusedDeliveryIsRecordedAndNotRetried() async {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        center.deliverError = NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue,
                                      userInfo: [NSLocalizedDescriptionKey: "a message that must not be stored"])
        let manager = manager(center, store: fileStore(dir, clock: clock), clock: clock)
        let result = await manager.submit(makeTaskEvent("a", at: clock.now))
        XCTAssertEqual(delivery(result), .failed("UNErrorDomain:1", at: clock.now))

        center.deliverError = nil
        guard case .duplicate = await manager.submit(makeTaskEvent("a", at: clock.now)) else { return XCTFail() }
        XCTAssertEqual(center.deliverAttempts, 1)
        let reloaded = await fileStore(dir, clock: clock).event(id: "a")
        XCTAssertEqual(reloaded?.delivery.reason, "UNErrorDomain:1")
    }

    // MARK: - Taps, reads, change callbacks

    func testATapMarksTheEventReadAndHandsItOn() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        let manager = manager(center, store: store, clock: clock)
        var responses: [(String, String)] = []
        manager.onEventResponse = {
            responses.append(($0.id, $1))
            return true
        }
        await manager.submit(makeTaskEvent("a", at: clock.now))
        clock.advance(120)

        await manager.handleEventResponse(eventID: "a", actionIdentifier: UNNotificationDismissActionIdentifier)
        var readAt = await store.event(id: "a")?.readAt
        XCTAssertNil(readAt, "closing a banner is not reading it")
        XCTAssertTrue(responses.isEmpty)

        await manager.handleEventResponse(eventID: "a", actionIdentifier: UNNotificationDefaultActionIdentifier)
        readAt = await store.event(id: "a")?.readAt
        XCTAssertEqual(readAt, clock.now)
        XCTAssertEqual(responses.map(\.0), ["a"])
        XCTAssertEqual(responses.map(\.1), [UNNotificationDefaultActionIdentifier])

        await manager.handleEventResponse(eventID: "pruned", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(responses.count, 1, "an event no longer on record is not handed on")
    }

    func testATapThatDidNotReachTheEventLeavesItUnread() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        let manager = manager(center, store: store, clock: clock)
        await manager.submit(makeTaskEvent("a", at: clock.now))
        var handed = 0
        manager.onEventResponse = { _, _ in
            handed += 1
            return false
        }
        await manager.handleEventResponse(eventID: "a", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(handed, 1)
        var readAt = await store.event(id: "a")?.readAt
        XCTAssertNil(readAt, "the handler could not get there: it stays unread for the menu to explain")

        manager.onEventResponse = nil
        await manager.handleEventResponse(eventID: "a", actionIdentifier: UNNotificationDefaultActionIdentifier)
        readAt = await store.event(id: "a")?.readAt
        XCTAssertEqual(readAt, clock.now, "without a handler a tap reads it")
    }

    func testChangesAreAnnouncedOnlyWhenSomethingChanged() async {
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let manager = manager(center, store: .inMemory(clock: clock.function), clock: clock)
        var changes = 0
        manager.onEventsChanged = { changes += 1 }
        await manager.submit(makeTaskEvent("a", at: clock.now))
        XCTAssertEqual(changes, 2, "recorded, then settled")
        await manager.submit(makeTaskEvent("a", at: clock.now))
        XCTAssertEqual(changes, 2, "a duplicate changes nothing")
        var marked = await manager.markEventsRead(matching: .all)
        XCTAssertEqual(marked, 1)
        marked = await manager.markEventsRead(ids: ["a"])
        XCTAssertEqual(marked, 0)
        XCTAssertEqual(changes, 3)
    }

    // MARK: - Lifecycle and the quota path

    func testActivateRegistersTheEventCategoriesAndLoadsTheRecordOffTheMainActor() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        try AgentMeterEventLogCodec.encode(.event(makeTaskEvent("a", at: clock.now))).write(to: url)
        let center = AuthorizationCenterStub(result: .success(true))
        let logged = LockedLines()
        let store = AgentMeterEventStore(fileURL: url, clock: clock.function, log: { logged.append($0) })
        let manager = manager(center, store: store, clock: clock)

        manager.activate()
        XCTAssertTrue(center.delegate === manager)
        XCTAssertEqual(Set(center.categories?.map(\.identifier) ?? []),
                       [NotificationManager.taskCategoryIdentifier, NotificationManager.ruleCategoryIdentifier])
        XCTAssertEqual(center.requestCount, 0, "activation never prompts")
        await settle { logged.lines.count == 2 }
        XCTAssertEqual(logged.lines, ["loaded 1 events (1 lines, 0 unreadable)",
                                      "1 events an earlier run left pending marked interrupted (not retried)"])

        let unbundledCenter = AuthorizationCenterStub(result: .success(true))
        self.manager(unbundledCenter, store: .inMemory(), clock: clock, bundle: nil).activate()
        XCTAssertNil(unbundledCenter.delegate)
        XCTAssertNil(unbundledCenter.categories)
    }

    func testQuotaNotificationsStayOutOfTheEventPath() async {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: "alertsEnabled")
        let savedThreshold = defaults.object(forKey: "alertThresholdPercent")
        defaults.set(true, forKey: "alertsEnabled")
        defaults.set(10.0, forKey: "alertThresholdPercent")
        defer {
            restoreDefault(defaults, key: "alertsEnabled", to: savedEnabled)
            restoreDefault(defaults, key: "alertThresholdPercent", to: savedThreshold)
        }
        let clock = EventTestClock()
        let center = AuthorizationCenterStub(result: .success(true))
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        let manager = manager(center, store: store, clock: clock)
        await manager.requestAuthorizationIfNeeded()
        manager.evaluate(provider: .claude, windows: [
            QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 95, resetsAt: Date().addingTimeInterval(3600)),
        ])

        XCTAssertEqual(center.posted.count, 1)
        let request = center.posted[0]
        XCTAssertTrue(request.identifier.hasPrefix("agentmeter.claude.five_hour."))
        XCTAssertEqual(request.content.categoryIdentifier, "")
        XCTAssertEqual(request.content.threadIdentifier, "")
        XCTAssertEqual(request.content.userInfo as? [String: String], ["provider": "claude"])
        XCTAssertEqual(center.statusQueries, 0, "the quota path keeps its cached grant")
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    /// Waits (up to 5 s) for work on the store's queue or a parked task.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<5_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "the awaited work never ran")
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(line)
    }
}

private func restoreDefault(_ defaults: UserDefaults, key: String, to value: Any?) {
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}

final class AgentMeterNotificationPreferencesTests: XCTestCase {
    func testCompletedFailedAndWaitingDefaultOn() {
        let preferences = AgentMeterNotificationPreferences()
        XCTAssertTrue(preferences.notifies(.taskCompleted))
        XCTAssertTrue(preferences.notifies(.taskFailed))
        XCTAssertTrue(preferences.notifies(.taskWaiting))
        XCTAssertFalse(preferences.notifies(.taskInterrupted))
        XCTAssertFalse(preferences.notifies(.taskUnknown))
        XCTAssertFalse(preferences.notifies(AgentMeterEventKind("rule_fired")))
    }

    func testStoredSwitchesOverrideTheDefaultsAndMissingOnesKeepThem() {
        let unset = AgentMeterNotificationPreferences(stored: { _ in nil })
        XCTAssertEqual(unset, AgentMeterNotificationPreferences())
        XCTAssertTrue(unset.taskCompleted && unset.taskFailed && unset.taskWaiting, "nothing stored: all on")

        let stored: [String: Any] = [
            AgentMeterNotificationPreferences.taskCompletedKey: false,
            AgentMeterNotificationPreferences.taskWaitingKey: false,
            AgentMeterNotificationPreferences.taskFailedKey: "garbage",
        ]
        let read = AgentMeterNotificationPreferences(stored: { stored[$0] })
        XCTAssertFalse(read.taskCompleted)
        XCTAssertFalse(read.taskWaiting, "a stored off overrides the on default")
        XCTAssertTrue(read.taskFailed, "a value of the wrong type falls back to the default")
    }

    func testTheKeysAreTheContract() {
        XCTAssertEqual(AgentMeterNotificationPreferences.taskCompletedKey, "taskCompletedNotificationsEnabled")
        XCTAssertEqual(AgentMeterNotificationPreferences.taskFailedKey, "taskFailedNotificationsEnabled")
        XCTAssertEqual(AgentMeterNotificationPreferences.taskWaitingKey, "taskWaitingNotificationsEnabled")
    }
}
