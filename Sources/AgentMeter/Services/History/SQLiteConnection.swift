import Foundation
import SQLite3

/// How a connection is opened. The defaults are the store's production
/// settings; tests override single fields (a short busy timeout, read-only).
struct SQLiteOpenOptions: Sendable {
    enum Threading: Sendable { case noMutex, fullMutex }

    var readOnly = false
    /// `FULLMUTEX` costs 7-16 % on bulk inserts of a path that is about 1 % of
    /// the app's time, and protects against the one class of bug the type
    /// system cannot see (a later `nonisolated` helper or a test sharing the
    /// connection). The actor already serialises every call.
    var threading: Threading = .fullMutex
    /// Does NOT cover the switch to WAL on a fresh file: that returns BUSY at
    /// once when another connection is doing the same (see `HistoryDatabase.configure`).
    var busyTimeoutMs: Int32 = 5_000
    /// Pages, not bytes (1,000 x 4 KiB = 4 MiB of WAL). A 1,000-row chunk of
    /// random-key inserts dirties about 1,000 pages, so nearly every such
    /// commit runs a checkpoint itself; that is why nothing awaits the store
    /// on a latency-sensitive path.
    var walAutocheckpointPages: Int = HistoryDatabase.walAutocheckpointPages
    /// Bounds the WAL file after a reset.
    var journalSizeLimitBytes: Int = 8 << 20
    /// Negative = KiB. 2 MiB: the heap budget of the whole app is gated, and a
    /// larger cache did not measurably speed up random inserts.
    var cacheSizeKiB: Int = 2_048
    init() {}
}

/// One SQLite connection. NOT Sendable on purpose: the compiler then proves
/// that it never leaves the actor that created it, and the actor's
/// serialisation is all SQLite's multi-thread mode asks for.
///
/// Why not `@unchecked Sendable`: it would silence exactly the diagnostics
/// that protect the handle. Why a class with a `deinit` instead of closing in
/// the actor's `deinit`: a Swift 6 actor `deinit` is nonisolated and may not
/// touch isolated non-Sendable state, and `isolated deinit` needs macOS 15.4.
/// When the last reference drops, the close runs on whichever thread released
/// it, which SQLite allows because nobody else can still be using the handle.
final class SQLiteConnection {
    private(set) var handle: OpaquePointer?
    let path: String
    private var cache: [String: SQLiteStatement] = [:]

    init(path: String, options: SQLiteOpenOptions = SQLiteOpenOptions()) throws {
        self.path = path
        var db: OpaquePointer?
        var flags: Int32 = options.readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        flags |= options.threading == .fullMutex ? SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let err = SQLiteError(handle: db, rc: rc, context: "open")
            if let db { sqlite3_close_v2(db) }
            throw err
        }
        handle = db
        // Compound codes (1555 = CONSTRAINT_PRIMARYKEY ...) are what `SQLiteError.extendedCode` reports.
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, options.busyTimeoutMs)
    }

    deinit { closeQuietly() }

    private func closeQuietly() {
        guard let h = handle else { return }
        cache.removeAll()           // finalize the cached statements first
        sqlite3_close_v2(h)         // v2 defers the real close if anything is still alive and never fails
        handle = nil
    }

    func close() { closeQuietly() }

    /// Strict close for tests and orderly shutdown: `sqlite3_close` fails with
    /// BUSY when any statement leaked, which `close_v2` would hide as a zombie.
    func closeStrict() throws {
        guard let h = handle else { return }
        cache.removeAll()
        let rc = sqlite3_close(h)
        if rc != SQLITE_OK { throw SQLiteError(handle: h, rc: rc, context: "close") }
        handle = nil
    }

    var isOpen: Bool { handle != nil }
    /// The main database was opened (or fell back to) read-only.
    var isReadOnly: Bool { sqlite3_db_readonly(handle, "main") == 1 }

    private func requireHandle() throws -> OpaquePointer {
        guard let h = handle else { throw HistoryStoreError.closed }
        return h
    }

    // MARK: Exec / prepare

    func exec(_ sql: String) throws {
        let h = try requireHandle()
        let rc = sqlite3_exec(h, sql, nil, nil, nil)
        if rc != SQLITE_OK { throw SQLiteError(handle: h, rc: rc, context: "exec", sql: sql) }
    }

    func prepare(_ sql: String, persistent: Bool = false) throws -> SQLiteStatement {
        let h = try requireHandle()
        var stmt: OpaquePointer?
        let flags: UInt32 = persistent ? UInt32(SQLITE_PREPARE_PERSISTENT) : 0
        let rc = sqlite3_prepare_v3(h, sql, -1, flags, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw SQLiteError(handle: h, rc: rc, context: "prepare", sql: sql) }
        return SQLiteStatement(raw: stmt, sql: sql)
    }

    /// Runs `body` with a cached, persistent statement that is reset before and
    /// after use, including when `body` throws. Use it for SQL that runs per
    /// observation; the same text prepares once per connection.
    func withStatement<T>(_ sql: String, _ body: (SQLiteStatement) throws -> T) throws -> T {
        let stmt: SQLiteStatement
        if let hit = cache[sql] {
            stmt = hit
        } else {
            stmt = try prepare(sql, persistent: true)
            cache[sql] = stmt
        }
        stmt.reset()
        defer { stmt.reset() }
        return try body(stmt)
    }

    /// One-shot statement (not cached) for rare SQL: PRAGMAs, migrations,
    /// integrity checks.
    func withTemporaryStatement<T>(_ sql: String, _ body: (SQLiteStatement) throws -> T) throws -> T {
        let stmt = try prepare(sql)
        defer { stmt.reset() }      // the statement finalizes in its deinit right after
        return try body(stmt)
    }

    // MARK: Convenience queries (uncached)

    func queryInt(_ sql: String) throws -> Int64? {
        try withTemporaryStatement(sql) { s in try s.step() ? s.int64(0) : nil }
    }

    func queryText(_ sql: String) throws -> String? {
        try withTemporaryStatement(sql) { s in try s.step() ? s.text(0) : nil }
    }

    func queryTexts(_ sql: String) throws -> [String] {
        try withTemporaryStatement(sql) { s in
            var out: [String] = []
            while try s.step() { if let t = s.text(0) { out.append(t) } }
            return out
        }
    }

    /// Rows inserted, updated or deleted since the connection opened.
    var totalChanges: Int64 { sqlite3_total_changes64(handle) }
    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    var lastChanges: Int64 { sqlite3_changes64(handle) }
    var inTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }

    /// Statements still alive on this connection that stopped mid-result. A
    /// test hook: anything above 0 outside a call pins a WAL snapshot.
    func busyStatementCount() -> Int {
        var n = 0
        var s = sqlite3_next_stmt(handle, nil)
        while let cur = s {
            if sqlite3_stmt_busy(cur) != 0 { n += 1 }
            s = sqlite3_next_stmt(handle, cur)
        }
        return n
    }

    // MARK: Transactions

    enum TransactionMode: String, Sendable { case deferred = "DEFERRED", immediate = "IMMEDIATE", exclusive = "EXCLUSIVE" }

    /// `BEGIN IMMEDIATE ... COMMIT`, `ROLLBACK` on any throw. IMMEDIATE takes
    /// the write lock up front, so a writer never fails halfway with BUSY when
    /// upgrading a read lock (the WAL "busy snapshot" case).
    ///
    /// Validate rows BEFORE calling this. A NOT NULL or CHECK failure inside
    /// the body rolls the whole transaction back, so a scan transaction of
    /// 1,000 observations (`HistoryStore.scanChunkObservations`) with one bad
    /// row would silently drop the other 999; `HistoryStore.inChunks` counts
    /// such a chunk in `failedChunks` and moves on, which is the safety net,
    /// not the plan.
    func transaction<T>(_ mode: TransactionMode = .immediate, _ body: () throws -> T) throws -> T {
        try exec("BEGIN \(mode.rawValue)")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            // COMMIT can itself fail (BUSY, FULL, IOERR) and leave the
            // transaction open, and some errors roll back by themselves: roll
            // back only if one is still active, and swallow a secondary error.
            if inTransaction { _ = try? exec("ROLLBACK") }
            throw error
        }
    }

    // MARK: PRAGMAs and checkpoints

    /// `PRAGMA name = value`, stepping to the end because some PRAGMAs
    /// (`journal_mode`) return a row when set.
    func setPragma(_ name: String, _ value: String) throws {
        try withTemporaryStatement("PRAGMA \(name) = \(value)") { s in while try s.step() {} }
    }

    /// `wal_checkpoint(PASSIVE)`: copies what it can without waiting for any
    /// reader. The only mode the store uses. Never TRUNCATE or RESTART while
    /// the integrity-check reader may be open: they wait for readers and would
    /// stall the store actor behind a check that takes seconds.
    ///
    /// A freshly opened connection reports (-1, -1) and silently does nothing
    /// until it has executed one read (it does not yet know the file is WAL),
    /// hence the priming read.
    @discardableResult
    func checkpointPassive() throws -> (walFrames: Int32, checkpointed: Int32) {
        let h = try requireHandle()
        _ = try queryInt("PRAGMA user_version")
        var log: Int32 = 0, ckpt: Int32 = 0
        let rc = sqlite3_wal_checkpoint_v2(h, nil, SQLITE_CHECKPOINT_PASSIVE, &log, &ckpt)
        if rc != SQLITE_OK { throw SQLiteError(handle: h, rc: rc, context: "checkpoint") }
        return (log, ckpt)
    }
}
