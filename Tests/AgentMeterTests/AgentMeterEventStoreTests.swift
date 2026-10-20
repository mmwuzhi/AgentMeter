import Foundation
import XCTest
@testable import AgentMeter

/// A clock a test moves by hand.
final class EventTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_792_458_306)) { current = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
    var function: @Sendable () -> Date { { self.now } }
}

func makeTaskEvent(_ id: String, kind: AgentMeterEventKind = .taskCompleted, at date: Date,
                   session: String = "s1", identifier: String? = nil) -> AgentMeterEvent {
    AgentMeterEvent(
        id: id, kind: kind, occurredAt: date, discoveredAt: date.addingTimeInterval(0.4),
        subject: AgentMeterEventSubject(provider: "claude", sessionID: session, taskKey: id, projectPath: "/tmp/project"),
        content: AgentMeterEventContent(title: "project finished", body: "session · 3m",
                                        notificationIdentifier: identifier, threadIdentifier: "agentmeter.task./tmp/project"),
        producerVersion: "test/1")
}

final class AgentMeterEventStoreTests: XCTestCase {
    private func store(_ dir: URL, clock: EventTestClock, limits: AgentMeterEventStore.Limits = .standard) -> AgentMeterEventStore {
        AgentMeterEventStore(fileURL: dir.appendingPathComponent(AgentMeterEventStore.fileName), limits: limits,
                             clock: clock.function)
    }

    private func lines(_ dir: URL) throws -> [String] {
        let text = try String(contentsOf: dir.appendingPathComponent(AgentMeterEventStore.fileName), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Record, dedup, restart

    func testRecordedEventsReadBackEqualAfterRestart() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let first = store(dir, clock: clock)
        let event = makeTaskEvent("a", at: clock.now.addingTimeInterval(-0.0004))
        guard case let .recorded(stored) = await first.record(event) else { return XCTFail("not recorded") }
        XCTAssertEqual(stored.delivery, .pending)
        XCTAssertTrue(stored.isUnread)
        await first.setDelivery(.posted(at: clock.now), forEventID: "a")
        clock.advance(5)
        await first.markRead(ids: ["a"])

        let restarted = store(dir, clock: clock)
        let reloaded = await restarted.event(id: "a")
        let before = await first.event(id: "a")
        XCTAssertEqual(reloaded, before)
        XCTAssertEqual(reloaded?.delivery.state, .posted)
        XCTAssertEqual(reloaded?.readAt, clock.now)
        XCTAssertEqual(reloaded?.subject.sessionID, "s1")
        XCTAssertEqual(reloaded?.producerVersion, "test/1")
    }

    func testAnIDOnRecordIsADuplicateAcrossRestartsWhateverItsDelivery() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let first = store(dir, clock: clock)
        await first.record(makeTaskEvent("posted", at: clock.now))
        await first.setDelivery(.posted(at: clock.now), forEventID: "posted")
        // A process that died between recording and posting leaves it pending.
        await first.record(makeTaskEvent("died", at: clock.now))

        let restarted = store(dir, clock: clock)
        for id in ["posted", "died"] {
            guard case let .duplicate(existing) = await restarted.record(makeTaskEvent(id, at: clock.now)) else {
                return XCTFail("\(id) recorded twice")
            }
            XCTAssertEqual(existing.id, id)
        }
        let died = await restarted.event(id: "died")
        XCTAssertEqual(died?.delivery, .interrupted(at: clock.now), "settled as terminal, never retried")
    }

    // MARK: - Pending left by an earlier run

    func testAPendingEventFromAnEarlierRunBecomesInterruptedOnceAndStaysThat() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let first = store(dir, clock: clock)
        await first.record(makeTaskEvent("posted", at: clock.now))
        await first.setDelivery(.posted(at: clock.now), forEventID: "posted")
        await first.record(makeTaskEvent("suppressed", at: clock.now))
        await first.setDelivery(.suppressed("beforeLaunch", at: clock.now), forEventID: "suppressed")
        // The run ends here: crash, kill, or a quit while a permission prompt
        // held "died" before its outcome.
        await first.record(makeTaskEvent("died", at: clock.now))
        let markedAt = clock.now.addingTimeInterval(30)
        clock.advance(30)

        let logged = EventLogLines()
        let second = AgentMeterEventStore(fileURL: dir.appendingPathComponent(AgentMeterEventStore.fileName),
                                          clock: clock.function, log: { logged.append($0) })
        let died = await second.event(id: "died")
        XCTAssertEqual(died?.delivery, .interrupted(at: markedAt))
        let posted = await second.event(id: "posted")?.delivery
        XCTAssertEqual(posted, .posted(at: clock.now.addingTimeInterval(-30)), "a final state is left alone")
        let suppressed = await second.event(id: "suppressed")?.delivery.reason
        XCTAssertEqual(suppressed, "beforeLaunch")
        XCTAssertTrue(died?.isUnread == true, "settling the delivery does not touch read state")
        XCTAssertEqual(logged.lines.last, "1 events an earlier run left pending marked interrupted (not retried)")
        let linesAfterSecond = try lines(dir).count

        // A third run finds it already terminal: no new line, same time.
        clock.advance(30)
        let third = store(dir, clock: clock)
        let again = await third.event(id: "died")
        XCTAssertEqual(again?.delivery, .interrupted(at: markedAt))
        XCTAssertEqual(try lines(dir).count, linesAfterSecond)
        guard case .duplicate = await third.record(makeTaskEvent("died", at: clock.now)) else {
            return XCTFail("an interrupted event was recorded again")
        }
        let unchanged = await third.setDelivery(.interrupted(at: clock.now), forEventID: "died")
        XCTAssertEqual(unchanged?.delivery.decidedAt, markedAt)
    }

    func testTheRecordingRunsOwnOutcomeOutranksAnInterruptedMark() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let posting = store(dir, clock: clock)
        await posting.record(makeTaskEvent("x", at: clock.now))
        // A second instance starts while "posting" still waits on the center.
        let other = store(dir, clock: clock)
        let marked = await other.event(id: "x")?.delivery.state
        XCTAssertEqual(marked, .interrupted)

        let settled = await posting.setDelivery(.posted(at: clock.now), forEventID: "x")
        XCTAssertEqual(settled?.delivery.state, .posted)
        let reread = await store(dir, clock: clock).event(id: "x")?.delivery.state
        XCTAssertEqual(reread, .posted)
        let otherView = await other.event(id: "x")?.delivery.state
        XCTAssertEqual(otherView, .posted)
    }

    func testDeliveriesOnlyMoveForwardWhateverOrderTheLinesLandIn() throws {
        let clock = EventTestClock()
        let event = try AgentMeterEventLogCodec.encode(.event(makeTaskEvent("x", at: clock.now)))
        let posted = try AgentMeterEventLogCodec.encode(.delivery(id: "x", delivery: .posted(at: clock.now)))
        let interrupted = try AgentMeterEventLogCodec.encode(.delivery(id: "x", delivery: .interrupted(at: clock.now)))
        let failed = try AgentMeterEventLogCodec.encode(.delivery(id: "x", delivery: .failed("UNErrorDomain:1", at: clock.now)))
        for order in [[posted, interrupted, failed], [interrupted, posted, failed], [interrupted, failed, posted]] {
            var state = AgentMeterEventLogState()
            state.consume(order.reduce(event, +))
            let first = order.first { $0 != interrupted }
            XCTAssertEqual(state.events["x"]?.delivery.state, first == posted ? .posted : .failed,
                           "the first final state wins and an interrupted mark never replaces it")
        }
    }

    func testThisRunsOwnPendingEventIsNotSettledByALaterReRead() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let store = store(dir, clock: clock)
        await store.record(makeTaskEvent("mine", at: clock.now))
        // Another process replaces the file (a compaction) while "mine" is
        // still being posted: the re-read is not this run's first read.
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        try AtomicFile.replace(url, with: Data(try lines(dir).joined(separator: "\n").utf8) + Data([0x0A]))
        let state = await store.event(id: "mine")?.delivery.state
        XCTAssertEqual(state, .pending)
    }

    func testPendingIsSettledAtTheFirstReadThatSucceeds() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        await store(dir, clock: clock).record(makeTaskEvent("died", at: clock.now))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let store = store(dir, clock: clock)
        let unseen = await store.event(id: "died")
        XCTAssertNil(unseen)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let seen = await store.event(id: "died")?.delivery.state
        XCTAssertEqual(seen, .interrupted)
    }

    func testRecordForcesUnreadAndPending() async {
        let clock = EventTestClock()
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        var event = makeTaskEvent("a", at: clock.now)
        event.delivery = .posted(at: clock.now)
        event.readAt = clock.now
        guard case let .recorded(stored) = await store.record(event) else { return XCTFail() }
        XCTAssertEqual(stored.delivery, .pending)
        XCTAssertNil(stored.readAt)
    }

    func testEventsOlderThanTheRetentionAreRefused() async {
        let clock = EventTestClock()
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        let old = makeTaskEvent("old", at: clock.now.addingTimeInterval(-181 * 86_400))
        let result = await store.record(old)
        XCTAssertEqual(result, .expired)
        let count = await store.events().count
        XCTAssertEqual(count, 0)
    }

    func testADecidedDeliveryIsNeverChanged() async {
        let clock = EventTestClock()
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        await store.record(makeTaskEvent("a", at: clock.now))
        await store.setDelivery(.failed("UNErrorDomain:1", at: clock.now), forEventID: "a")
        let after = await store.setDelivery(.posted(at: clock.now), forEventID: "a")
        XCTAssertEqual(after?.delivery.state, .failed)
        let unknown = await store.setDelivery(.posted(at: clock.now), forEventID: "missing")
        XCTAssertNil(unknown)
    }

    // MARK: - Read state

    func testReadStateOnlyChangesOnAnExplicitReadNeverWithTime() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let first = store(dir, clock: clock)
        await first.record(makeTaskEvent("a", at: clock.now, session: "s1"))
        await first.record(makeTaskEvent("b", at: clock.now, session: "s2"))
        await first.record(makeTaskEvent("c", kind: .taskFailed, at: clock.now, session: "s1"))

        // A month passes: still unread, in memory and after a restart.
        clock.advance(30 * 86_400)
        var unread = await first.unreadCount()
        XCTAssertEqual(unread, 3)
        unread = await store(dir, clock: clock).unreadCount()
        XCTAssertEqual(unread, 3)

        let marked = await first.markRead(matching: AgentMeterEventFilter(sessionID: "s1"))
        XCTAssertEqual(Set(marked), ["a", "c"])
        let readAt = await first.event(id: "a")?.readAt
        XCTAssertEqual(readAt, clock.now)

        clock.advance(60)
        let again = await first.markRead(ids: ["a", "b", "b", "missing"])
        XCTAssertEqual(again, ["b"], "already read and unknown ids are left alone")
        let firstRead = await first.event(id: "a")?.readAt
        XCTAssertEqual(firstRead, readAt, "a second read keeps the first readAt")

        let restarted = store(dir, clock: clock)
        unread = await restarted.unreadCount()
        XCTAssertEqual(unread, 0)
    }

    func testBulkReadsWriteBoundedLines() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let store = store(dir, clock: clock)
        for i in 0..<(AgentMeterEventStore.idsPerReadLine + 10) {
            await store.record(makeTaskEvent("e\(i)", at: clock.now))
        }
        await store.markRead(matching: .all)
        let readLines = try lines(dir).filter { $0.contains("\"op\":\"read\"") }
        XCTAssertEqual(readLines.count, 2)
        let unread = await self.store(dir, clock: clock).unreadCount()
        XCTAssertEqual(unread, 0)
    }

    func testQueriesAreNewestFirstAndFiltered() async {
        let clock = EventTestClock()
        let store = AgentMeterEventStore.inMemory(clock: clock.function)
        await store.record(makeTaskEvent("old", at: clock.now))
        clock.advance(10)
        await store.record(makeTaskEvent("failed", kind: .taskFailed, at: clock.now))
        clock.advance(10)
        await store.record(makeTaskEvent("new", at: clock.now, session: "s2"))

        let all = await store.events().map(\.id)
        XCTAssertEqual(all, ["new", "failed", "old"])
        let limited = await store.events(limit: 1).map(\.id)
        XCTAssertEqual(limited, ["new"])
        let failed = await store.events(matching: AgentMeterEventFilter(kinds: [.taskFailed])).map(\.id)
        XCTAssertEqual(failed, ["failed"])
        await store.markRead(ids: ["new"])
        let unreadS1 = await store.unreadCount(matching: AgentMeterEventFilter(sessionID: "s1"))
        XCTAssertEqual(unreadS1, 2)
        let unread = await store.events(matching: AgentMeterEventFilter(unreadOnly: true)).map(\.id)
        XCTAssertEqual(unread, ["failed", "old"])
    }

    // MARK: - Two processes on one file

    func testAnotherProcessesAppendIsSeenBeforeDeciding() async {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let mine = store(dir, clock: clock)
        let other = store(dir, clock: clock)
        // Both know the file before the other one appends to it, so mine
        // catches up by reading only what was added.
        await mine.record(makeTaskEvent("seed", at: clock.now))
        await other.prepare()
        await other.record(makeTaskEvent("x", at: clock.now))
        await other.markRead(ids: ["x"])

        guard case let .duplicate(existing) = await mine.record(makeTaskEvent("x", at: clock.now)) else {
            return XCTFail("the other process's event was not seen")
        }
        XCTAssertNotNil(existing.readAt)
    }

    func testAReplacedFileIsReReadAndKeepsTheEventsItLacks() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let mine = store(dir, clock: clock)
        await mine.record(makeTaskEvent("mine", at: clock.now))
        // Another process rewrites the file from its own view, which lacks
        // "mine" (it compacted before catching up).
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        try AtomicFile.replace(url, with: AgentMeterEventLogCodec.encode(.event(makeTaskEvent("theirs", at: clock.now))))

        let ids = await mine.events().map(\.id).sorted()
        XCTAssertEqual(ids, ["mine", "theirs"])
        let restarted = await store(dir, clock: clock).events().map(\.id).sorted()
        XCTAssertEqual(restarted, ["mine", "theirs"], "the events the new file lacked were written back")
    }

    func testADeletedFileIsWrittenBackFromMemory() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let store = store(dir, clock: clock)
        await store.record(makeTaskEvent("a", at: clock.now))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(AgentMeterEventStore.fileName))
        await store.record(makeTaskEvent("b", at: clock.now))
        let restarted = await self.store(dir, clock: clock).events().map(\.id).sorted()
        XCTAssertEqual(restarted, ["a", "b"])
    }

    // MARK: - Damage and versions

    func testTornAndGarbageLinesAreSkippedAndTheNextAppendStartsOnANewLine() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        var data = try AgentMeterEventLogCodec.encode(.event(makeTaskEvent("a", at: clock.now)))
        data.append(Data("not json\n{\"v\":1,\"op\":\"event\"}\n".utf8))
        let torn = try AgentMeterEventLogCodec.encode(.event(makeTaskEvent("torn", at: clock.now)))
        data.append(torn.prefix(torn.count / 2))
        try data.write(to: url)

        let store = store(dir, clock: clock)
        var ids = await store.events().map(\.id)
        XCTAssertEqual(ids, ["a"])
        await store.record(makeTaskEvent("b", at: clock.now))

        let restarted = self.store(dir, clock: clock)
        ids = await restarted.events().map(\.id).sorted()
        XCTAssertEqual(ids, ["a", "b"], "b did not join the torn line")
        let stats = await restarted.statistics()
        XCTAssertEqual(stats.unreadableLines, 2, "the garbage line and the torn one, now closed by b's newline")
    }

    func testANewerFormatIsAppliedButTheFileIsNeverRewritten() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        // A newer build's line: an extra field, a higher version, and an
        // operation this build does not know.
        let newer = #"{"v":2,"op":"event","event":{"id":"n","kind":"task_paused","occurredAt":1792458306000,"#
            + #""discoveredAt":1792458306000,"subject":{},"content":{"title":"t","body":"b"},"#
            + #""delivery":{"state":"posted","decidedAt":1792458306000},"futureField":true}}"# + "\n"
            + #"{"v":2,"op":"pin","id":"n"}"# + "\n"
        try Data(newer.utf8).write(to: url)

        let limits = AgentMeterEventStore.Limits(retention: 180 * 86_400, maximumEvents: 2, minimumSupersededLines: 0)
        let store = store(dir, clock: clock, limits: limits)
        let applied = await store.event(id: "n")
        XCTAssertEqual(applied?.kind.rawValue, "task_paused", "an unknown kind survives")
        for i in 0..<4 {
            await store.record(makeTaskEvent("e\(i)", at: clock.now))
            await store.markRead(ids: ["e\(i)"])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(newer), "the newer lines were kept verbatim: no compaction, no pruning")
        let count = await store.events().count
        XCTAssertEqual(count, 5, "the cap waits for a rewrite this build may not do")
        let stats = await store.statistics()
        XCTAssertEqual(stats.newestFormatVersion, 2)
    }

    func testTheLineFormatIsPinned() throws {
        let event = AgentMeterEvent(
            id: "task_completed|s1|p1", kind: .taskCompleted,
            occurredAt: Date(timeIntervalSince1970: 1_792_458_306.123),
            discoveredAt: Date(timeIntervalSince1970: 1_792_458_306.5),
            subject: AgentMeterEventSubject(sessionID: "s1", taskKey: "p1", projectPath: "/Users/u/p"),
            content: AgentMeterEventContent(title: "p finished", body: "s", notificationIdentifier: "agentmeter.task.s1.p1"),
            producerVersion: "task-outcome/1")
        let line = String(decoding: try AgentMeterEventLogCodec.encode(.event(event)), as: UTF8.self)
        let decoded = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["v"] as? Int, 1)
        XCTAssertEqual(decoded?["op"] as? String, "event")
        let body = decoded?["event"] as? [String: Any]
        XCTAssertEqual(body?["occurredAt"] as? Int64, 1_792_458_306_123)
        XCTAssertEqual(body?["discoveredAt"] as? Int64, 1_792_458_306_500)
        XCTAssertEqual((body?["delivery"] as? [String: Any])?["state"] as? String, "pending")
        XCTAssertNil(body?["readAt"])
        XCTAssertTrue(line.hasSuffix("}\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.contains(#""projectPath":"/Users/u/p""#), "paths are written without escaped slashes")

        let read = try AgentMeterEventLogCodec.encode(.read(ids: ["a"], at: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(String(decoding: read, as: UTF8.self), #"{"at":1000,"ids":["a"],"op":"read","v":1}"# + "\n")
        let overflow = try AgentMeterEventLogCodec.encode(.unreadOverflow(AgentMeterUnreadOverflow(
            count: 2, throughDiscoveredAt: Date(timeIntervalSince1970: 1), lastDroppedAt: Date(timeIntervalSince1970: 2))))
        XCTAssertEqual(String(decoding: overflow, as: UTF8.self),
                       #"{"op":"unreadOverflow","unreadOverflow":{"count":2,"lastDroppedAt":2000,"throughDiscoveredAt":1000},"v":1}"# + "\n")
        let interrupted = try AgentMeterEventLogCodec.encode(.delivery(id: "a", delivery: .interrupted(at: Date(timeIntervalSince1970: 3))))
        XCTAssertEqual(String(decoding: interrupted, as: UTF8.self),
                       #"{"delivery":{"decidedAt":3000,"state":"interrupted"},"id":"a","op":"delivery","v":1}"# + "\n")
    }

    func testReplayingTheSameLinesTwiceChangesNothing() throws {
        let clock = EventTestClock()
        var data = Data()
        data.append(try AgentMeterEventLogCodec.encode(.event(makeTaskEvent("a", at: clock.now))))
        data.append(try AgentMeterEventLogCodec.encode(.delivery(id: "a", delivery: .posted(at: clock.now))))
        data.append(try AgentMeterEventLogCodec.encode(.read(ids: ["a"], at: clock.now)))
        var duplicate = makeTaskEvent("a", at: clock.now.addingTimeInterval(99))
        duplicate.content.title = "a later copy"
        data.append(try AgentMeterEventLogCodec.encode(.event(duplicate)))
        data.append(try AgentMeterEventLogCodec.encode(.read(ids: ["a"], at: clock.now.addingTimeInterval(50))))

        var once = AgentMeterEventLogState()
        once.consume(data)
        var twice = AgentMeterEventLogState()
        twice.consume(data)
        twice.consume(data)
        XCTAssertEqual(once.events, twice.events)
        XCTAssertEqual(once.events["a"]?.content.title, "project finished", "the first event line wins")
        XCTAssertEqual(once.events["a"]?.readAt, clock.now, "the first read wins")
    }

    // MARK: - Limits and compaction

    func testOldEventsArePrunedAtLoadAndTheFileRewritten() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let first = store(dir, clock: clock)
        await first.record(makeTaskEvent("oldRead", at: clock.now))
        await first.record(makeTaskEvent("oldUnread", at: clock.now))
        await first.markRead(ids: ["oldRead"])
        clock.advance(100 * 86_400)
        await first.record(makeTaskEvent("new", at: clock.now))
        clock.advance(81 * 86_400)

        let restarted = store(dir, clock: clock)
        let ids = await restarted.events().map(\.id)
        XCTAssertEqual(ids, ["new", "oldUnread"], "a read event ages out, an unread one never does")
        XCTAssertEqual(try lines(dir).count, 2)

        // Years later it is still there, until it is read.
        clock.advance(3 * 365 * 86_400)
        let years = await store(dir, clock: clock).events().map(\.id)
        XCTAssertEqual(years, ["new", "oldUnread"])
        let overflow = await restarted.unreadOverflow()
        XCTAssertNil(overflow)
    }

    func testTheCapDropsReadEventsBeforeAnyUnread() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let writer = store(dir, clock: clock)
        for i in 0..<5 {
            await writer.record(makeTaskEvent("e\(i)", at: clock.now))
            clock.advance(1)
        }
        await writer.markRead(ids: ["e1", "e3", "e4"])

        let limits = AgentMeterEventStore.Limits(retention: 180 * 86_400, maximumEvents: 3, minimumSupersededLines: 512)
        let capped = store(dir, clock: clock, limits: limits)
        let ids = await capped.events().map(\.id)
        XCTAssertEqual(ids, ["e4", "e2", "e0"], "the two oldest read events went; the oldest event, unread, stayed")
        let overflow = await capped.unreadOverflow()
        XCTAssertNil(overflow)
        let restarted = await self.store(dir, clock: clock, limits: limits).events().map(\.id)
        XCTAssertEqual(restarted, ids)
    }

    func testUnreadEventsAloneOverTheCapDropTheOldestAndSayHowMany() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let writer = store(dir, clock: clock)
        var discovered: [String: Date] = [:]
        for i in 0..<5 {
            let event = makeTaskEvent("e\(i)", at: clock.now)
            discovered[event.id] = event.discoveredAt
            await writer.record(event)
            clock.advance(1)
        }

        let limits = AgentMeterEventStore.Limits(retention: 180 * 86_400, maximumEvents: 3, minimumSupersededLines: 512)
        let logged = EventLogLines()
        let capped = AgentMeterEventStore(fileURL: dir.appendingPathComponent(AgentMeterEventStore.fileName),
                                          limits: limits, clock: clock.function, log: { logged.append($0) })
        var ids = await capped.events().map(\.id)
        XCTAssertEqual(ids, ["e4", "e3", "e2"])
        var overflow = await capped.unreadOverflow()
        XCTAssertEqual(overflow, AgentMeterUnreadOverflow(count: 2, throughDiscoveredAt: discovered["e1"]!, lastDroppedAt: clock.now))
        XCTAssertTrue(logged.lines.contains("cap of 3 reached with unread events only: dropped the 2 oldest unread (2 so far)"))

        // The total survives a restart and keeps counting; new events are
        // still recorded, and the file stays at the cap plus the total.
        clock.advance(60)
        let restarted = store(dir, clock: clock, limits: limits)
        overflow = await restarted.unreadOverflow()
        XCTAssertEqual(overflow?.count, 2)
        let e5 = makeTaskEvent("e5", at: clock.now)
        guard case .recorded = await restarted.record(e5) else { return XCTFail("a new event was refused") }
        ids = await restarted.events().map(\.id)
        XCTAssertEqual(ids, ["e5", "e4", "e3"])
        overflow = await restarted.unreadOverflow()
        XCTAssertEqual(overflow, AgentMeterUnreadOverflow(count: 3, throughDiscoveredAt: discovered["e2"]!, lastDroppedAt: clock.now))
        XCTAssertEqual(try lines(dir).count, 4, "three events and the overflow line")
        let stats = await store(dir, clock: clock, limits: limits).statistics()
        XCTAssertEqual(stats.events, 3)
        XCTAssertEqual(stats.unreadOverflow, 3)
    }

    // MARK: - History-only events (recorded for the history, never read)

    private func recordSettled(_ store: AgentMeterEventStore, _ id: String, reason: String?, clock: EventTestClock) async {
        await store.record(makeTaskEvent(id, at: clock.now))
        await store.setDelivery(reason.map { .suppressed($0, at: clock.now) } ?? .posted(at: clock.now), forEventID: id)
    }

    func testHistoryOnlyUnreadEventsAgeOutLikeReadOnesWithoutAReadTime() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let writer = store(dir, clock: clock)
        await recordSettled(writer, "short", reason: TaskOutcomeAnnouncement.Reason.belowMinimumDuration, clock: clock)
        await recordSettled(writer, "unconfirmed", reason: TaskOutcomeAnnouncement.Reason.backgroundShellRunning, clock: clock)
        await recordSettled(writer, "bannerOff", reason: AgentMeterEventDelivery.Suppression.disabledByUser, clock: clock)
        await recordSettled(writer, "posted", reason: nil, clock: clock)
        let short = await writer.event(id: "short")
        XCTAssertNil(short?.readAt, "no read time is invented")

        clock.advance(181 * 86_400)
        let ids = await store(dir, clock: clock).events().map(\.id)
        XCTAssertEqual(Set(ids), ["unconfirmed", "bannerOff", "posted"],
                       "the history-only event aged out; the ones waiting for the user never do")
    }

    func testAtTheCapHistoryOnlyEventsGoBeforeUnreadOnesAndAreNotOverflow() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let writer = store(dir, clock: clock)
        for i in 0..<5 {
            await recordSettled(writer, "e\(i)", reason: i % 2 == 1 ? TaskOutcomeAnnouncement.Reason.beforeLaunch : nil,
                                clock: clock)
            clock.advance(1)
        }
        let limits = AgentMeterEventStore.Limits(retention: 180 * 86_400, maximumEvents: 3, minimumSupersededLines: 512)
        let capped = store(dir, clock: clock, limits: limits)
        let ids = await capped.events().map(\.id)
        XCTAssertEqual(ids, ["e4", "e2", "e0"], "the two history-only events went first, though unread")
        let overflow = await capped.unreadOverflow()
        XCTAssertNil(overflow, "nothing waiting for the user was dropped")
    }

    func testSupersededLinesAreCompactedAwayWithoutChangingTheEvents() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let limits = AgentMeterEventStore.Limits(retention: 180 * 86_400, maximumEvents: 10_000, minimumSupersededLines: 8)
        let store = store(dir, clock: clock, limits: limits)
        for i in 0..<20 {
            await store.record(makeTaskEvent("e\(i)", at: clock.now))
            await store.setDelivery(.posted(at: clock.now), forEventID: "e\(i)")
            await store.markRead(ids: ["e\(i)"])
        }
        let fileLines = try lines(dir).count
        XCTAssertLessThan(fileLines, 60, "never compacted")
        let before = await store.events()
        let after = await self.store(dir, clock: clock, limits: limits).events()
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.count, 20)
    }

    // MARK: - Disk trouble

    func testAFailedAppendKeepsTheEventAndTheNextWriteRewritesTheFile() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        let store = store(dir, clock: clock)
        await store.record(makeTaskEvent("a", at: clock.now))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)

        await store.record(makeTaskEvent("b", at: clock.now))
        let stats = await store.statistics()
        XCTAssertEqual(stats.writeFailures, 1)
        XCTAssertTrue(stats.needsRewrite)
        let duplicate = await store.record(makeTaskEvent("b", at: clock.now))
        guard case .duplicate = duplicate else { return XCTFail("memory lost b") }

        // The rewrite renames a new file over the read-only one.
        await store.record(makeTaskEvent("c", at: clock.now))
        let restarted = await self.store(dir, clock: clock).events().map(\.id).sorted()
        XCTAssertEqual(restarted, ["a", "b", "c"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testAnUnreadableFileIsNeverOverwritten() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        await store(dir, clock: clock).record(makeTaskEvent("kept", at: clock.now))
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = store(dir, clock: clock)
        await store.record(makeTaskEvent("memory", at: clock.now))
        // The first write failed too; the second would be a rewrite from a
        // memory that never saw "kept".
        await store.record(makeTaskEvent("memory2", at: clock.now))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original, "nothing was written while the file could not be read")

        // Readable again: the next call reads it and writes memory's event back.
        let ids = await store.events().map(\.id).sorted()
        XCTAssertEqual(ids, ["kept", "memory", "memory2"])
        let restarted = await self.store(dir, clock: clock).events().map(\.id).sorted()
        XCTAssertEqual(restarted, ["kept", "memory", "memory2"])
    }

    func testTheFileIsPrivate() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let store = store(dir, clock: clock)
        await store.record(makeTaskEvent("a", at: clock.now))
        let url = dir.appendingPathComponent(AgentMeterEventStore.fileName)
        var mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "appended")
        let limits = AgentMeterEventStore.Limits(retention: 180 * 86_400, maximumEvents: 1, minimumSupersededLines: 0)
        await self.store(dir, clock: clock, limits: limits).record(makeTaskEvent("b", at: clock.now))
        mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "rewritten")
    }

    // MARK: - Concurrency and cost

    func testConcurrentCallersSeeOneConsistentState() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        let store = store(dir, clock: clock)
        let results = await withTaskGroup(of: AgentMeterEventSubmission.self) { group in
            for i in 0..<200 {
                group.addTask { await store.record(makeTaskEvent("e\(i % 50)", at: clock.now)) }
                group.addTask { await store.markRead(ids: ["e\(i % 50)"]); return .expired }
            }
            var all: [AgentMeterEventSubmission] = []
            for await result in group { all.append(result) }
            return all
        }
        let recorded = results.filter { if case .recorded = $0 { true } else { false } }
        XCTAssertEqual(recorded.count, 50, "each id recorded exactly once")
        let before = await store.events()
        // A second store's first read settles what this one left pending, so
        // compare what the concurrency could have broken: ids and read state.
        let after = await self.store(dir, clock: clock).events()
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.readAt), after.map(\.readAt))
        XCTAssertTrue(after.allSatisfy { $0.delivery.state == .interrupted })
    }

    /// One-off cost of a full log at the cap: decoding at launch happens on
    /// the store's utility queue, never on the MainActor.
    func testLoadingAFullLogStaysCheap() async throws {
        let dir = historyTempDirectory()
        let clock = EventTestClock()
        var data = Data()
        for i in 0..<10_000 {
            data.append(try AgentMeterEventLogCodec.encode(.event(makeTaskEvent("event-\(i)", at: clock.now))))
        }
        try data.write(to: dir.appendingPathComponent(AgentMeterEventStore.fileName))
        let store = store(dir, clock: clock)
        let started = ContinuousClock.now
        await store.prepare()
        let elapsed = ContinuousClock.now - started
        let count = await store.events().count
        XCTAssertEqual(count, 10_000)
        print("events.jsonl: \(data.count) bytes, 10,000 events loaded in \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(5))
    }
}

final class EventLogLines: @unchecked Sendable {
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
