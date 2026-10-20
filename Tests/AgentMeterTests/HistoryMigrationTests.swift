import CryptoKit
import Foundation
import os
import SQLite3
import XCTest
@testable import AgentMeter

/// Open, PRAGMAs, migrations, downgrade protection, the identity probe and
/// the process lock.
final class HistoryMigrationTests: XCTestCase {
    func testFreshDatabaseReachesTheLatestVersionWithTheWholeSchema() throws {
        let dir = historyTempDirectory()
        let db = try HistoryDatabase.open(historyConfig(dir))
        XCTAssertEqual(try db.userVersion(), HistorySchema.migrations.count)
        XCTAssertEqual(try db.conn.queryInt("PRAGMA application_id"), 0x414D4853)
        let names = try db.conn.queryTexts("""
            SELECT name FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' ORDER BY name
            """)
        XCTAssertEqual(names, (HistorySchema.tableNames + HistorySchema.indexNames).sorted())
        XCTAssertNil(db.recovery)
        XCTAssertFalse(db.openedAfterUncleanShutdown)
        db.close()
    }

    func testPragmasAreAppliedAndWALIsOn() throws {
        let dir = historyTempDirectory()
        let db = try HistoryDatabase.open(historyConfig(dir))
        defer { db.close() }
        XCTAssertEqual(try db.conn.queryText("PRAGMA journal_mode"), "wal")
        XCTAssertEqual(try db.conn.queryInt("PRAGMA synchronous"), 1, "NORMAL")
        XCTAssertEqual(try db.conn.queryInt("PRAGMA foreign_keys"), 1)
        XCTAssertEqual(try db.conn.queryInt("PRAGMA busy_timeout"), 5_000)
        XCTAssertEqual(try db.conn.queryInt("PRAGMA wal_autocheckpoint"), Int64(HistoryDatabase.walAutocheckpointPages))
        XCTAssertEqual(try db.conn.queryInt("PRAGMA journal_size_limit"), 8 << 20)
        XCTAssertEqual(try db.conn.queryInt("PRAGMA cache_size"), -2048, "2 MiB")
        XCTAssertEqual(try db.conn.queryInt("PRAGMA mmap_size"), 0)
        XCTAssertEqual(try db.conn.queryInt("PRAGMA trusted_schema"), 0)
        XCTAssertEqual(try db.conn.queryInt("PRAGMA cell_size_check"), 1)
        XCTAssertEqual(try db.conn.queryInt("PRAGMA page_size"), 4096)
        XCTAssertNotNil(sqlite3_db_mutex(db.conn.handle), "opened FULLMUTEX (serialized)")
    }

    func testReopenIsIdempotentAndRunsNoMigrationTwice() throws {
        let dir = historyTempDirectory()
        let runs = OSAllocatedUnfairLock(initialState: 0)
        var config = historyConfig(dir)
        config.migrations = [HistoryMigration(version: 1, name: "t") { db in
            runs.withLock { $0 += 1 }
            try db.exec("CREATE TABLE a(x)")
        }]
        for _ in 0..<3 {
            let db = try HistoryDatabase.open(config)
            XCTAssertEqual(try db.userVersion(), 1)
            db.close()
        }
        XCTAssertEqual(runs.withLock { $0 }, 1)
    }

    func testForwardUpgradeKeepsData() throws {
        let dir = historyTempDirectory()
        var v1 = historyConfig(dir)
        v1.migrations = [HistorySchema.migrations[0]]
        let first = try HistoryDatabase.open(v1)
        try first.conn.exec("INSERT INTO dict(kind, value) VALUES (1, 'claude-opus')")
        first.close()
        var v2 = historyConfig(dir)
        v2.migrations = [HistorySchema.migrations[0], HistoryMigration(version: 2, name: "dict index") { db in
            try db.exec("CREATE INDEX dict_value ON dict(value)")
        }]
        let second = try HistoryDatabase.open(v2)
        XCTAssertEqual(try second.userVersion(), 2)
        XCTAssertEqual(try second.conn.queryText("SELECT value FROM dict"), "claude-opus")
        XCTAssertEqual(try second.conn.queryInt("SELECT count(*) FROM sqlite_master WHERE name = 'dict_value'"), 1)
        second.close()
    }

    func testAFailureInTheMiddleLeavesVersionAndSchemaUnchanged() throws {
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.migrations = [HistorySchema.migrations[0], HistoryMigration(version: 2, name: "broken") { db in
            try db.exec("CREATE TABLE half_done(x)")
            try db.exec("INSERT INTO half_done VALUES (1)")
            try db.exec("CREATE INDEX nope ON missing_table(y)")     // fails after the DDL and DML already ran
        }]
        XCTAssertThrowsError(try HistoryDatabase.open(config)) { error in
            guard case let HistoryStoreError.migrationFailed(version, name, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(version, 2); XCTAssertEqual(name, "broken")
        }
        // A raw connection: v1 applied, v2 rolled back whole, version still 1.
        let raw = try SQLiteConnection(path: config.url.path)
        XCTAssertEqual(try raw.queryInt("PRAGMA user_version"), 1)
        XCTAssertEqual(try raw.queryInt("SELECT count(*) FROM sqlite_master WHERE name = 'half_done'"), 0)
        XCTAssertEqual(try raw.queryInt("SELECT count(*) FROM sqlite_master WHERE name = 'request'"), 1)
        raw.close()
        // A later, fixed build finishes the job.
        config.migrations = [HistorySchema.migrations[0], HistoryMigration(version: 2, name: "fixed") { db in
            try db.exec("CREATE INDEX dict_value ON dict(value)")
        }]
        let db = try HistoryDatabase.open(config)
        XCTAssertEqual(try db.userVersion(), 2)
        db.close()
    }

    func testAThrowingClosureThatIsNotSQLiteAlsoRollsBack() throws {
        struct Nope: Error {}
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.migrations = [HistoryMigration(version: 1, name: "x") { db in
            try db.exec("CREATE TABLE a(x)")
            throw Nope()
        }]
        XCTAssertThrowsError(try HistoryDatabase.open(config)) { XCTAssertTrue($0 is Nope) }
        let raw = try SQLiteConnection(path: config.url.path)
        XCTAssertEqual(try raw.queryInt("PRAGMA user_version"), 0)
        XCTAssertEqual(try raw.queryInt("SELECT count(*) FROM sqlite_master"), 0)
    }

    /// Downgrade protection: a file from a newer build is neither migrated,
    /// renamed nor modified, so the newer build still finds its data.
    func testANewerSchemaIsRefusedAndTheFileIsByteIdentical() throws {
        let dir = historyTempDirectory()
        let config = historyConfig(dir)
        let first = try HistoryDatabase.open(config)
        try first.conn.exec("INSERT INTO dict(kind, value) VALUES (1, 'x')")
        try first.conn.setPragma("user_version", "99")            // pretend a future build wrote this
        first.close()
        let before = historyFileBytes(config.url)
        let walBefore = FileManager.default.fileExists(atPath: config.url.path + "-wal")
        XCTAssertThrowsError(try HistoryDatabase.open(config)) { error in
            guard case let HistoryStoreError.schemaTooNew(found, supported) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found, 99); XCTAssertEqual(supported, HistorySchema.migrations.count)
        }
        XCTAssertEqual(historyFileBytes(config.url), before, "the main file is untouched")
        XCTAssertEqual(FileManager.default.fileExists(atPath: config.url.path + "-wal"), walBefore)
        XCTAssertEqual(historyQuarantined(in: dir), [], "a newer file must not be quarantined")
        var readOnly = SQLiteOpenOptions(); readOnly.readOnly = true
        let reader = try SQLiteConnection(path: config.url.path, options: readOnly)
        XCTAssertEqual(try reader.queryInt("SELECT count(*) FROM dict"), 1)
    }

    func testAForeignSQLiteFileIsQuarantinedNotDeleted() throws {
        let dir = historyTempDirectory()
        let config = historyConfig(dir)
        let other = try SQLiteConnection(path: config.url.path)
        try other.exec("CREATE TABLE someone_elses(x); INSERT INTO someone_elses VALUES (42)")
        other.close()
        let db = try HistoryDatabase.open(config)
        let report = try XCTUnwrap(db.recovery)
        XCTAssertTrue(report.reason.contains("foreignDatabase"))
        let moved = try XCTUnwrap(report.quarantinedTo)
        let kept = try SQLiteConnection(path: moved.path)
        XCTAssertEqual(try kept.queryInt("SELECT x FROM someone_elses"), 42, "the old rows stay readable in the quarantined file")
        XCTAssertEqual(try db.userVersion(), HistorySchema.migrations.count)
        db.close()
    }

    func testADifferentApplicationIDIsForeignToo() throws {
        let dir = historyTempDirectory()
        let config = historyConfig(dir)
        let other = try SQLiteConnection(path: config.url.path)
        try other.exec("PRAGMA application_id = 1234; PRAGMA user_version = 1; CREATE TABLE theirs(x)")
        other.close()
        let db = try HistoryDatabase.open(config)
        XCTAssertTrue(try XCTUnwrap(db.recovery).reason.contains("application_id=1234"))
        XCTAssertEqual(try db.userVersion(), HistorySchema.migrations.count)
        db.close()
    }

    /// Eight threads open the same fresh file at once, with the process lock
    /// off, to exercise BEGIN IMMEDIATE plus the re-check, the BUSY retry of the
    /// WAL switch and the single-statement identity probe. Twenty rounds.
    func testConcurrentOpenOfAFreshFileAllSucceedWithoutQuarantine() throws {
        for _ in 0..<20 {
            let dir = historyTempDirectory()
            var config = historyConfig(dir)
            config.useProcessLock = false
            let frozen = config
            let errors = OSAllocatedUnfairLock<[String]>(initialState: [])
            let versions = OSAllocatedUnfairLock<[Int]>(initialState: [])
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do {
                    let db = try HistoryDatabase.open(frozen)
                    let version = try db.userVersion()
                    db.close()
                    versions.withLock { $0.append(version) }
                } catch {
                    errors.withLock { $0.append("\(error)") }
                }
            }
            XCTAssertEqual(errors.withLock { $0 }, [])
            XCTAssertEqual(Set(versions.withLock { $0 }), [HistorySchema.migrations.count])
            XCTAssertEqual(historyQuarantined(in: dir), [])
        }
    }

    func testASecondInstanceIsLockedOutAndNeverTouchesTheFile() throws {
        let dir = historyTempDirectory()
        let config = historyConfig(dir)
        let first = try HistoryDatabase.open(config)
        try first.conn.exec("INSERT INTO dict(kind, value) VALUES (1, 'x')")
        XCTAssertThrowsError(try HistoryDatabase.open(config)) { error in
            guard case HistoryStoreError.lockedByAnotherInstance = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try historyDictCount(first), 1)
        first.close()
        let again = try HistoryDatabase.open(config)
        XCTAssertEqual(try historyDictCount(again), 1, "the lock is released by close()")
        again.close()
    }

    func testAnOldSQLiteIsRefusedBeforeAnythingIsCreated() throws {
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.sqliteVersionNumber = 3_036_000
        XCTAssertThrowsError(try HistoryDatabase.open(config)) { error in
            guard case let HistoryStoreError.sqliteTooOld(found, required) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found, 3_036_000); XCTAssertEqual(required, 3_037_000)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "no database, no lock file")
    }

    func testMigrationsMustBeNumberedFromOne() {
        XCTAssertEqual(HistorySchema.migrations.map(\.version), Array(1...HistorySchema.migrations.count))
        XCTAssertEqual(HistorySchema.applicationID, 0x414D_4853, "'AMHS'")
    }

    /// Migration 1 pinned to what it creates. A database already at version 1
    /// never runs it again, so once a build with it has shipped, an edit would
    /// leave old and new files with different schemas under the same version:
    /// a schema change is then a new migration appended to
    /// `HistorySchema.migrations`. Until the first release an edit is still
    /// allowed; update `migrationOneDigest` on purpose, from the dump printed
    /// on failure.
    func testMigrationOneStillCreatesThePinnedSchema() throws {
        let migration = HistorySchema.migrations[0]
        XCTAssertEqual(migration.version, 1)
        XCTAssertEqual(migration.name, "history schema v1")
        let dir = historyTempDirectory()
        let conn = try SQLiteConnection(path: dir.appendingPathComponent("v1.sqlite").path)
        defer { conn.close() }
        try migration.apply(conn)
        // sqlite_master keeps each CREATE as written (SQLite only normalises
        // its first two keywords), so whitespace inside the SQL counts too.
        let objects = try conn.queryTexts("""
            SELECT type || ' ' || name || ' ON ' || tbl_name || char(10) || sql || ';'
            FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name
            """)
        let applicationID = try XCTUnwrap(conn.queryInt("PRAGMA application_id"))
        let dump = (["application_id \(applicationID)"] + objects).joined(separator: "\n") + "\n"
        let digest = HistoryHex.encode(SHA256.hash(data: Data(dump.utf8)))
        XCTAssertEqual(digest, Self.migrationOneDigest, "migration 1 now creates:\n\(dump)")
    }

    /// SHA-256 of the dump above, Phase 0B's schema: 16 tables, 3 indexes.
    private static let migrationOneDigest = "de1f5f46fe719c2eb38c0baf518a59ccc3ee4bcd03c9191249cd173b0516eaca"
}
