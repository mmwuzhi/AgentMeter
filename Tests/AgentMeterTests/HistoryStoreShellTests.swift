import Foundation
import os
import SQLite3
import XCTest
@testable import AgentMeter

/// The actor shell: executor, lazy open, the ordered inbox, the barrier, the
/// latches and the counters. (The chunk runner is in `HistoryStoreShellTests+Chunks.swift`.)
final class HistoryStoreShellTests: XCTestCase {
    func makeStore(_ dir: URL, retryInterval: Duration = .seconds(60),
                   configure: @Sendable (inout HistoryDatabaseConfiguration) -> Void = { _ in }) -> HistoryStore {
        HistoryStore(directory: dir, lockRetryInterval: retryInterval, configure: configure)
    }

    func emptyScan(ticket: UInt64 = 1) -> HistoryScanBatch {
        HistoryScanBatch(ticket: ticket, startedMs: 0, isCompleteHistory: false, files: [])
    }

    // MARK: Execution and construction

    @MainActor
    func testSQLiteWorkRunsOnTheStoreQueueNeverOnTheMainThread() async throws {
        XCTAssertTrue(Thread.isMainThread, "precondition: this test body is on the MainActor")
        let store = makeStore(historyTempDirectory())
        let info = try await store.withDatabase { _ in
            (Thread.isMainThread, String(cString: __dispatch_queue_get_label(nil)))
        }
        XCTAssertFalse(info.0)
        XCTAssertEqual(info.1, "agentmeter.history")
    }

    func testInitDoesNoIOAndTheFirstIsolatedCallCreatesTheDatabase() async throws {
        let dir = historyTempDirectory().appendingPathComponent("not-yet", isDirectory: true)
        let store = makeStore(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "init must not touch the disk")
        let status = await store.status()
        XCTAssertEqual(status, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL.path))
        let stats = await store.statistics()
        XCTAssertEqual(stats.openAttempts, 1)
    }

    func testTheStoreOwnsTheClockTheTimeZoneAndTheRetentionItWasGiven() async throws {
        let pinned = Date(timeIntervalSince1970: 1_800_000_000)
        let store = HistoryStore(directory: historyTempDirectory(), retention: HistoryRetention(quotaSampleDays: 30),
                                 clock: { pinned }, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(store.clock(), pinned)
        XCTAssertEqual(store.timeZone.identifier, "Asia/Tokyo")
        XCTAssertEqual(store.retention.quotaSampleDays, 30)
        let seen = try await store.withDatabase { db in
            (db.config.clock(), db.config.timeZone.identifier, db.config.retention.quotaSampleDays)
        }
        XCTAssertEqual(seen.0, pinned, "the hooks read the injected clock, never Date()")
        XCTAssertEqual(seen.1, "Asia/Tokyo")
        XCTAssertEqual(seen.2, 30)
        XCTAssertEqual(HistoryRetention().quotaSampleDays, 400)
    }

    func testTheDefaultDirectoryIsApplicationSupportAndNotAUsageCacheDirectory() {
        let path = HistoryStore.defaultDirectory.path
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/AgentMeter"), path)
        XCTAssertFalse(path.contains("claude-usage-cache"), "ClaudeUsageCacheStore.prune deletes foreign files there")
    }

    func testReleasingTheStoreClosesTheHandleAndTheLock() async throws {
        let dir = historyTempDirectory()
        var store: HistoryStore? = makeStore(dir)
        try await store!.withDatabase { try historyPopulate($0, rows: 1_000) }
        let walURL = store!.databaseURL.path + "-wal"
        func walBytes() -> Int { ((try? FileManager.default.attributesOfItem(atPath: walURL)[.size] as? Int) ?? nil) ?? 0 }
        XCTAssertGreaterThan(walBytes(), 0)
        store = nil
        // The last reference drops, SQLiteConnection.deinit closes the handle, and the last connection
        // checkpoints the WAL and truncates it to 0 bytes (the file stays).
        var released = false
        for _ in 0..<100 {
            if walBytes() == 0 { released = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(released, "the WAL still has frames: the connection was not closed")
        let again = try HistoryDatabase.open(historyConfig(dir))    // the process lock went with it
        XCTAssertEqual(try historyDictCount(again), 1_000)
    }

    // MARK: The inbox: one consumer, call order

    /// The simpler pattern starts a second drain whenever the inbox had been
    /// empty, so a submit that arrived while the first drain was yielding
    /// between chunks ran ahead of it (199 of 200 rounds reordered). Here the
    /// running command suspends mid-way, two more commands are submitted
    /// meanwhile, and the application order must still be submission order.
    func testCallOrderIsPreservedWhileACommandYieldsInTheMiddle() async throws {
        let store = makeStore(historyTempDirectory())
        for round in 0..<200 {
            let log = HistoryOrderLog()
            let started = HistoryAsyncGate(), gate = HistoryAsyncGate()
            store.enqueue { _ in
                log.add("A-start")
                await started.open()
                await gate.wait()
                for _ in 0..<3 { await Task.yield() }
                log.add("A-end")
            }
            await started.wait()                       // A is now suspended inside its body
            store.enqueue { _ in log.add("B") }
            store.enqueue { _ in log.add("C") }
            await gate.open()
            await store.flush()
            XCTAssertEqual(log.all, ["A-start", "A-end", "B", "C"], "round \(round)")
            if log.all != ["A-start", "A-end", "B", "C"] { return }
        }
    }

    func testTheDrainRestartsAfterGoingIdleAndNeverStrandsACommand() async throws {
        let store = makeStore(historyTempDirectory())
        let log = HistoryOrderLog()
        for i in 0..<500 {
            store.enqueue { _ in log.add("\(i)") }
            if i % 3 == 0 { await store.flush() }        // drain goes idle, the next enqueue must start a new one
        }
        await store.flush()
        XCTAssertEqual(log.all, (0..<500).map(String.init))
        let stats = await store.statistics()
        XCTAssertEqual(stats.appliedCommands, 500)
    }

    func testManyProducersEveryCommandRunsOnceAndEachProducersOrderHolds() async throws {
        let store = makeStore(historyTempDirectory())
        let log = HistoryOrderLog()
        let producers = 8, perProducer = 300
        DispatchQueue.concurrentPerform(iterations: producers) { producer in
            for seq in 0..<perProducer {
                store.enqueue { _ in
                    if seq % 7 == 0 { await Task.yield() }       // yielding commands are the ones that used to reorder
                    log.add("\(producer):\(seq)")
                }
            }
        }
        await store.flush()
        let entries = log.all
        XCTAssertEqual(entries.count, producers * perProducer)
        XCTAssertEqual(Set(entries).count, entries.count, "no command ran twice")
        for producer in 0..<producers {
            let seqs = entries.compactMap { e -> Int? in
                let parts = e.split(separator: ":")
                return Int(parts[0]) == producer ? Int(parts[1]) : nil
            }
            XCTAssertEqual(seqs, Array(0..<perProducer), "producer \(producer)")
        }
    }

    func testSubmitNeverWaitsForTheDrainAndEverythingLandsInOrder() async throws {
        let store = makeStore(historyTempDirectory())
        let gate = HistoryAsyncGate(), started = HistoryAsyncGate()
        store.enqueue { _ in await started.open(); await gate.wait() }       // the drain is busy and suspended
        await started.wait()
        for i in 0..<1_000 {
            store.submit(quota: [])
            if i == 0 { store.submit(scan: emptyScan()) }
        }
        let pending = store.inbox.withLock { $0.commands.count }
        XCTAssertEqual(pending, 1_001, "1,000 submits returned while the drain was occupied: none waited for it")
        await gate.open()
        await store.flush()
        let stats = await store.statistics()
        XCTAssertEqual(stats.appliedCommands, 1_002)
        XCTAssertEqual(store.inbox.withLock { $0.commands.count }, 0)
        // The barrier resumes inside the drain's last command; the drain clears its flag when it next
        // looks at the empty inbox, a moment later.
        var cleared = false
        for _ in 0..<200 where !cleared {
            cleared = !store.inbox.withLock { $0.draining }
            if !cleared { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(cleared, "the flag is cleared when the inbox empties")
    }

    func testFlushIsABarrierThatWaitsForEverythingSubmittedBeforeIt() async throws {
        let store = makeStore(historyTempDirectory())
        let gate = HistoryAsyncGate(), started = HistoryAsyncGate()
        let log = HistoryOrderLog()
        store.enqueue { _ in await started.open(); await gate.wait(); log.add("slow") }
        await started.wait()
        let flushed = Task { await store.flush(); log.add("flushed") }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(log.all, [], "flush must not return while an earlier command is still running")
        await gate.open()
        await flushed.value
        XCTAssertEqual(log.all, ["slow", "flushed"])
        await store.flush()        // on an idle store: returns at once
    }

    func testTheFourSubmitMethodsConformToHistoryIngestingAndAreApplied() async throws {
        let store = makeStore(historyTempDirectory())
        let sink: any HistoryIngesting = store
        sink.submit(scan: emptyScan())
        sink.submit(quota: [])
        sink.submit(legacyQuota: [])
        sink.submit(resetGrants: [], recordedMs: 5)
        await store.flush()
        let stats = await store.statistics()
        XCTAssertEqual(stats.appliedCommands, 4)
        XCTAssertEqual(stats.droppedSubmissions, 0)
        XCTAssertEqual(stats.failedCommands, 0)
        let status = await store.status()
        XCTAssertEqual(status, .ready)
    }
}
