import Foundation
import SQLite3

/// Everything `HistoryDatabase.open` needs. The store fills `clock`,
/// `timeZone` and `retention` from its own init, so the sync hooks of
/// `HistoryDatabase+Ingest` read them from here instead of calling `Date()`.
struct HistoryDatabaseConfiguration: Sendable {
    var url: URL
    var migrations: [HistoryMigration] = HistorySchema.migrations
    var options = SQLiteOpenOptions()
    /// Advisory `flock` on `<db>.lock` for the life of the database. Only the
    /// holder may quarantine, so a second instance can never move a live file
    /// out from under the first. Tests of the concurrent-open race switch it off.
    var useProcessLock = true
    /// Newest quarantined files kept (`history.corrupt-*`).
    var maxQuarantined = 3
    var clock: @Sendable () -> Date = { Date() }
    var timeZone: TimeZone = .current
    var retention = HistoryRetention()
    /// `sqlite3_libversion_number()`; a field only so a test can fake an old SQLite.
    var sqliteVersionNumber: Int32 = sqlite3_libversion_number()
    /// `st_birthtime` of a transcript in Unix ms, nil when unavailable. Read
    /// once, when the store first registers a path; tests substitute a table.
    var birthTime: @Sendable (String) -> Int64? = HistoryFileBirth.read
    /// Providers the quota hooks store, re-checked in the store. The app keeps
    /// `QuotaHistoryPolicy.ingestedProviders`; a test may widen it.
    var quotaProviders: Set<Provider> = QuotaHistoryPolicy.ingestedProviders
    /// Test-only negative controls; always empty in the app.
    var mergeMutations: HistoryMergeMutations = []
    /// `meta.schema_writer_app_version` of a database this build creates.
    var appVersion: String = HistoryFileBirth.bundleVersion

    init(url: URL) { self.url = url }
}

enum HistoryFileBirth {
    /// `st_birthtimespec` in Unix ms; nil when the file cannot be stat'd.
    @Sendable static func read(_ path: String) -> Int64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let ts = st.st_birthtimespec
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// What an open or a runtime recovery had to do to a damaged file.
struct HistoryRecovery: Sendable, Equatable {
    var reason: String
    /// The moved main file; nil when only sidecar files existed.
    var quarantinedTo: URL?
    var at: Date
}

/// The synchronous core: owns one `SQLiteConnection`, knows the schema and the
/// recovery rules, never awaits. NOT Sendable: it is created and used inside
/// exactly one actor (`HistoryStore`) or one test, which is what lets the
/// compiler keep the connection from leaking.
///
/// Open sequence, in this order, and why:
///  1. SQLite version guard (STRICT tables need 3.37).
///  2. `flock` on `<db>.lock`. Nothing touches the database before this, so a
///     second process never reads, migrates or quarantines it.
///  3. ONE-statement identity probe. A newer-schema or foreign file must not be
///     touched at all, not even by `journal_mode = WAL`, which rewrites header
///     bytes of a rollback-journal file.
///  4. PRAGMAs, then migrations.
///  5. NOTADB / CORRUPT / a foreign file at any step: quarantine, then create
///     a fresh database exactly once. If that fails too: `.unrecoverable`.
/// No `quick_check` runs at open: garbage, truncation and header damage already
/// fail the very first statement in under a millisecond, and a quick_check of a
/// 100 MB file costs 0.2-0.8 s on every launch for little. `runIntegrityCheck`
/// is the periodic detector.
final class HistoryDatabase {
    static let fileName = "history.sqlite"
    /// STRICT tables arrived in 3.37.0.
    static let minimumSQLiteVersion: Int32 = 3_037_000
    /// See `SQLiteOpenOptions.walAutocheckpointPages`.
    static let walAutocheckpointPages = 1_000

    /// Fixed for the life of the object except `timeZone` (`useAccountingTimeZone`).
    private(set) var config: HistoryDatabaseConfiguration
    /// Replaced by `recreateAfterCorruption`. Never cache it across calls.
    private(set) var conn: SQLiteConnection
    /// Set when the open (or the latest recovery) had to move a file aside.
    private(set) var recovery: HistoryRecovery?
    /// A non-empty `-wal` was found at open: the previous process did not close
    /// cleanly (a clean close of the last connection truncates the WAL to 0
    /// bytes but leaves the file). Maintenance runs an integrity check then.
    let openedAfterUncleanShutdown: Bool
    private var lock: HistoryProcessLock?

    private init(config: HistoryDatabaseConfiguration, conn: SQLiteConnection, recovery: HistoryRecovery?,
                 lock: HistoryProcessLock?, unclean: Bool) {
        self.config = config
        self.conn = conn
        self.recovery = recovery
        self.lock = lock
        self.openedAfterUncleanShutdown = unclean
    }

    // MARK: Open

    /// Opens (creating if needed), configures and migrates. Throws
    /// `HistoryStoreError.schemaTooNew` without touching a newer file,
    /// `.lockedByAnotherInstance` when another process holds the lock,
    /// `.lockUnavailable` when the directory or the lock cannot be had for
    /// another reason, a `SQLITE_READONLY` `SQLiteError` for a file this
    /// process may not write, `.sqliteTooOld`, `.migrationFailed`, or
    /// `.unrecoverable`.
    static func open(_ config: HistoryDatabaseConfiguration) throws -> HistoryDatabase {
        guard config.sqliteVersionNumber >= minimumSQLiteVersion else {
            throw HistoryStoreError.sqliteTooOld(found: Int(config.sqliteVersionNumber), required: Int(minimumSQLiteVersion))
        }
        let directory = config.url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw HistoryProcessLock.failure(.directory, errno: posixCode(of: error))
        }
        let lock = config.useProcessLock ? try HistoryProcessLock(path: config.url.path + ".lock") : nil
        let unclean = walSize(of: config.url) > 0
        do {
            let conn = try openOnce(config)
            return HistoryDatabase(config: config, conn: conn, recovery: nil, lock: lock, unclean: unclean)
        } catch let reason as Recoverable {
            let moved = try quarantine(config)
            let conn = try openFresh(config)
            let report = HistoryRecovery(reason: reason.description, quarantinedTo: moved, at: config.clock())
            return HistoryDatabase(config: config, conn: conn, recovery: report, lock: lock, unclean: false)
        }
    }

    /// The POSIX errno behind a Foundation file error (0 when there is none).
    private static func posixCode(of error: any Error) -> Int32 {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return 0
    }

    /// A failure worth quarantining, as opposed to one that must propagate
    /// untouched (schema too new, lock, environment).
    struct Recoverable: Error, CustomStringConvertible {
        let description: String
    }

    /// One attempt: connect, probe identity, configure, migrate.
    static func openOnce(_ config: HistoryDatabaseConfiguration) throws -> SQLiteConnection {
        let conn: SQLiteConnection
        do {
            conn = try SQLiteConnection(path: config.url.path, options: config.options)
        } catch let e as SQLiteError {
            throw e.isCorruption ? Recoverable(description: "open: \(e)") : e
        }
        do {
            // `READWRITE` quietly falls back to read-only for a file this
            // process may not write (restored 0444, created by root), and on a
            // file already in WAL mode every step below is a read, so the open
            // would "succeed" and every later write fail. An environmental
            // error instead: the store reports it and retries after the
            // interval. Before the first read: in WAL mode that read creates
            // `-wal` and `-shm` with the main file's read-only permissions, and
            // they would stay unwritable after the user fixes the file. Such a
            // file is not quarantined either, even if damaged: it is left alone
            // until it is writable.
            if !config.options.readOnly && conn.isReadOnly {
                throw SQLiteError(code: SQLITE_READONLY, message: "the database file is not writable", context: "open")
            }
            try checkIdentity(conn, known: config.migrations.count)
            try configure(conn, config.options)
            try HistoryMigrator.run(conn, config.migrations)
            return conn
        } catch let e as SQLiteError where e.isCorruption {
            conn.close()
            throw Recoverable(description: "\(e)")
        } catch let e as HistoryStoreError {
            conn.close()
            switch e {
            case .foreignDatabase: throw Recoverable(description: "\(e)")
            case let .migrationFailed(_, _, underlying) where underlying.isCorruption: throw Recoverable(description: "\(e)")
            default: throw e
            }
        } catch {
            conn.close()
            throw error
        }
    }

    /// The attempt after a quarantine: whatever goes wrong now is `.unrecoverable`
    /// and the caller must not loop (the store latches).
    static func openFresh(_ config: HistoryDatabaseConfiguration) throws -> SQLiteConnection {
        do {
            return try openOnce(config)
        } catch let e as SQLiteError {
            throw HistoryStoreError.unrecoverable(e)
        } catch let r as Recoverable {
            throw HistoryStoreError.unrecoverable(SQLiteError(code: SQLITE_CORRUPT, message: r.description, context: "open"))
        }
    }

    // MARK: PRAGMAs

    /// The first statement on the handle is `journal_mode = WAL`: on a garbage
    /// file this is where NOTADB shows up (after the identity probe has
    /// already ruled out a foreign or newer file).
    ///
    /// Everything is a PRAGMA because `sqlite3_config` and `sqlite3_db_config`
    /// are variadic C functions that Swift cannot import. Consequence: the
    /// build's DQS=3 default stays on, so a double-quoted string is silently
    /// accepted as a literal. Never write one; STRICT tables catch the type
    /// slips that follow from a misspelt column.
    static func configure(_ c: SQLiteConnection, _ o: SQLiteOpenOptions) throws {
        if !o.readOnly {
            // Switching a fresh file to WAL needs an exclusive lock, and SQLite
            // answers BUSY at once, ignoring busy_timeout, when another
            // connection is doing the same. Retry a few times.
            let mode = try retryWhileBusy { try c.queryText("PRAGMA journal_mode = WAL") }
            guard mode?.lowercased() == "wal" else {
                throw SQLiteError(code: SQLITE_ERROR, message: "journal_mode is \(mode ?? "nil"), wanted wal", context: "pragma")
            }
        }
        // WAL + NORMAL: no fsync per commit, durable across an app crash. Not
        // adopted: synchronous=OFF (a power cut can corrupt a WAL database that
        // holds non-rebuildable samples), checkpoint_fullfsync=OFF and a
        // background checkpointer (decide from telemetry, not guesses).
        try c.setPragma("synchronous", "NORMAL")
        try c.setPragma("foreign_keys", "ON")        // a no-op inside a transaction: set it at open
        try c.setPragma("wal_autocheckpoint", "\(o.walAutocheckpointPages)")
        try c.setPragma("journal_size_limit", "\(o.journalSizeLimitBytes)")
        try c.setPragma("cache_size", "-\(o.cacheSizeKiB)")
        // mmap off: a file truncated under a mapping is a SIGBUS, and a
        // measurement showed no win for the range queries this store serves.
        try c.setPragma("mmap_size", "0")
        try c.setPragma("trusted_schema", "OFF")
        try c.setPragma("cell_size_check", "ON")     // catches a malformed cell at its first read
    }

    static func retryWhileBusy<T>(attempts: Int = 40, delayMs: UInt32 = 25, _ body: () throws -> T) throws -> T {
        var n = 0
        while true {
            do { return try body() } catch let e as SQLiteError where e.isBusy && n < attempts {
                n += 1
                usleep(delayMs * 1000 + UInt32.random(in: 0..<(delayMs * 500)))
            }
        }
    }

    /// `application_id` guards against somebody else's SQLite file at our path;
    /// the `user_version` comparison against the newest migration is the
    /// downgrade guard.
    private static func checkIdentity(_ c: SQLiteConnection, known: Int) throws {
        // ONE statement = ONE read snapshot. Three separate reads raced a
        // concurrent first-time migration (application_id read before its
        // commit, table count after), classified a live database as foreign and
        // quarantined it from under the other opener.
        let (appID, version, tables) = try c.withTemporaryStatement("""
            SELECT (SELECT application_id FROM pragma_application_id),
                   (SELECT user_version FROM pragma_user_version),
                   (SELECT count(*) FROM sqlite_master)
            """) { s -> (Int, Int, Int) in
            guard try s.step() else { return (0, 0, 0) }
            return (Int(s.int64(0)), Int(s.int64(1)), Int(s.int64(2)))
        }
        if appID != 0 && appID != Int(HistorySchema.applicationID) { throw HistoryStoreError.foreignDatabase(applicationID: appID) }
        if version > known { throw HistoryStoreError.schemaTooNew(found: version, supported: known) }
        if appID == 0 && version == 0 && tables > 0 { throw HistoryStoreError.foreignDatabase(applicationID: 0) }
    }

    /// Runtime recovery, used by `HistoryStore.guarded` when a statement
    /// reports corruption long after open (a page smashed in the middle of the
    /// file is only noticed when something reads it). Closes the connection,
    /// moves the files aside and creates a fresh database on the SAME lock, so
    /// no second instance can slip in between. Instance method on purpose:
    /// only the process that holds the lock can call it.
    ///
    /// What is lost: the file watermarks go with the old database, so the next
    /// scan re-ingests everything from the usage cache (AMCU); quota and event
    /// samples older than AMCU's reach, and rows of transcripts Claude Code has
    /// deleted, are gone. The status says so.
    @discardableResult
    func recreateAfterCorruption(reason: String) throws -> HistoryRecovery {
        conn.close()
        let moved = try Self.quarantine(config)
        conn = try Self.openFresh(config)
        let report = HistoryRecovery(reason: reason, quarantinedTo: moved, at: config.clock())
        recovery = report
        return report
    }

    // MARK: Maintenance helpers and inspection

    /// `PRAGMA integrity_check` on a SEPARATE read-only connection, so it can
    /// never share a statement or a transaction with the writer. `["ok"]` is a
    /// healthy file. It is the only detector for index/table disagreement
    /// (`quick_check` skips the cross-check), costs about 1.3 s per 100 MB, and
    /// in WAL mode its reader pins a snapshot for that long, which is why the
    /// store only ever runs `wal_checkpoint(PASSIVE)`. A SQLITE_CORRUPT or NOTADB
    /// thrown by the check itself is returned as the finding. Blocking: call it off
    /// the store actor (`HistoryStore.runIntegrityCheck` does). When it runs
    /// (weekly, and once after an unclean shutdown) is `HistoryStore.maintainIfDue`'s call.
    static func runIntegrityCheck(at url: URL, limit: Int = 5) throws -> [String] {
        var options = SQLiteOpenOptions()
        options.readOnly = true
        let reader = try SQLiteConnection(path: url.path, options: options)
        defer { reader.close() }
        do {
            return try reader.queryTexts("PRAGMA integrity_check(\(limit))")
        } catch let error as SQLiteError where error.isCorruption {
            // On a badly damaged file the check itself fails with CORRUPT instead of
            // listing findings. That is a finding too: `["ok"]` stays the only healthy answer.
            return ["\(error.message)"]
        }
    }

    func runIntegrityCheck(limit: Int = 5) throws -> [String] {
        try Self.runIntegrityCheck(at: config.url, limit: limit)
    }

    func userVersion() throws -> Int { Int(try conn.queryInt("PRAGMA user_version") ?? 0) }

    /// Switches the zone that new rows' `acct_day` and `ensureMeta` use. The
    /// store calls it when the system zone changed and then runs `ensureMeta`
    /// in one transaction, which recomputes every stored `acct_day` before
    /// anything else is applied or read.
    func useAccountingTimeZone(_ zone: TimeZone) { config.timeZone = zone }

    func walSizeBytes() -> Int { Self.walSize(of: config.url) }

    func fileSizeBytes() -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: config.url.path)[.size] as? Int) ?? nil) ?? 0
    }

    private static func walSize(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? nil) ?? 0
    }

    /// Closes the connection, then releases the lock. The order matters: a
    /// second instance must never get in while our handle is still open.
    func close() {
        conn.close()
        lock = nil
    }
}
