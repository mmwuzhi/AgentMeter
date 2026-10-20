@testable import AgentMeter
import Foundation
import XCTest

/// Times the task list against a full event log, and writes that log for a
/// sandboxed run of the app. Both skip unless asked:
///
///     AGENTMETER_TASK_FEED_BENCH=1 swift test --filter TaskEventFeedBenchmarkTests
///     AGENTMETER_SEED_EVENTS=/path/events.jsonl swift test --filter TaskEventFeedBenchmarkTests/testWriteSeedLog
@MainActor
final class TaskEventFeedBenchmarkTests: XCTestCase {
    /// Near the 10,000-event cap: mostly read history, a thousand history-only
    /// events a build without 1c left unread, 150 unread tasks (a wait and its
    /// end each), 40 unconfirmed tasks, and an overflow on record.
    static func seedEntries(now: Date) -> [AgentMeterEventLogEntry] {
        var entries: [AgentMeterEventLogEntry] = [
            .unreadOverflow(AgentMeterUnreadOverflow(count: 12, throughDiscoveredAt: now.addingTimeInterval(-40 * 86_400),
                                                     lastDroppedAt: now.addingTimeInterval(-86_400))),
        ]
        func event(_ id: String, _ kind: AgentMeterEventKind, task: String, age: TimeInterval,
                   delivery: AgentMeterEventDelivery, read: Bool) -> AgentMeterEventLogEntry {
            let at = now.addingTimeInterval(-age)
            let session = "\(String(format: "%08x", abs(task.hashValue) % 0xffff_ffff))-seed"
            return .event(AgentMeterEvent(
                id: id, kind: kind, occurredAt: at, discoveredAt: at.addingTimeInterval(1),
                subject: AgentMeterEventSubject(provider: "claude", sessionID: session, taskKey: task,
                                                projectPath: "/Users/u/work/project\(abs(task.hashValue) % 12)"),
                content: AgentMeterEventContent(title: "project finished", body: "Session \(session.prefix(8))\n12m run",
                                                notificationIdentifier: "agentmeter.task.\(session).\(task)"),
                producerVersion: "task-outcome/1", delivery: delivery, readAt: read ? at.addingTimeInterval(60) : nil))
        }
        let posted = AgentMeterEventDelivery.posted(at: now)
        for index in 0..<8_500 {
            entries.append(event("read\(index)", index % 7 == 0 ? .taskFailed : .taskCompleted, task: "r\(index)",
                                 age: Double(index) * 1_500, delivery: posted, read: true))
        }
        let reasons = [TaskOutcomeAnnouncement.Reason.belowMinimumDuration, TaskOutcomeAnnouncement.Reason.beforeLaunch,
                       TaskOutcomeAnnouncement.Reason.reportOrigin, TaskOutcomeAnnouncement.Reason.notAnnounced]
        for index in 0..<1_000 {
            let reason = reasons[index % reasons.count]
            entries.append(event("hist\(index)", reason == TaskOutcomeAnnouncement.Reason.notAnnounced ? .taskInterrupted : .taskCompleted,
                                 task: "h\(index)", age: Double(index) * 900,
                                 delivery: .suppressed(reason, at: now), read: false))
        }
        for index in 0..<150 {
            entries.append(event("wait\(index)", .taskWaiting, task: "u\(index)", age: Double(index) * 3_000 + 600,
                                 delivery: posted, read: false))
            entries.append(event("done\(index)", .taskCompleted, task: "u\(index)", age: Double(index) * 3_000,
                                 delivery: posted, read: false))
        }
        for index in 0..<40 {
            entries.append(event("unk\(index)", .taskUnknown, task: "k\(index)", age: Double(index) * 7_000,
                                 delivery: .suppressed(TaskOutcomeAnnouncement.Reason.backgroundShellRunning, at: now),
                                 read: false))
        }
        return entries
    }

    func testReloadTimeAtTheCap() async throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_TASK_FEED_BENCH"] == "1" else {
            throw XCTSkip("set AGENTMETER_TASK_FEED_BENCH=1 to time the task list at 10,000 events")
        }
        let dir = historyTempDirectory()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        let now = Date()
        var data = Data()
        for entry in Self.seedEntries(now: now) { data.append(try AgentMeterEventLogCodec.encode(entry)) }
        try data.write(to: url)

        let store = AgentMeterEventStore(fileURL: url)
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let manager = NotificationManager(authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" },
                                          eventStore: store)
        let model = AppViewModel(snapshot: nil, storedLifetimeSpend: [])
        let suite = "agentmeter.tests.bench.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let feed = TaskEventFeed(manager: manager, model: model, defaults: defaults,
                                 lookup: stubLookup(now: now, recorder: RoutingRecorder()), log: { _ in })
        let clock = ContinuousClock()

        let load = clock.now
        await store.prepare()
        let loadTime = clock.now - load

        let first = clock.now
        await feed.reloadNow()
        let firstTime = clock.now - first
        var steady: [Duration] = []
        for _ in 0..<20 {
            let start = clock.now
            await feed.reloadNow()
            steady.append(clock.now - start)
        }
        steady.sort()
        // The part that runs on the main actor: grouping what the store returned.
        let unreadEvents0 = await store.events(matching: AgentMeterEventFilter(kinds: TaskEventStatus.kinds, unreadOnly: true))
        let recentEvents0 = await store.events(matching: AgentMeterEventFilter(kinds: TaskEventStatus.kinds),
                                               limit: TaskEventFeed.recentLimit)
        let grouping = clock.now
        for _ in 0..<20 {
            _ = TaskEventsSnapshot.make(unreadEvents: unreadEvents0, recentEvents: recentEvents0, overflow: nil)
        }
        let groupingTime = (clock.now - grouping) / 20
        let snapshot = try XCTUnwrap(model.taskEvents.snapshot)
        let unreadEvents = await store.unreadCount()
        print("""
            TASK-FEED-BENCH file \(data.count) B, \(Self.seedEntries(now: now).count - 1) events
            TASK-FEED-BENCH log load \(loadTime)
            TASK-FEED-BENCH first reload \(firstTime)
            TASK-FEED-BENCH steady reload p50 \(steady[10]) max \(steady[19])
            TASK-FEED-BENCH main-actor grouping of \(unreadEvents0.count) + \(recentEvents0.count) events \(groupingTime)
            TASK-FEED-BENCH unread tasks \(snapshot.unreadCount), unread events left \(unreadEvents), overflow \(snapshot.overflow?.dropped ?? 0)
            """)
        XCTAssertEqual(snapshot.unreadCount, 190)
        XCTAssertEqual(unreadEvents, 1_340, "the history-only thousand stay unread in the log, left out of the menu")
        XCTAssertEqual(snapshot.overflow?.dropped, 12)
    }

    func testWriteSeedLog() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTMETER_SEED_EVENTS"], !path.isEmpty else {
            throw XCTSkip("set AGENTMETER_SEED_EVENTS to a file path to write the seed log")
        }
        var data = Data()
        for entry in Self.seedEntries(now: Date()) { data.append(try AgentMeterEventLogCodec.encode(entry)) }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
