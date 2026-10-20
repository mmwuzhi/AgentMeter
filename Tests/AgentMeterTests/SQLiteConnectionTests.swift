import Foundation
import SQLite3
import XCTest
@testable import AgentMeter

/// The thin SQLite wrapper under the history: typed binds, the statement
/// cache, transactions and error codes. Pure SQLite, no history schema.
final class SQLiteConnectionTests: XCTestCase {
    private func memoryDB() throws -> SQLiteConnection { try SQLiteConnection(path: ":memory:") }

    func testLinkedSQLiteIsNewEnoughForStrictTablesAndHasTheFeaturesTheStoreUses() throws {
        XCTAssertGreaterThanOrEqual(sqlite3_libversion_number(), HistoryDatabase.minimumSQLiteVersion,
                                    "STRICT tables (3.37) are required")
        let db = try memoryDB()
        // row values, UPSERT, RETURNING, window functions, STRICT, generated columns
        XCTAssertEqual(try db.queryInt("SELECT (1,2) < (1,3)"), 1)
        try db.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b INTEGER NOT NULL, g INTEGER GENERATED ALWAYS AS (b*2) VIRTUAL) STRICT")
        try db.exec("INSERT INTO t(a,b) VALUES (1,5) ON CONFLICT(a) DO UPDATE SET b = max(b, excluded.b)")
        XCTAssertEqual(try db.queryInt("INSERT INTO t(a,b) VALUES (1,9) ON CONFLICT(a) DO UPDATE SET b = max(b, excluded.b) RETURNING g"), 18)
        XCTAssertEqual(try db.queryInt("SELECT sum(b) OVER (ORDER BY a) FROM t"), 9)
        // STRICT rejects text in an INTEGER column instead of converting it
        XCTAssertThrowsError(try db.exec("INSERT INTO t(a,b) VALUES (2,'abc')")) { e in
            XCTAssertEqual((e as? SQLiteError)?.code, SQLITE_CONSTRAINT)
        }
    }

    func testTypedBindsRoundTripIncludingNULTextAndEmptyBlob() throws {
        let db = try memoryDB()
        try db.exec("CREATE TABLE t(i INTEGER, d REAL, s TEXT, b BLOB, n)")
        let emoji = "héllo 🧪 \u{0}tail"      // an embedded NUL must survive: bound with an explicit length
        let blob: [UInt8] = [0, 1, 2, 255, 0]
        try db.withStatement("INSERT INTO t VALUES (?1,?2,?3,?4,?5)") { s in
            s.bind(1, Int64.max); s.bind(2, 3.5); s.bind(3, emoji); s.bind(4, blob: blob); s.bindNull(5)
            try s.step()
            s.reset()
            s.bind(1, Int64.min); s.bind(2, -0.0); s.bind(3, ""); s.bind(4, blob: [UInt8]()); s.bindNull(5)
            try s.step()
            s.reset()
            s.bind([.int(7), .double(.infinity), .text("x"), .blob([9]), .null])
            try s.step()
        }
        try db.withTemporaryStatement("SELECT i,d,s,b,n,typeof(b) FROM t ORDER BY rowid") { s in
            XCTAssertTrue(try s.step())
            XCTAssertEqual(s.int64(0), Int64.max); XCTAssertEqual(s.double(1), 3.5)
            XCTAssertEqual(s.text(2), emoji, "String(cString:) would have stopped at the NUL")
            XCTAssertEqual(s.blob(3), blob); XCTAssertTrue(s.isNull(4))
            XCTAssertTrue(try s.step())
            XCTAssertEqual(s.int64(0), Int64.min)
            XCTAssertEqual(s.text(2), "", "empty text is '' and not NULL")
            XCTAssertEqual(s.blob(3), [], "an empty blob is zeroblob(0); a nil pointer would have stored NULL")
            XCTAssertEqual(s.text(5), "blob")
            XCTAssertTrue(try s.step())
            XCTAssertEqual(s.double(1), .infinity)
            XCTAssertFalse(try s.step())
        }
        // NaN is stored as NULL by SQLite: never bind it.
        try db.withStatement("INSERT INTO t(d) VALUES (?1)") { s in s.bind(1, Double.nan); try s.step() }
        XCTAssertEqual(try db.queryInt("SELECT count(*) FROM t WHERE d IS NULL AND i IS NULL"), 1)
    }

    func testUInt64BindsItsBitPatternAndRoundTrips() throws {
        let db = try memoryDB()
        try db.exec("CREATE TABLE t(id INTEGER) STRICT")
        let values: [UInt64] = [0, 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max, 0xDEAD_BEEF_CAFE_F00D]
        try db.withStatement("INSERT INTO t VALUES (?1)") { s in
            for v in values { s.bind(1, v); try s.step(); s.rewind() }
        }
        var back: [UInt64] = []
        try db.withTemporaryStatement("SELECT id FROM t ORDER BY rowid") { s in
            while try s.step() { back.append(s.uint64(0)) }
        }
        XCTAssertEqual(back, values, "file ids and volume ids above Int64.max must not trap and must round-trip")
        XCTAssertEqual(try db.queryInt("SELECT id FROM t WHERE rowid = 5"), -1, "SQL sees the signed value (UInt64.max is -1)")
    }

    func testStatementsNeverLeakOnThrow() throws {
        let dir = historyTempDirectory()
        let db = try SQLiteConnection(path: dir.appendingPathComponent("a.sqlite").path)
        try db.exec("CREATE TABLE t(k INTEGER PRIMARY KEY, v INTEGER NOT NULL) STRICT")
        try db.exec("INSERT INTO t VALUES (1,1),(2,2),(3,3)")
        // 1) a constraint failure inside withStatement leaves the statement reset and the connection usable
        for _ in 0..<500 {
            XCTAssertThrowsError(try db.withStatement("INSERT INTO t VALUES (?1, ?2)") { s in s.bind(1, 1); s.bind(2, 1); try s.step() }) {
                XCTAssertEqual(($0 as? SQLiteError)?.extendedCode, 1555 /* SQLITE_CONSTRAINT_PRIMARYKEY */)
            }
        }
        // 2) a SELECT abandoned halfway (the body throws while rows remain)
        struct Boom: Error {}
        for _ in 0..<500 {
            XCTAssertThrowsError(try db.withStatement("SELECT k FROM t ORDER BY k") { s in
                XCTAssertTrue(try s.step()); throw Boom()
            })
        }
        // 3) a prepare failure leaves nothing behind
        for _ in 0..<500 { XCTAssertThrowsError(try db.prepare("SELEKT nonsense")) }
        // 4) a bad bind surfaces from step() and the statement is reusable afterwards
        try db.withStatement("SELECT ?1") { s in
            s.bind(5, 1)    // out of range: SQLITE_RANGE, remembered until step()
            XCTAssertThrowsError(try s.step()) { XCTAssertEqual(($0 as? SQLiteError)?.code, SQLITE_RANGE) }
        }
        XCTAssertEqual(db.busyStatementCount(), 0, "nothing may stay mid-execution: it would pin a WAL snapshot")
        // Only the cached statements are alive; the strict close (sqlite3_close, not _v2) must succeed.
        XCTAssertNoThrow(try db.closeStrict())
    }

    func testStrictCloseDetectsALeakedStatement() throws {
        let db = try memoryDB()
        let leaked = try db.prepare("SELECT 1")      // held by the test: sqlite3_close must refuse
        XCTAssertThrowsError(try db.closeStrict()) { XCTAssertEqual(($0 as? SQLiteError)?.code, SQLITE_BUSY) }
        _ = leaked
        db.close()                                    // the close_v2 path (deinit) still succeeds, as a zombie
    }

    func testTransactionRollsBackOnAnyThrow() throws {
        let db = try memoryDB()
        try db.exec("CREATE TABLE t(k INTEGER PRIMARY KEY) STRICT")
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction { try db.exec("INSERT INTO t VALUES (1)"); throw Boom() })
        XCTAssertFalse(db.inTransaction)
        XCTAssertEqual(try db.queryInt("SELECT count(*) FROM t"), 0)
        // a SQL error inside the body
        XCTAssertThrowsError(try db.transaction { try db.exec("INSERT INTO t VALUES (1)"); try db.exec("INSERT INTO t VALUES (1)") })
        XCTAssertFalse(db.inTransaction)
        XCTAssertEqual(try db.queryInt("SELECT count(*) FROM t"), 0)
        try db.transaction { try db.exec("INSERT INTO t VALUES (1)") }
        XCTAssertEqual(try db.queryInt("SELECT count(*) FROM t"), 1)
    }

    func testErrorsCarryCodesAndMessage() throws {
        let db = try memoryDB()
        do { try db.exec("SELEKT 1"); XCTFail("expected a syntax error") } catch let e as SQLiteError {
            XCTAssertEqual(e.code, SQLITE_ERROR); XCTAssertEqual(e.context, "exec"); XCTAssertTrue(e.message.contains("syntax"))
        }
        try db.exec("CREATE TABLE t(k INTEGER PRIMARY KEY, u TEXT NOT NULL UNIQUE)")
        try db.exec("INSERT INTO t VALUES (1,'a')")
        do { try db.exec("INSERT INTO t VALUES (2,'a')"); XCTFail("expected a constraint error") } catch let e as SQLiteError {
            XCTAssertTrue(e.isConstraint); XCTAssertEqual(e.extendedCode, 2067 /* SQLITE_CONSTRAINT_UNIQUE */)
            XCTAssertFalse(e.isCorruption)
        }
        XCTAssertEqual(sqliteIOErrShortRead, 522)
        XCTAssertTrue(SQLiteError(code: SQLITE_IOERR, extendedCode: sqliteIOErrShortRead, message: "", context: "step").isCorruption)
        XCTAssertFalse(SQLiteError(code: SQLITE_IOERR, extendedCode: sqliteIOErrShortRead, message: "", context: "step").isEnvironmental)
    }

    func testBusyTimeoutSurfacesAsBusyNotAHang() throws {
        let dir = historyTempDirectory()
        let path = dir.appendingPathComponent("b.sqlite").path
        var options = SQLiteOpenOptions(); options.busyTimeoutMs = 150
        let a = try SQLiteConnection(path: path, options: options)
        let b = try SQLiteConnection(path: path, options: options)
        try a.exec("PRAGMA journal_mode = WAL")
        try a.exec("CREATE TABLE t(k)")
        try a.exec("BEGIN IMMEDIATE")                 // a holds the single WAL write lock
        let t0 = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try b.exec("BEGIN IMMEDIATE")) { XCTAssertTrue(($0 as? SQLiteError)?.isBusy == true) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        XCTAssertGreaterThan(ms, 100); XCTAssertLessThan(ms, 1500)
        XCTAssertEqual(try b.queryInt("SELECT count(*) FROM t"), 0, "WAL readers are never blocked by the writer")
        try a.exec("ROLLBACK")
    }

    func testPassiveCheckpointOnAFreshConnectionNeedsAndDoesAPrimingRead() throws {
        let dir = historyTempDirectory()
        let path = dir.appendingPathComponent("c.sqlite").path
        let writer = try SQLiteConnection(path: path)
        try writer.exec("PRAGMA journal_mode = WAL")
        try writer.exec("CREATE TABLE t(k INTEGER PRIMARY KEY, v TEXT)")
        try writer.transaction { for i in 0..<500 { try writer.exec("INSERT INTO t(v) VALUES ('row \(i)')") } }
        let fresh = try SQLiteConnection(path: path)      // has not read anything yet
        let result = try fresh.checkpointPassive()
        XCTAssertGreaterThan(result.walFrames, 0, "a fresh connection would report -1 without the priming read")
        XCTAssertEqual(result.checkpointed, result.walFrames, "no reader is open, so PASSIVE copies everything")
    }
}
