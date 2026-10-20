import AppKit
import Foundation
import os
import SQLite3
import XCTest
@testable import AgentMeter

/// The store's life around the edges of a process: closing it cleanly at
/// quit, a file this process may not write, lock and directory failures,
/// quarantine retention when the clock moves, the accounting zone changing
/// under a running store, and what it logs.
final class HistoryStoreLifecycleTests: XCTestCase {
    let t0: Int64 = 1_789_000_000_000

    func observations(_ range: Range<Int>, first: Int64? = nil) -> [RequestObservation] {
        let base = first ?? t0
        return range.map { n in
            hmObs(hmKey(n), [hmPart(output: 1 + n % 7)], .final,
                  first: base + Int64(n) * 1_000, last: base + Int64(n) * 1_000, final: base + Int64(n) * 1_000)
        }
    }

    /// `files` transcripts of `perFile` observations each, all with full watermarks.
    func scan(_ ticket: UInt64, files: Int, perFile: Int) -> HistoryScanBatch {
        hmScan(ticket, (0..<files).map { f in
            let obs = observations(f * perFile..<(f + 1) * perFile)
            return hmFile("/p/proj/s\(f).jsonl", scan: ticket, watermark: hmWatermark(id: UInt64(500 + f), parsed: Int64(obs.count)), obs)
        }, complete: true, startedMs: Int64(ticket) * 1_000)
    }

    func quotaRow(_ i: Int) -> QuotaSampleRow {
        QuotaSampleRow(provider: .claude, windowID: "five_hour", source: .oauth, readingMs: t0 + Int64(i) * 60_000,
                       fetchedMs: nil, cachedMs: nil, recordedMs: t0 + Int64(i) * 60_000, usedPercent: Double(i),
                       resetsAtMs: nil, cycleSeconds: nil, isModelScoped: nil, isOneTimeCredit: nil, isActive: nil,
                       severity: nil, lockedReason: nil, scopeName: nil, shareUsedOfWeekly: nil,
                       shareAllowanceOfWeekly: nil, plan: nil, tier: nil, flags: [])
    }

    func count(_ store: HistoryStore, _ table: String) async throws -> Int {
        try await store.withDatabase { Int(try $0.conn.queryInt("SELECT count(*) FROM \(table)") ?? -1) }
    }

    // MARK: Shutdown

    /// A normal quit used to end in `exit()` with the connection open: the WAL
    /// stayed non-empty, and every launch took itself for a crash and ran a
    /// full `integrity_check`.
    func testShutdownLeavesAnEmptyWalSoTheNextLaunchOpensCleanWithoutAnIntegrityCheck() async throws {
        let dir = historyTempDirectory()
        let store = hmStore(dir)
        try await store.applyScanCommand(scan(1, files: 3, perFile: 400))
        try await store.applyQuotaCommand((0..<5).map(quotaRow))
        XCTAssertGreaterThan(historyWalBytes(dir), 0, "precondition: the writes are still in the WAL")
        await store.shutdown()
        XCTAssertEqual(historyWalBytes(dir), 0, "the last close checkpointed the WAL into the file")
        let status = await store.status()
        XCTAssertEqual(status, .unavailable(reason: "closed"))

        let next = hmStore(dir)
        let unclean = try await next.withDatabase { $0.openedAfterUncleanShutdown }
        XCTAssertFalse(unclean)
        try await next.applyScanCommand(scan(2, files: 3, perFile: 400))
        let stats = await next.statistics()
        XCTAssertEqual(stats.integrityChecks, 0, "a clean quit owes no integrity check")
        let requests = try await count(next, "request")
        XCTAssertEqual(requests, 1_200)
    }

    /// The last quota readings of a session cannot be fetched again: they are
    /// applied even when a scan is in flight, queued scans and custom commands
    /// are dropped and counted, and every waiting `flush()` returns.
    func testShutdownAppliesQueuedQuotaCommandsDropsQueuedScansAndReleasesFlushes() async throws {
        let dir = historyTempDirectory()
        let store = hmStore(dir)
        let started = HistoryAsyncGate(), gate = HistoryAsyncGate()
        store.enqueue { _ in await started.open(); await gate.wait() }      // the drain is busy and suspended
        await started.wait()
        store.submit(scan: scan(1, files: 2, perFile: 10))
        store.submit(quota: [quotaRow(1)])
        store.submit(resetGrants: [ResetGrantObservation(id: "g1", resetsLeft: 1, endsAtMs: nil, clears: "five_hour")],
                     recordedMs: t0)
        store.enqueue { _ in XCTFail("a custom command queued at shutdown is dropped, not run") }
        let flushed = OSAllocatedUnfairLock(initialState: false)
        Task { await store.flush(); flushed.withLock { $0 = true } }
        store.submit(quota: [quotaRow(2)])
        // Let the barrier reach the inbox before the shutdown takes it.
        for _ in 0..<200 where store.inbox.withLock({ $0.commands.count }) < 6 { try await Task.sleep(nanoseconds: 1_000_000) }

        await store.shutdown()
        // Bounded: a shutdown that left the barrier queued behind the gated command would wait forever.
        for _ in 0..<500 where !flushed.withLock({ $0 }) { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(flushed.withLock { $0 }, "the queued flush() returned")
        XCTAssertEqual(store.inbox.withLock { $0.commands.count }, 0)
        let stats = await store.statistics()
        XCTAssertEqual(stats.droppedSubmissions, 2, "the scan and the custom command")
        XCTAssertEqual(stats.appliedCommands, 3, "two quota commands and the grant set")
        await gate.open()
        await store.flush()

        let reopened = hmStore(dir)
        let quota = try await count(reopened, "quota_sample")
        let grants = try await count(reopened, "reset_grant_sample")
        let requests = try await count(reopened, "request")
        XCTAssertEqual(quota, 2)
        XCTAssertEqual(grants, 1)
        XCTAssertEqual(requests, 0, "the queued scan was dropped; the next launch's scan re-feeds it")
    }

    /// A shutdown that lands between two chunks of a long scan returns at
    /// once, leaves no watermark that claims more than was applied, and the
    /// next launch's rescan converges to the same content as one clean ingest.
    func testAShutdownDuringALongScanReturnsWithinTheDeadlineAndARescanConverges() async throws {
        let dir = historyTempDirectory()
        let store = hmStore(dir)
        await store.setScanChunkSize(100)
        let big = scan(1, files: 60, perFile: 50)              // 3,000 observations, 30 transactions
        store.submit(scan: big)
        var committed = 0
        for _ in 0..<5_000 where committed < 4 {
            committed = await store.statistics().committedChunks
            if committed < 4 { try await Task.sleep(nanoseconds: 200_000) }
        }
        XCTAssertGreaterThanOrEqual(committed, 4, "precondition: the scan is under way")
        let began = ContinuousClock.now
        let inTime = await QuitSequence.run({ await store.shutdown() }, deadline: QuitSequence.historyDeadline)
        let took = ContinuousClock.now - began
        XCTAssertTrue(inTime)
        XCTAssertLessThan(took, QuitSequence.historyDeadline)
        await store.flush()
        let stats = await store.statistics()
        XCTAssertEqual(stats.failedCommands, 1, "the scan was interrupted, not finished")
        XCTAssertLessThan(stats.committedChunks, 30)
        XCTAssertEqual(historyWalBytes(dir), 0)

        // Every watermark on disk is backed by all of its file's observations.
        let reopened = hmStore(dir)
        let watermarked = try await reopened.withDatabase { db -> [String: Int] in
            try db.conn.withTemporaryStatement("""
                SELECT f.path, (SELECT count(*) FROM request_occurrence o WHERE o.file_ref = f.file_ref)
                FROM source_file f WHERE f.parsed_bytes IS NOT NULL
                """) { s in
                var out: [String: Int] = [:]
                while try s.step() { out[s.text(0) ?? ""] = Int(s.int64(1)) }
                return out
            }
        }
        XCTAssertFalse(watermarked.isEmpty, "some files were complete before the shutdown")
        XCTAssertLessThan(watermarked.count, 60, "and some were not")
        for (path, occurrences) in watermarked { XCTAssertEqual(occurrences, 50, path) }
        let unclean = try await reopened.withDatabase { $0.openedAfterUncleanShutdown }
        XCTAssertFalse(unclean)

        try await reopened.applyScanCommand(scan(2, files: 60, perFile: 50))
        let got = try await reopened.logicalDump()
        let reference = hmStore(historyTempDirectory("reference"))
        try await reference.applyScanCommand(scan(1, files: 60, perFile: 50))
        let want = try await reference.logicalDump()
        XCTAssertEqual(got, want, hmDiff(got, want))
    }

    func testSubmissionsAfterShutdownAreDroppedAndCountedAndNeverReopenTheFile() async throws {
        let dir = historyTempDirectory()
        let store = hmStore(dir)
        try await store.applyQuotaCommand([quotaRow(1)])
        await store.shutdown()
        let attempts = await store.statistics().openAttempts
        store.submit(quota: [quotaRow(2)])
        store.submit(scan: scan(1, files: 1, perFile: 3))
        store.submit(legacyQuota: [])
        store.submit(resetGrants: [], recordedMs: t0)
        store.enqueue { store in _ = try store.guarded { try $0.userVersion() } }
        await store.flush()
        await store.shutdown()                                    // idempotent
        let stats = await store.statistics()
        XCTAssertEqual(stats.droppedSubmissions, 4)
        XCTAssertEqual(stats.failedCommands, 1, "a custom command that needs the database fails")
        XCTAssertEqual(stats.openAttempts, attempts, "nothing reopened the file")
        do {
            _ = try await store.logicalDump()
            XCTFail("a read after shutdown must not reopen the database")
        } catch HistoryStoreError.closed {}
        XCTAssertEqual(historyWalBytes(dir), 0)
    }

    /// The deadline is what keeps a quit from hanging: a store whose queue is
    /// blocked (an fsync that takes seconds) does not hold the reply.
    func testAShutdownStuckBehindABlockedQueueReturnsAtTheDeadline() async throws {
        let store = hmStore(historyTempDirectory())
        let blocking = OSAllocatedUnfairLock(initialState: false)
        store.enqueue { _ in
            blocking.withLock { $0 = true }
            usleep(600_000)                                      // holds the store's executor
        }
        for _ in 0..<2_000 where !blocking.withLock({ $0 }) { try await Task.sleep(nanoseconds: 1_000_000) }
        let began = ContinuousClock.now
        let inTime = await QuitSequence.run({ await store.shutdown() }, deadline: .milliseconds(100))
        let took = ContinuousClock.now - began
        XCTAssertFalse(inTime)
        XCTAssertLessThan(took, .milliseconds(450), "returned at the deadline, not when the queue freed up")
        await store.flush()
        let shut = await store.isShutDown
        XCTAssertTrue(shut, "the shutdown still ran once the queue was free")
    }

    // MARK: A file this process may not write

    /// Restored from a backup as 0444, or created by a root-run build: SQLite
    /// opens it read-only without an error. It used to report `.ready` while
    /// every write failed for the life of the process.
    func testAWriteProtectedFileIsUnavailableAndRecoversAfterTheRetryInterval() async throws {
        let dir = historyTempDirectory()
        let first = hmStore(dir)
        try await first.applyQuotaCommand([quotaRow(1)])
        await first.close()
        let file = dir.appendingPathComponent(HistoryDatabase.fileName).path
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file) }

        let clock = HistoryRetryClock()
        let store = HistoryStore(directory: dir, timeZone: hmTokyo, retryClock: { clock.now() })
        let status = await store.status()
        guard case let .unavailable(reason) = status else { return XCTFail("\(status)") }
        XCTAssertTrue(reason.contains("code=8"), reason)          // SQLITE_READONLY
        store.submit(quota: [quotaRow(2)])
        await store.flush()
        var stats = await store.statistics()
        XCTAssertEqual(stats.droppedSubmissions, 1)
        XCTAssertEqual(stats.failedChunks + stats.failedCommands, 0, "nothing was attempted on the read-only handle")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        let latched = await store.status()
        XCTAssertNotEqual(latched, .ready, "inside the retry interval the latch answers without touching the disk")
        let attempts = await store.statistics().openAttempts
        XCTAssertEqual(attempts, 1)
        clock.advance(HistoryStore.defaultLockRetryInterval + .seconds(1))
        let healed = await store.status()
        XCTAssertEqual(healed, .ready)
        store.submit(quota: [quotaRow(3)])
        await store.flush()
        stats = await store.statistics()
        XCTAssertEqual(stats.appliedCommands, 1)
        let rows = try await count(store, "quota_sample")
        XCTAssertEqual(rows, 2, "the row from before and the one after the fix; the dropped one is gone")
    }

    /// A write that answers `SQLITE_READONLY` on an open handle (the file was
    /// deleted or moved under it) closes the handle and latches a retry, so the
    /// store does not keep failing every write until the app restarts.
    func testAReadOnlyErrorOnAnOpenHandleClosesItAndTheStoreRecoversAfterTheInterval() async throws {
        let dir = historyTempDirectory()
        let clock = HistoryRetryClock()
        let store = HistoryStore(directory: dir, timeZone: hmTokyo, retryClock: { clock.now() })
        try await store.applyQuotaCommand([quotaRow(1)])
        store.enqueue { store in
            try store.guarded { _ -> Void in
                throw SQLiteError(code: SQLITE_READONLY, extendedCode: 1032, message: "moved", context: "step")
            }
        }
        store.submit(quota: [quotaRow(2)])
        await store.flush()
        let stats = await store.statistics()
        XCTAssertEqual(stats.failedCommands, 1)
        XCTAssertEqual(stats.droppedSubmissions, 1, "closed and latched: the next command is dropped, not failed")
        let status = await store.status()
        guard case let .unavailable(reason) = status else { return XCTFail("\(status)") }
        XCTAssertTrue(reason.contains("code=8"), reason)
        clock.advance(HistoryStore.defaultLockRetryInterval + .seconds(1))
        let healed = await store.status()
        XCTAssertEqual(healed, .ready)
        let attempts = await store.statistics().openAttempts
        XCTAssertEqual(attempts, 2)
    }

    /// The real case behind it: the database deleted while the app runs (a
    /// manual reset). The next write must not land in an unlinked file.
    func testADatabaseDeletedUnderTheStoreIsRecreatedAfterTheRetryInterval() async throws {
        let dir = historyTempDirectory()
        let clock = HistoryRetryClock()
        let store = HistoryStore(directory: dir, timeZone: hmTokyo, retryClock: { clock.now() })
        try await store.applyQuotaCommand([quotaRow(1)])
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(HistoryDatabase.fileName).path + suffix)
        }
        store.submit(quota: [quotaRow(2)])
        await store.flush()
        clock.advance(HistoryStore.defaultLockRetryInterval + .seconds(1))
        store.submit(quota: [quotaRow(3)])
        await store.flush()
        let status = await store.status()
        XCTAssertEqual(status, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL.path), "a fresh file at the path")
        let rows = try await count(store, "quota_sample")
        XCTAssertEqual(rows, 1, "the reading after the reopen landed in the file on disk")
    }

    // MARK: Lock and directory failures

    func testLockFailuresAreClassifiedByErrno() {
        func check(_ step: HistoryLockStep, _ code: Int32, _ expected: String) {
            XCTAssertEqual(HistoryProcessLock.failure(step, errno: code).description, expected, "\(step) \(code)")
        }
        check(.flock, EWOULDBLOCK, "lockedByAnotherInstance")
        check(.flock, EAGAIN, "lockedByAnotherInstance")
        check(.lockFile, ENOSPC, "lockUnavailable(lockFile: ENOSPC, transient)")
        check(.lockFile, EMFILE, "lockUnavailable(lockFile: EMFILE, transient)")
        check(.lockFile, ENFILE, "lockUnavailable(lockFile: ENFILE, transient)")
        check(.flock, EINTR, "lockUnavailable(flock: EINTR, transient)")
        check(.directory, ENOSPC, "lockUnavailable(directory: ENOSPC, transient)")
        check(.flock, ENOTSUP, "lockUnavailable(flock: ENOTSUP, the volume does not support flock)")
        check(.flock, EOPNOTSUPP, "lockUnavailable(flock: EOPNOTSUPP, the volume does not support flock)")
        check(.lockFile, EACCES, "lockUnavailable(lockFile: EACCES)")
        check(.directory, ENOTDIR, "lockUnavailable(directory: ENOTDIR)")
        check(.lockFile, 0, "lockUnavailable(lockFile: errno 0)")
        // Only another holder is reported as one.
        XCTAssertEqual(HistoryProcessLock.failure(.lockFile, errno: EWOULDBLOCK).description,
                       "lockUnavailable(lockFile: errno \(EWOULDBLOCK))")
    }

    /// A directory that cannot be created (a file in its place) is an
    /// environment problem, not a property of the database: it used to latch
    /// the history off until the app restarted.
    func testADirectoryThatCannotBeCreatedIsRetriedAndRecoversOnceItCan() async throws {
        let root = historyTempDirectory()
        let blocker = root.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let clock = HistoryRetryClock()
        let store = HistoryStore(directory: blocker.appendingPathComponent("AgentMeter", isDirectory: true),
                                 timeZone: hmTokyo, retryClock: { clock.now() })
        let first = await store.status()
        XCTAssertEqual(first, .unavailable(reason: "lockUnavailable(directory: ENOTDIR)"))
        clock.advance(.seconds(30))
        _ = await store.status()
        let attempts = await store.statistics().openAttempts
        XCTAssertEqual(attempts, 1, "within the interval: no new attempt")
        try FileManager.default.removeItem(at: blocker)
        clock.advance(.seconds(31))
        let healed = await store.status()
        XCTAssertEqual(healed, .ready)
    }

    // MARK: Quarantine retention when the clock moves

    /// Three quarantines stamped by a clock that ran ahead, then the clock is
    /// corrected: the next quarantine used to sort OLDEST by its name stamp
    /// and be deleted in the call that created it, leaving `.rebuilt` pointing
    /// at nothing. The retention orders by the sequence number instead.
    func testQuarantineRetentionFollowsTheSequenceNotTheClock() throws {
        let dir = historyTempDirectory()
        let clock = HMClock()
        var config = historyConfig(dir)
        config.maxQuarantined = 3
        config.clock = { clock.get() }
        func quarantineGarbage(_ text: String) throws -> URL? {
            try Data(String(repeating: text + " ", count: 40).utf8).write(to: config.url)
            let db = try HistoryDatabase.open(config)
            defer { db.close() }
            return db.recovery?.quarantinedTo
        }
        clock.set(Date(timeIntervalSince1970: 1_830_000_000))          // ran ahead
        var future: [String] = []
        for round in 0..<3 {
            clock.advance(60)
            future.append(try XCTUnwrap(try quarantineGarbage("garbage \(round)")).lastPathComponent)
        }
        clock.set(Date(timeIntervalSince1970: 1_800_000_000))          // corrected: earlier than every stamp
        let precious = try XCTUnwrap(try quarantineGarbage("precious"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path), "the file .rebuilt points at still exists")
        var kept = historyQuarantined(in: dir).filter { $0.hasSuffix(".sqlite") }
        XCTAssertEqual(Set(kept), Set([future[1], future[2], precious.lastPathComponent]), "\(kept)")
        XCTAssertEqual(try Data(contentsOf: precious), Data(String(repeating: "precious ", count: 40).utf8))

        clock.advance(60)
        let later = try XCTUnwrap(try quarantineGarbage("later"))
        kept = historyQuarantined(in: dir).filter { $0.hasSuffix(".sqlite") }
        XCTAssertEqual(Set(kept), Set([future[2], precious.lastPathComponent, later.lastPathComponent]),
                       "the oldest by sequence goes, whatever its stamp says: \(kept)")
    }

    func testTheFileJustMovedIsKeptEvenWhenNoneShouldBe() throws {
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.maxQuarantined = 0
        for round in 0..<2 {
            try Data(String(repeating: "garbage \(round) ", count: 40).utf8).write(to: config.url)
            let db = try HistoryDatabase.open(config)
            let moved = try XCTUnwrap(db.recovery?.quarantinedTo)
            db.close()
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
            XCTAssertEqual(historyQuarantined(in: dir).filter { $0.hasSuffix(".sqlite") }, [moved.lastPathComponent])
        }
    }

    // MARK: The accounting zone

    /// Observations around Tokyo and Los Angeles midnights, so the two zones
    /// give different days.
    func zoneScan(_ ticket: UInt64, path: String = "/p/proj/zone.jsonl", keys: Range<Int> = 0..<40) -> HistoryScanBatch {
        let mids = [hmMidnight(hmTokyo, 2026, 9, 1), hmMidnight(hmLosAngeles, 2026, 9, 1), hmMidnight(hmTokyo, 2026, 9, 2)]
        let obs = keys.map { n -> RequestObservation in
            let t = mids[n % 3] + Int64((n / 3) % 5 - 2) * 900_000 - 1
            return hmObs(hmKey(n), [hmPart(output: 1 + n)], .final, first: t, last: t, final: t)
        }
        return hmScan(ticket, [hmFile(path, scan: ticket, obs)])
    }

    func freshDump(_ scans: [HistoryScanBatch], zone: TimeZone) async throws -> HistoryLogicalDump {
        let store = hmStore(historyTempDirectory("fresh"), timeZone: zone)
        for s in scans { try await store.applyScanCommand(s) }
        return try await store.logicalDump()
    }

    /// A launch in another zone: a reader that comes before the first write
    /// must already see the new zone's days (it used to see the old zone's
    /// until some write ran the recompute).
    func testAReadBeforeAnyWriteAfterALaunchInAnotherZoneSeesTheNewZonesDays() async throws {
        let dir = historyTempDirectory()
        let tokyo = hmStore(dir, timeZone: hmTokyo)
        try await tokyo.applyScanCommand(zoneScan(1))
        let tokyoDump = try await tokyo.logicalDump()
        await tokyo.close()

        let la = hmStore(dir, timeZone: hmLosAngeles)
        let beforeAnyWrite = try await la.logicalDump()
        let want = try await freshDump([zoneScan(1)], zone: hmLosAngeles)
        XCTAssertNotEqual(tokyoDump, want, "precondition: the zones give different days")
        XCTAssertEqual(beforeAnyWrite, want, hmDiff(beforeAnyWrite, want))
        let days = try await la.dayModelUsage().map(\.acctDay)
        XCTAssertEqual(Set(days), Set(want.requests.map(\.acctDay)))
    }

    /// The system zone changes while the app runs: the next scan command of
    /// the same store recomputes every day (as the usage ledger's
    /// `Calendar.current` does), and so does the next read.
    func testAZoneChangeBetweenTwoScanCommandsOfOneStoreRecomputesEveryDay() async throws {
        let zone = HistoryZoneBox(hmTokyo)
        let store = HistoryStore(directory: historyTempDirectory(), timeZone: hmTokyo,
                                 configure: { $0.birthTime = { _ in nil } }, timeZoneSource: { zone.get() })
        let first = zoneScan(1, keys: 0..<30)
        try await store.applyScanCommand(first)
        zone.set(hmLosAngeles)
        let second = zoneScan(2, path: "/p/proj/zone2.jsonl", keys: 30..<40)
        try await store.applyScanCommand(second)
        let got = try await store.logicalDump()
        let want = try await freshDump([first, second], zone: hmLosAngeles)
        XCTAssertEqual(got, want, hmDiff(got, want))
        let stored = try await store.withDatabase { try $0.metaText("acct_tz") }
        XCTAssertEqual(stored, hmLosAngeles.identifier)
        XCTAssertEqual(store.timeZone.identifier, hmLosAngeles.identifier)

        zone.set(hmTokyo)
        let readOnly = try await store.logicalDump()
        let back = try await freshDump([first, second], zone: hmTokyo)
        XCTAssertEqual(readOnly, back, "a read after the zone moved back sees Tokyo days: \(hmDiff(readOnly, back))")
    }

    // MARK: What it logs

    func testOneLinePerStateChangeNothingPerScanAndNoPaths() async throws {
        let dir = historyTempDirectory()
        let lines = HistoryOrderLog()
        let store = HistoryStore(directory: dir, timeZone: hmTokyo, log: { lines.add($0) })
        for ticket in 1...20 { store.submit(scan: scan(UInt64(ticket), files: 2, perFile: 5)) }
        store.submit(quota: [quotaRow(1)])
        await store.flush()
        XCTAssertEqual(lines.all, ["opened (schema \(HistorySchema.migrations.count), clean)"], "nothing per scan")
        await store.shutdown()
        XCTAssertEqual(lines.all.count, 2)
        XCTAssertTrue(lines.all[1].hasPrefix("closed for quit (database closed"), lines.all[1])
        for line in lines.all { XCTAssertFalse(line.contains("/"), line) }
    }

    func testASecondInstanceIsLoggedOnceAndTheTakeoverOnce() async throws {
        let dir = historyTempDirectory()
        let holder = try HistoryDatabase.open(historyConfig(dir))
        let lines = HistoryOrderLog()
        let clock = HistoryRetryClock()
        let store = HistoryStore(directory: dir, timeZone: hmTokyo, retryClock: { clock.now() }, log: { lines.add($0) })
        for _ in 0..<5 {
            _ = await store.status()
            clock.advance(.seconds(61))
        }
        let attempts = await store.statistics().openAttempts
        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(lines.all, ["unavailable, retrying after 60.0 seconds: lockedByAnotherInstance"])
        holder.close()
        let status = await store.status()
        XCTAssertEqual(status, .ready)
        XCTAssertEqual(lines.all.last, "opened (schema \(HistorySchema.migrations.count), clean)")
        XCTAssertEqual(lines.all.count, 2)
    }

    func testDroppedSubmissionsAreLoggedTheFirstTimeAndThenEveryHundredth() async throws {
        let dir = historyTempDirectory()
        let db = try HistoryDatabase.open(historyConfig(dir))
        try db.conn.setPragma("user_version", "99")
        db.close()
        let lines = HistoryOrderLog()
        let store = HistoryStore(directory: dir, timeZone: hmTokyo, log: { lines.add($0) })
        for i in 0..<250 { store.submit(quota: [quotaRow(i)]) }
        await store.flush()
        let dropped = await store.statistics().droppedSubmissions
        XCTAssertEqual(dropped, 250)
        let supported = HistorySchema.migrations.count
        XCTAssertEqual(lines.all, [
            "unavailable for the rest of this process: schemaTooNew(found=99, supported=\(supported))",
            "dropped 1 submission(s) so far, store unavailable: schemaTooNew(found=99, supported=\(supported))",
            "dropped 100 submission(s) so far, store unavailable: schemaTooNew(found=99, supported=\(supported))",
            "dropped 200 submission(s) so far, store unavailable: schemaTooNew(found=99, supported=\(supported))",
        ])
    }

    func testAQuarantineIsLoggedByFileNameOnly() async throws {
        let dir = historyTempDirectory()
        try Data(repeating: 0x42, count: 8_192).write(to: dir.appendingPathComponent(HistoryDatabase.fileName))
        let lines = HistoryOrderLog()
        let store = HistoryStore(directory: dir, timeZone: hmTokyo, log: { lines.add($0) })
        let status = await store.status()
        guard case let .rebuilt(path) = status else { return XCTFail("\(status)") }
        let name = URL(fileURLWithPath: path).lastPathComponent
        XCTAssertEqual(lines.all.count, 2, "\(lines.all)")
        XCTAssertEqual(lines.all.last, "the database was damaged at open: quarantined as \(name), rebuilt empty")
        for line in lines.all { XCTAssertFalse(line.contains(dir.path), line) }
    }
}

/// The quit path of `AppDelegate`, without AppKit's run loop: always
/// `.terminateLater`, exactly one reply, never a hang.
@MainActor
final class QuitSequenceTests: XCTestCase {
    final class Probe: Sendable {
        private let counts = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
        func hit(_ name: String) { counts.withLock { $0[name, default: 0] += 1 } }
        func count(_ name: String) -> Int { counts.withLock { $0[name] ?? 0 } }
    }

    func waitFor(_ probe: Probe, _ name: String, count: Int, within seconds: Double = 5) async throws {
        let end = Date().addingTimeInterval(seconds)
        while probe.count(name) < count && Date() < end { try await Task.sleep(nanoseconds: 2_000_000) }
    }

    func testTheReplyComesOnceAfterTheStoreClosedAndASecondQuitStartsNothing() async throws {
        let probe = Probe()
        let quit = QuitSequence(deadline: .seconds(5), stopRefreshing: { probe.hit("stop") },
                                closeHistory: { probe.hit("close") })
        XCTAssertEqual(quit.begin { probe.hit("reply") }, .terminateLater)
        XCTAssertEqual(probe.count("stop"), 1, "the refresh stops before anything else")
        XCTAssertEqual(quit.begin { probe.hit("second reply") }, .terminateLater)
        try await waitFor(probe, "reply", count: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(probe.count("reply"), 1)
        XCTAssertEqual(probe.count("second reply"), 0)
        XCTAssertEqual(probe.count("close"), 1)
        XCTAssertEqual(probe.count("stop"), 2)
    }

    func testTheReplyComesAtTheDeadlineWhenTheStoreNeverCloses() async throws {
        let probe = Probe()
        let never = HistoryAsyncGate()
        let quit = QuitSequence(deadline: .milliseconds(100), stopRefreshing: {},
                                closeHistory: { await never.wait() })
        let began = ContinuousClock.now
        XCTAssertEqual(quit.begin { probe.hit("reply") }, .terminateLater)
        try await waitFor(probe, "reply", count: 1)
        XCTAssertEqual(probe.count("reply"), 1)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.count("reply"), 1, "exactly once, also on the timeout path")
        await never.open()
    }

    /// What AppKit does after `.terminateLater`: it spins the main run loop in
    /// `NSModalPanelRunLoopMode` inside `terminate(_:)`. When the quit came
    /// from a MainActor task (this async test body is one), the main dispatch
    /// queue cannot run until that returns, so a reply sent through the
    /// MainActor or `DispatchQueue.main` would never arrive and the quit would
    /// hang. The reply must come through the run loop itself.
    func testTheReplyArrivesWhileTheMainThreadWaitsInAppKitsModalRunLoop() async throws {
        let probe = Probe()
        let quit = QuitSequence(deadline: .seconds(5), stopRefreshing: {}, closeHistory: { probe.hit("close") })
        XCTAssertEqual(quit.begin { probe.hit("reply") }, .terminateLater)
        spinModalRunLoop(seconds: 3) { probe.count("reply") > 0 }
        XCTAssertEqual(probe.count("reply"), 1, "the reply reached the main thread inside the modal wait")
        XCTAssertEqual(probe.count("close"), 1)
    }

    /// Work that never suspends (a long synchronous parse) can hold every
    /// thread of the cooperative pool's default-QoS bucket, the one an
    /// unprioritised `Task.detached` runs in. A deadline reply that first has
    /// to resume on the pool then comes only when one frees up, however long
    /// after the deadline that is.
    func testTheDeadlineReplyComesWhileTheCooperativePoolIsSaturated() {
        let probe = Probe()
        let never = HistoryAsyncGate()
        let quit = QuitSequence(deadline: .milliseconds(100), stopRefreshing: {}, closeHistory: { await never.wait() })
        let began = ContinuousClock.now
        XCTAssertEqual(quit.begin { probe.hit("reply") }, .terminateLater)
        let width = ProcessInfo.processInfo.activeProcessorCount
        for _ in 0..<width {
            Task.detached { usleep(1_000_000); probe.hit("held") }
        }
        spinModalRunLoop(seconds: 5) { probe.count("reply") > 0 }
        let took = ContinuousClock.now - began
        XCTAssertEqual(probe.count("reply"), 1)
        XCTAssertLessThan(took, .milliseconds(600), "the deadline reply waited for a cooperative-pool thread")
        spinModalRunLoop(seconds: 5) { probe.count("held") == width }
        Task.detached { await never.open() }
    }

    /// The same with the pool held at a higher QoS by work that keeps its CPU
    /// busy, as tasks started from the MainActor (the Claude scan) run. A
    /// thread for a global (non-overcommit) queue at or below that QoS can be
    /// held back while as many threads as there are CPUs run there, so a
    /// deadline timer on `DispatchQueue.global` waited for them too.
    func testTheDeadlineReplyComesWhileThePoolIsBusyAtAHigherQoS() {
        let probe = Probe()
        let never = HistoryAsyncGate()
        let quit = QuitSequence(deadline: .milliseconds(100), stopRefreshing: {}, closeHistory: { await never.wait() })
        let stop = OSAllocatedUnfairLock(initialState: false)
        let width = ProcessInfo.processInfo.activeProcessorCount
        for _ in 0..<width {
            Task.detached(priority: .high) {
                probe.hit("spinning")
                let end = ContinuousClock.now + .seconds(1)
                while !stop.withLock({ $0 }) && ContinuousClock.now < end {}
                probe.hit("spun")
            }
        }
        spinModalRunLoop(seconds: 2) { probe.count("spinning") == width }
        let began = ContinuousClock.now
        XCTAssertEqual(quit.begin { probe.hit("reply") }, .terminateLater)
        spinModalRunLoop(seconds: 5) { probe.count("reply") > 0 }
        let took = ContinuousClock.now - began
        stop.withLock { $0 = true }
        XCTAssertEqual(probe.count("reply"), 1)
        XCTAssertLessThan(took, .milliseconds(600), "the deadline reply waited for the busy pool")
        spinModalRunLoop(seconds: 5) { probe.count("spun") == width }
        Task.detached { await never.open() }
    }

    /// Synchronous on purpose: the nested run loop must run inside the
    /// current main-queue job, as AppKit's does.
    func spinModalRunLoop(seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02))
        }
    }

    func testTheDeadlineIsShortEnoughForAQuit() {
        XCTAssertLessThanOrEqual(QuitSequence.historyDeadline, .milliseconds(1_500))
    }
}
