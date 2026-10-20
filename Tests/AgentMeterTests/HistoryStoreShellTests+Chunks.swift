import Foundation
import os
import SQLite3
import XCTest
@testable import AgentMeter

// Latches, status, the dropped-submission counter and the chunk runner.
extension HistoryStoreShellTests {
    // MARK: Status and latches

    private func writeNewerSchemaFile(in dir: URL) throws {
        let db = try HistoryDatabase.open(historyConfig(dir))
        try db.conn.setPragma("user_version", "99")
        db.close()
    }

    func testAnOpenTimeQuarantineShowsAsRebuiltAndKeepsShowingIt() async throws {
        let dir = historyTempDirectory()
        try Data(repeating: 0x42, count: 8_192).write(to: dir.appendingPathComponent(HistoryDatabase.fileName))
        let store = makeStore(dir)
        let status = await store.status()
        guard case let .rebuilt(path) = status else { return XCTFail("\(status)") }
        XCTAssertTrue(path.hasPrefix(dir.path) && path.contains(".corrupt-"), path)
        let again = await store.status()
        XCTAssertEqual(again, status, "sticky for the life of the process: what was lost does not come back")
        let rebuilds = await store.statistics().rebuilds
        XCTAssertEqual(rebuilds, 0, "an open-time quarantine is reported through the status, not counted as a runtime rebuild")
    }

    func testANewerSchemaLatchesForGoodDropsSubmissionsAndIsNeverRetried() async throws {
        let dir = historyTempDirectory()
        try writeNewerSchemaFile(in: dir)
        let store = makeStore(dir, retryInterval: .milliseconds(1))
        let log = HistoryOrderLog()
        store.submit(quota: [])
        store.submit(scan: emptyScan())
        store.submit(resetGrants: [], recordedMs: 1)
        store.enqueue { _ in log.add("custom") }            // custom commands are not dropped: they decide for themselves
        await store.flush()
        try await Task.sleep(nanoseconds: 30_000_000)       // far beyond the 1 ms retry interval
        store.submit(legacyQuota: [])
        await store.flush()
        let status = await store.status()
        guard case let .unavailable(reason) = status else { return XCTFail("\(status)") }
        XCTAssertTrue(reason.contains("schemaTooNew"), reason)
        let stats = await store.statistics()
        XCTAssertEqual(stats.droppedSubmissions, 4)
        XCTAssertEqual(stats.failedCommands, 0)
        XCTAssertEqual(stats.openAttempts, 1, "schemaTooNew is never retried, however much time passes")
        XCTAssertEqual(log.all, ["custom"])
        XCTAssertEqual(historyQuarantined(in: dir), [], "and the newer file is left alone")
    }

    func testAnOldSQLiteLatchesAsUnavailableWithoutCreatingAFile() async throws {
        let dir = historyTempDirectory()
        let store = makeStore(dir, retryInterval: .milliseconds(1)) { $0.sqliteVersionNumber = 3_036_000 }
        let first = await store.status()
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = await store.status()
        guard case let .unavailable(reason) = first else { return XCTFail("\(first)") }
        XCTAssertTrue(reason.contains("sqliteTooOld"), reason)
        XCTAssertEqual(first, second)
        let attempts = await store.statistics().openAttempts
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databaseURL.path))
    }

    /// A garbage file that cannot be moved aside (no lock, read-only directory).
    func testAnUnrecoverableFileLatchesForGood() async throws {
        let dir = historyTempDirectory()
        try Data(repeating: 0x41, count: 5_000).write(to: dir.appendingPathComponent(HistoryDatabase.fileName))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let store = makeStore(dir, retryInterval: .milliseconds(1)) { $0.useProcessLock = false }
        for _ in 0..<3 {
            let status = await store.status()
            guard case let .unavailable(reason) = status else { return XCTFail("\(status)") }
            XCTAssertTrue(reason.contains("unrecoverable"), reason)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let attempts = await store.statistics().openAttempts
        XCTAssertEqual(attempts, 1)
    }

    /// The lock file cannot be created in a read-only directory: reported with
    /// its errno and retried (it used to latch for good as "unrecoverable"),
    /// so a permission fix brings the history back without a restart.
    func testALockFileThatCannotBeCreatedIsRetriedAndRecoversOnceItCan() async throws {
        let dir = historyTempDirectory()
        try Data(repeating: 0x41, count: 5_000).write(to: dir.appendingPathComponent(HistoryDatabase.fileName))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let clock = HistoryRetryClock()
        let store = HistoryStore(directory: dir, retryClock: { clock.now() })
        var status = await store.status()
        XCTAssertEqual(status, .unavailable(reason: "lockUnavailable(lockFile: EACCES)"))
        clock.advance(.seconds(61))
        status = await store.status()
        XCTAssertEqual(status, .unavailable(reason: "lockUnavailable(lockFile: EACCES)"))
        var attempts = await store.statistics().openAttempts
        XCTAssertEqual(attempts, 2, "retried after the interval, not latched for good")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        clock.advance(.seconds(61))
        status = await store.status()
        guard case .rebuilt = status else { return XCTFail("the garbage file is quarantined once the lock can be had: \(status)") }
        attempts = await store.statistics().openAttempts
        XCTAssertEqual(attempts, 3)
    }

    /// A second app instance (the installed one next to `make run`) runs without
    /// history, loses nothing it could have kept, and takes the database as soon as the holder lets go.
    func testALockHeldByAnotherInstanceIsRetriedAndThenTakenOver() async throws {
        let dir = historyTempDirectory()
        let holder = try HistoryDatabase.open(historyConfig(dir))
        let store = makeStore(dir, retryInterval: .milliseconds(100))
        let first = await store.status()
        guard case let .unavailable(reason) = first else { return XCTFail("\(first)") }
        XCTAssertTrue(reason.contains("lockedByAnotherInstance"), reason)
        store.submit(quota: [])
        await store.flush()
        let during = await store.statistics()
        XCTAssertEqual(during.droppedSubmissions, 1)
        XCTAssertEqual(during.openAttempts, 1, "inside the retry interval the latch answers without touching the disk")
        holder.close()
        var status = HistoryStatus.unavailable(reason: "")
        for _ in 0..<100 where status != .ready {
            try await Task.sleep(nanoseconds: 30_000_000)
            status = await store.status()
        }
        XCTAssertEqual(status, .ready, "the lock is retried after the interval and taken over")
        store.submit(quota: [])
        await store.flush()
        let after = await store.statistics()
        XCTAssertEqual(after.appliedCommands, 1)
        XCTAssertEqual(after.droppedSubmissions, 1)
    }

    func testACommandThatThrowsIsCountedAndDoesNotStopTheDrain() async throws {
        struct Boom: Error {}
        let store = makeStore(historyTempDirectory())
        let log = HistoryOrderLog()
        store.enqueue { _ in throw Boom() }
        store.enqueue { _ in log.add("next") }
        await store.flush()
        let stats = await store.statistics()
        XCTAssertEqual(stats.failedCommands, 1)
        XCTAssertEqual(stats.appliedCommands, 1)
        XCTAssertEqual(log.all, ["next"])
    }

    func testTheIntegrityCheckRunsThroughTheStoreOnItsOwnReader() async throws {
        let store = makeStore(historyTempDirectory())
        try await store.withDatabase { try historyPopulate($0, rows: 500) }
        let result = try await store.runIntegrityCheck()
        XCTAssertEqual(result, ["ok"])
    }

    // MARK: inChunks

    func testChunksCommitOneTransactionEachAndYieldBetweenThemSoQueuedCallsRunInside() async throws {
        let store = makeStore(historyTempDirectory())
        let log = HistoryOrderLog()
        let items = Array(0..<5_000)
        store.enqueue { store in
            // Queued on the store's own executor BEFORE the runner starts: it can only run when the
            // runner yields, i.e. between chunks.
            Task { log.add("queued call"); _ = store.status() }
            let run = await store.inChunks(items, size: 2_000) { db, slice in
                XCTAssertTrue(db.conn.inTransaction, "each chunk runs inside its transaction")
                log.add("chunk \(slice.count)")
                try db.conn.withStatement("INSERT INTO dict(kind, value) VALUES (1, ?1)") { s in
                    for i in slice { s.bind(1, "v\(i)"); try s.step(); s.rewind() }
                }
            }
            log.add("run \(run.committed)/\(run.failed)/\(run.completed)")
        }
        await store.flush()
        XCTAssertEqual(log.all, ["chunk 2000", "queued call", "chunk 2000", "chunk 1000", "run 3/0/true"])
        let rows = try await store.withDatabase { try historyDictCount($0) }
        XCTAssertEqual(rows, 5_000)
        let stats = await store.statistics()
        XCTAssertEqual(stats.committedChunks, 3)
    }

    /// One bad row rolls its chunk back; the other chunks must still land and the failure must be counted.
    func testABadRowFailsOnlyItsChunkAndTheRunContinues() async throws {
        let store = makeStore(historyTempDirectory())
        let items: [Int?] = (0..<6_000).map { $0 == 2_500 ? nil : $0 }   // nil violates dict.value NOT NULL
        let run = HistoryOrderLog()
        store.enqueue { store in
            let result = await store.inChunks(items, size: 2_000) { db, slice in
                try db.conn.withStatement("INSERT INTO dict(kind, value) VALUES (1, ?1)") { s in
                    for item in slice {
                        if let item { s.bind(1, "v\(item)") } else { s.bindNull(1) }
                        try s.step()
                        s.rewind()
                    }
                }
            }
            run.add("\(result.committed)/\(result.failed)/\(result.completed)")
        }
        await store.flush()
        XCTAssertEqual(run.all, ["2/1/true"])
        let rows = try await store.withDatabase { try historyDictCount($0) }
        XCTAssertEqual(rows, 4_000, "chunk 2 (items 2000..<4000) rolled back whole; chunks 1 and 3 committed")
        let stats = await store.statistics()
        XCTAssertEqual(stats.failedChunks, 1)
        XCTAssertEqual(stats.committedChunks, 2)
        let inTransaction = try await store.withDatabase { $0.conn.inTransaction }
        XCTAssertFalse(inTransaction)
    }

    func testCancellationStopsTheRunBetweenChunksAndLeavesTheConnectionClean() async throws {
        let store = makeStore(historyTempDirectory())
        let items = Array(0..<10_000)
        let box = OSAllocatedUnfairLock<Task<HistoryChunkRun, Never>?>(initialState: nil)
        let gate = HistoryAsyncGate()
        let task = Task { () -> HistoryChunkRun in
            await gate.wait()
            return await store.inChunks(items, size: 2_000) { db, slice in
                box.withLock { $0?.cancel() }            // cancelled during the first chunk
                try db.conn.withStatement("INSERT INTO dict(kind, value) VALUES (1, ?1)") { s in
                    for i in slice { s.bind(1, "v\(i)"); try s.step(); s.rewind() }
                }
            }
        }
        box.withLock { $0 = task }
        await gate.open()
        let run = await task.value
        XCTAssertEqual(run, HistoryChunkRun(committed: 1, failed: 0, completed: false))
        let rows = try await store.withDatabase { try historyDictCount($0) }
        XCTAssertEqual(rows, 2_000, "only whole chunks are visible")
        try await store.withDatabase { try $0.conn.exec("INSERT INTO dict(kind, value) VALUES (2, 'after')") }
    }

    func testARebuildDuringARunStopsItAndReportsTheStoreAsRebuilt() async throws {
        let store = makeStore(historyTempDirectory())
        let items = Array(0..<6_000)
        let outcome = OSAllocatedUnfairLock<HistoryChunkRun?>(initialState: nil)
        store.enqueue { store in
            let run = await store.inChunks(items, size: 2_000) { _, _ in
                throw SQLiteError(code: SQLITE_CORRUPT, message: "database disk image is malformed", context: "step")
            }
            outcome.withLock { $0 = run }
        }
        await store.flush()
        XCTAssertEqual(outcome.withLock { $0 }, HistoryChunkRun(committed: 0, failed: 1, completed: false))
        let status = await store.status()
        guard case .rebuilt = status else { return XCTFail("\(status)") }
        let stats = await store.statistics()
        XCTAssertEqual(stats.rebuilds, 1)
        let rows = try await store.withDatabase { try historyDictCount($0) }
        XCTAssertEqual(rows, 0)
    }

    func testAnEmptyListRunsNoChunk() async throws {
        let store = makeStore(historyTempDirectory())
        let outcome = OSAllocatedUnfairLock<HistoryChunkRun?>(initialState: nil)
        store.enqueue { store in
            outcome.withLock { $0 = nil }
            let run = await store.inChunks([Int]()) { _, _ in XCTFail("no chunk expected") }
            outcome.withLock { $0 = run }
        }
        await store.flush()
        XCTAssertEqual(outcome.withLock { $0 }, HistoryChunkRun(committed: 0, failed: 0, completed: true))
    }
}
