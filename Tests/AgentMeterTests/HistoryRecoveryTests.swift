import Foundation
import os
import SQLite3
import XCTest
@testable import AgentMeter

/// What happens to a damaged, truncated, foreign or half-written
/// `history.sqlite`: quarantine and rebuild, never a crash, never a loop, and
/// never touching a file this process does not hold the lock for.
final class HistoryRecoveryTests: XCTestCase {
    // MARK: Helpers

    /// A closed ~1 MB database (the last close checkpoints the WAL into the main file).
    private func makePopulated(rows: Int = 12_000, in dir: URL) throws -> HistoryDatabaseConfiguration {
        let config = historyConfig(dir)
        let db = try HistoryDatabase.open(config)
        try historyPopulate(db, rows: rows)
        db.close()
        return config
    }

    private func overwrite(_ url: URL, at offset: Int, with bytes: [UInt8]) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data(bytes))
    }

    private func fileSize(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
    }

    private func assertFreshWorkingDatabase(_ db: HistoryDatabase, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try db.userVersion(), HistorySchema.migrations.count, file: file, line: line)
        XCTAssertEqual(try historyDictCount(db), 0, file: file, line: line)
        try db.conn.exec("INSERT INTO dict(kind, value) VALUES (1, 'after the rebuild')")
        XCTAssertEqual(try historyDictCount(db), 1, file: file, line: line)
        XCTAssertEqual(try db.runIntegrityCheck(), ["ok"], file: file, line: line)
    }

    /// Copies db + `-wal` + `-shm` while the writer is still open: what the next launch finds after a crash.
    private func crashImage(of config: HistoryDatabaseConfiguration) throws -> URL {
        let image = historyTempDirectory("image")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.copyItem(
                atPath: config.url.path + suffix,
                toPath: image.appendingPathComponent(HistoryDatabase.fileName + suffix).path)
        }
        return image
    }

    // MARK: Garbage and empty files

    func testGarbageFilesOfSeveralSizesAreQuarantinedAndReplaced() throws {
        let pattern = try NSRegularExpression(pattern: #"^history\.corrupt-\d{8}T\d{6}Z(-\d+)?\.sqlite$"#)
        for size in [1, 50, 99, 100, 511, 600, 4096, 100_000] {
            let dir = historyTempDirectory("garbage\(size)")
            let url = dir.appendingPathComponent(HistoryDatabase.fileName)
            var rng = HistorySplitMix64(seed: UInt64(size))
            let junk = Data((0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            try junk.write(to: url)
            let db = try HistoryDatabase.open(historyConfig(dir))
            if let report = db.recovery {
                let moved = try XCTUnwrap(report.quarantinedTo)
                XCTAssertEqual(try Data(contentsOf: moved), junk, "the quarantined file holds the original bytes (\(size))")
                let name = moved.lastPathComponent
                XCTAssertNotNil(pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), name)
            } else {
                // SQLite treats a file shorter than a page header as an empty database and overwrites it;
                // nothing worth keeping.
                XCTAssertLessThan(size, 512, "only a sub-page file may be silently accepted")
            }
            try assertFreshWorkingDatabase(db)
            db.close()
        }
    }

    func testAZeroByteFileIsJustAnEmptyDatabase() throws {
        let dir = historyTempDirectory()
        let config = historyConfig(dir)
        FileManager.default.createFile(atPath: config.url.path, contents: Data())
        let db = try HistoryDatabase.open(config)
        XCTAssertNil(db.recovery, "nothing to quarantine: SQLite treats 0 bytes as a new database")
        XCTAssertEqual(historyQuarantined(in: dir), [])
        try assertFreshWorkingDatabase(db)
    }

    // MARK: Truncated files

    /// A truncated file fails the VERY FIRST statement (`PRAGMA user_version`
    /// included: the header's page count exceeds the file), so no `quick_check`
    /// at open is needed to catch it.
    func testTruncatedFilesAreCaughtAtOpenWithoutAQuickCheck() throws {
        for (label, keep) in [("100 bytes", 100), ("one page", 4096), ("40% page-aligned", 0), ("60% mid-page", -1)] {
            let dir = historyTempDirectory("truncated")
            let config = try makePopulated(in: dir)
            let size = try fileSize(config.url)
            let newSize = keep > 0 ? keep : (keep == 0 ? (size * 4 / 10) / 4096 * 4096 : size * 6 / 10 + 123)
            let handle = try FileHandle(forUpdating: config.url)
            try handle.truncate(atOffset: UInt64(newSize))
            try handle.close()
            let db = try HistoryDatabase.open(config)
            XCTAssertNotNil(db.recovery, "\(label): the open must flag it")
            XCTAssertEqual(historyQuarantined(in: dir).filter { $0.hasSuffix(".sqlite") }.count, 1, label)
            try assertFreshWorkingDatabase(db)
            db.close()
        }
    }

    // MARK: Damage that only shows later

    /// No quick_check at open: a smashed page in the middle is noticed by the
    /// first read that touches it, and the store rebuilds from there.
    func testLazilyDetectedCorruptionIsRebuiltByTheStore() async throws {
        let dir = historyTempDirectory()
        let config = try makePopulated(in: dir)
        let pages = try fileSize(config.url) / 4096
        // The schema is 16 tables and 3 indexes, so sqlite_master and the root pages take
        // the first ~40 pages; smash row pages only, which open never reads.
        for page in stride(from: 40, to: pages, by: 2) { try overwrite(config.url, at: page * 4096, with: [0xFF]) }

        let store = HistoryStore(directory: dir)
        let beforeStatus = await store.status()
        XCTAssertEqual(beforeStatus, .ready, "open reads page 1 and the schema only, so it cannot notice")
        do {
            _ = try await store.withDatabase { try historyDictCount($0) }
            XCTFail("expected the corruption to surface")
        } catch HistoryStoreError.rebuilt(let moved) {
            XCTAssertNotNil(moved)
        }
        let afterStatus = await store.status()
        guard case let .rebuilt(path) = afterStatus else { return XCTFail("\(afterStatus)") }
        XCTAssertTrue(path.hasPrefix(dir.path), path)
        let rows = try await store.withDatabase { try historyDictCount($0) }
        XCTAssertEqual(rows, 0, "an empty database, writable again")
        XCTAssertEqual(historyQuarantined(in: dir).filter { $0.hasSuffix(".sqlite") }.count, 1)
        let stats = await store.statistics()
        XCTAssertEqual(stats.rebuilds, 1)
        try await store.withDatabase { try $0.conn.exec("INSERT INTO dict(kind, value) VALUES (1, 'x')") }
    }

    func testAPageHeaderSmashIsFoundByTheIntegrityCheckNotByOpen() throws {
        let dir = historyTempDirectory()
        let config = try makePopulated(in: dir)
        let pages = try fileSize(config.url) / 4096
        try overwrite(config.url, at: (pages / 2) * 4096, with: [0xFF, 0xFF, 0xFF, 0xFF])
        let db = try HistoryDatabase.open(config)
        XCTAssertNil(db.recovery, "open does not run a check")
        let result = try db.runIntegrityCheck()
        XCTAssertNotEqual(result, ["ok"], "\(result)")
        db.close()
    }

    func testTheIntegrityCheckRunsOnItsOwnReaderWhileTheWriterHoldsAnOpenTransaction() throws {
        let dir = historyTempDirectory()
        let db = try HistoryDatabase.open(historyConfig(dir))
        try historyPopulate(db, rows: 3_000)
        try db.conn.exec("BEGIN IMMEDIATE")
        try db.conn.exec("INSERT INTO dict(kind, value) VALUES (9, 'uncommitted')")
        XCTAssertEqual(try db.runIntegrityCheck(), ["ok"], "a WAL reader neither waits for the writer nor sees its rows")
        try db.conn.exec("ROLLBACK")
        XCTAssertEqual(try historyDictCount(db), 3_000)
        db.close()
    }

    // MARK: Crashed writers and stray WAL files

    func testACrashImageWithCommittedWalFramesIsRecoveredAndFlaggedUnclean() throws {
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.options.walAutocheckpointPages = 0
        let db = try HistoryDatabase.open(config)
        try historyPopulate(db, rows: 3_000)
        XCTAssertGreaterThan(db.walSizeBytes(), 100_000, "the frames are in the WAL, not in the main file")
        let image = try crashImage(of: config)
        db.close()

        let recovered = try HistoryDatabase.open(historyConfig(image))
        XCTAssertNil(recovered.recovery, "a leftover WAL is normal recovery, not corruption")
        XCTAssertTrue(recovered.openedAfterUncleanShutdown, "a non-empty -wal at open is the unclean-shutdown signal")
        XCTAssertEqual(try historyDictCount(recovered), 3_000)
        XCTAssertEqual(try recovered.runIntegrityCheck(), ["ok"])
        recovered.close()
        let clean = try HistoryDatabase.open(historyConfig(image))
        XCTAssertFalse(clean.openedAfterUncleanShutdown, "a clean close truncates the WAL to 0 bytes")
    }

    func testAGarbageWalBesideAValidDatabaseIsIgnored() throws {
        let dir = historyTempDirectory()
        let config = try makePopulated(rows: 2_000, in: dir)
        var rng = HistorySplitMix64(seed: 3)
        try Data((0..<30_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            .write(to: URL(fileURLWithPath: config.url.path + "-wal"))
        let db = try HistoryDatabase.open(config)
        XCTAssertNil(db.recovery)
        XCTAssertEqual(try historyDictCount(db), 2_000)
        XCTAssertEqual(try db.runIntegrityCheck(), ["ok"])
    }

    func testATornWalKeepsTheCommittedPrefix() throws {
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.options.walAutocheckpointPages = 0
        let db = try HistoryDatabase.open(config)
        for batch in 0..<10 { try historyPopulate(db, rows: 500, seed: UInt64(batch + 1)) }     // ten commits
        let image = try crashImage(of: config)
        db.close()
        let wal = image.appendingPathComponent(HistoryDatabase.fileName + "-wal")
        let handle = try FileHandle(forUpdating: wal)
        try handle.truncate(atOffset: UInt64(try fileSize(wal) * 7 / 10))
        try handle.close()
        try? FileManager.default.removeItem(at: image.appendingPathComponent(HistoryDatabase.fileName + "-shm"))
        let recovered = try HistoryDatabase.open(historyConfig(image))
        let rows = try historyDictCount(recovered)
        XCTAssertNil(recovered.recovery)
        XCTAssertEqual(rows % 500, 0, "frames are checksummed: only whole commits are visible")
        XCTAssertGreaterThan(rows, 0); XCTAssertLessThan(rows, 5_000)
        XCTAssertEqual(try recovered.runIntegrityCheck(), ["ok"])
    }

    /// SQLite ignores a stale WAL next to a missing or zero-byte main file (the
    /// new file has no WAL header). Deleting only the main file is therefore
    /// safe; the dangerous direction is an older main file next to a newer WAL,
    /// which is why quarantine moves all of them together.
    func testAStaleWalBesideAMissingOrEmptyMainFileIsNotReplayed() throws {
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.options.walAutocheckpointPages = 0
        let live = try HistoryDatabase.open(config)
        try historyPopulate(live, rows: 1_000)
        let image = try crashImage(of: config)
        live.close()
        for variant in ["missing", "zero-byte"] {
            let target = historyTempDirectory("stale-\(variant)")
            for suffix in ["-wal", "-shm"] {
                try FileManager.default.copyItem(
                    atPath: image.appendingPathComponent(HistoryDatabase.fileName + suffix).path,
                    toPath: target.appendingPathComponent(HistoryDatabase.fileName + suffix).path)
            }
            if variant == "zero-byte" { FileManager.default.createFile(atPath: target.appendingPathComponent(HistoryDatabase.fileName).path, contents: Data()) }
            let db = try HistoryDatabase.open(historyConfig(target))
            XCTAssertNil(db.recovery)
            XCTAssertEqual(try historyDictCount(db), 0, "\(variant): stale frames must not leak into the new database")
            XCTAssertEqual(try db.runIntegrityCheck(), ["ok"])
            db.close()
        }
    }

    // MARK: Quarantine bookkeeping

    func testQuarantineMovesAllSidecarsAndKeepsTheNewestFew() throws {
        let dir = historyTempDirectory()
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        var config = historyConfig(dir)
        config.maxQuarantined = 2
        config.clock = { Date(timeIntervalSince1970: 1_800_000_000 + Double(ticks.withLock { $0 += 60; return $0 })) }
        for round in 0..<4 {
            try Data(String(repeating: "garbage \(round) ", count: 20).utf8).write(to: config.url)
            try Data("wal \(round)".utf8).write(to: URL(fileURLWithPath: config.url.path + "-wal"))
            try Data("shm \(round)".utf8).write(to: URL(fileURLWithPath: config.url.path + "-shm"))
            let db = try HistoryDatabase.open(config)
            XCTAssertNotNil(db.recovery)
            db.close()
        }
        let kept = historyQuarantined(in: dir)
        XCTAssertEqual(kept.filter { $0.hasSuffix(".sqlite") }.count, 2, "\(kept)")
        let newest = try XCTUnwrap(kept.filter { $0.hasSuffix(".sqlite") }.last)
        // Moved next to their main file. (Their bytes are not asserted: the failed open of a
        // garbage file may already have truncated a stray -wal, which costs nothing.)
        XCTAssertTrue(kept.contains(newest + "-wal"), "\(kept)")
        XCTAssertTrue(kept.contains(newest + "-shm"), "\(kept)")
        XCTAssertEqual(kept.filter { $0.hasSuffix("-wal") }.count, 2, "a pruned file takes its sidecars with it: \(kept)")
        XCTAssertEqual(kept.filter { $0.hasSuffix("-shm") }.count, 2, "\(kept)")
    }

    /// Same-second quarantines get `-1`, `-2`, ... before the extension; the
    /// retention must order them by that counter, not by plain string order
    /// (`-` sorts below `.`, which would delete the newest first).
    func testSameSecondQuarantinesAreNumberedAndPrunedOldestFirst() throws {
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.maxQuarantined = 3
        config.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        for round in 0..<5 {
            try Data(String(repeating: "garbage \(round) ", count: 20).utf8).write(to: config.url)
            let db = try HistoryDatabase.open(config)
            db.close()
        }
        let kept = historyQuarantined(in: dir).filter { $0.hasSuffix(".sqlite") }
        XCTAssertEqual(kept, [
            "history.corrupt-20270115T080000Z-2.sqlite",
            "history.corrupt-20270115T080000Z-3.sqlite",
            "history.corrupt-20270115T080000Z-4.sqlite",
        ])
    }

    func testRuntimeRecoveryKeepsTheProcessLockSoNoSecondInstanceSlipsIn() throws {
        let dir = historyTempDirectory()
        let config = historyConfig(dir)
        let db = try HistoryDatabase.open(config)
        try historyPopulate(db, rows: 100)
        let report = try db.recreateAfterCorruption(reason: "test")
        XCTAssertEqual(report.reason, "test")
        XCTAssertNotNil(report.quarantinedTo)
        XCTAssertEqual(db.recovery, report)
        try assertFreshWorkingDatabase(db)
        XCTAssertThrowsError(try HistoryDatabase.open(config)) { error in
            guard case HistoryStoreError.lockedByAnotherInstance = error else { return XCTFail("\(error)") }
        }
        let kept = try SQLiteConnection(path: try XCTUnwrap(report.quarantinedTo).path)
        XCTAssertEqual(try kept.queryInt("SELECT count(*) FROM dict"), 100, "the old rows stay readable")
        db.close()
    }

    // MARK: Unrecoverable

    /// Without the lock, the garbage file cannot be moved aside: unrecoverable.
    /// With it, creating the lock file already fails, and that is reported as
    /// the environment problem it is (EACCES), which the store retries.
    func testAReadOnlyDirectoryFailsTheOpenAndDestroysNothing() throws {
        for useLock in [false, true] {
            let dir = historyTempDirectory("readonly\(useLock)")
            var config = historyConfig(dir)
            config.useProcessLock = useLock
            try Data(repeating: 0x41, count: 5000).write(to: config.url)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
            XCTAssertThrowsError(try HistoryDatabase.open(config)) { error in
                switch (useLock, error as? HistoryStoreError) {
                case (false, .unrecoverable?): break
                case (true, .lockUnavailable(.lockFile, EACCES)?): break
                default: XCTFail("lock \(useLock): got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: config.url), Data(repeating: 0x41, count: 5000), "lock \(useLock): nothing destroyed")
        }
    }

    /// The real flock contention, end to end: only EWOULDBLOCK from `flock`
    /// reads as another instance.
    func testOnlyAHeldLockReadsAsAnotherInstance() throws {
        let dir = historyTempDirectory()
        let holder = try HistoryProcessLock(path: dir.appendingPathComponent("x.lock").path)
        XCTAssertThrowsError(try HistoryProcessLock(path: dir.appendingPathComponent("x.lock").path)) { error in
            guard case HistoryStoreError.lockedByAnotherInstance = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try HistoryProcessLock(path: dir.appendingPathComponent("missing/x.lock").path)) { error in
            guard case HistoryStoreError.lockUnavailable(.lockFile, ENOENT) = error else { return XCTFail("\(error)") }
        }
        withExtendedLifetime(holder) {}
    }
}
