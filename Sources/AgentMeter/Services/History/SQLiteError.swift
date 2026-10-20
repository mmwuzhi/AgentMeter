import Foundation
import SQLite3

/// `SQLITE_IOERR_SHORT_READ` is `SQLITE_IOERR | (2 << 8)` (= 522). SQLite's
/// compound result codes are C macros built with shifts, which Swift does not
/// import, so every compound code the store cares about is spelled out here.
/// A truncated database file answers page reads with this code.
let sqliteIOErrShortRead: Int32 = SQLITE_IOERR | (2 << 8)
/// `SQLITE_IOERR_VNODE` (27 << 8): the file under an open handle was deleted
/// or moved, or its volume went away. What Apple's SQLite answers when the
/// database is deleted while the app runs.
let sqliteIOErrVnode: Int32 = SQLITE_IOERR | (27 << 8)

/// A SQLite failure with the codes and the message captured at the moment it
/// happened. `sqlite3_errmsg` is only valid until the next call on the same
/// handle, so the text is copied into the error right away.
struct SQLiteError: Error, Sendable, CustomStringConvertible {
    /// Primary result code (`extended & 0xFF`), e.g. `SQLITE_CORRUPT` (11).
    let code: Int32
    /// Extended result code, e.g. `SQLITE_CONSTRAINT_PRIMARYKEY` (1555) or
    /// `SQLITE_CONSTRAINT_UNIQUE` (2067).
    let extendedCode: Int32
    let message: String
    /// Which call failed: `open`, `prepare`, `step`, `exec`, `bind`, `close`,
    /// `checkpoint`, `pragma`.
    let context: String
    let sql: String?

    init(code: Int32, extendedCode: Int32? = nil, message: String, context: String, sql: String? = nil) {
        self.code = code & 0xFF
        self.extendedCode = extendedCode ?? code
        self.message = message
        self.context = context
        self.sql = sql
    }

    /// Reads the error off a connection handle right after a failing call.
    /// `rc` is the return code of that call; it is all there is when the
    /// handle is nil (an out-of-memory `sqlite3_open_v2`).
    init(handle: OpaquePointer?, rc: Int32, context: String, sql: String? = nil) {
        if let handle {
            self.init(
                code: rc & 0xFF,
                extendedCode: sqlite3_extended_errcode(handle),
                message: String(cString: sqlite3_errmsg(handle)),
                context: context,
                sql: sql
            )
        } else {
            self.init(code: rc & 0xFF, extendedCode: rc, message: String(cString: sqlite3_errstr(rc)),
                      context: context, sql: sql)
        }
    }

    /// The file is not a database, or its pages are malformed: quarantine it
    /// and start a fresh one. `NOTADB` is what garbage answers on the first
    /// statement, `CORRUPT` what a truncated file or a smashed page answers,
    /// and `IOERR_SHORT_READ` what a file shorter than its header claims
    /// answers on some page reads.
    var isCorruption: Bool {
        code == SQLITE_CORRUPT || code == SQLITE_NOTADB || extendedCode == sqliteIOErrShortRead
    }
    var isBusy: Bool { code == SQLITE_BUSY || code == SQLITE_LOCKED }
    var isDiskFull: Bool { code == SQLITE_FULL }
    var isReadOnly: Bool { code == SQLITE_READONLY }
    /// The open handle is of no use any more: the file went read-only under
    /// it, or was deleted or moved (`SQLITE_READONLY_DBMOVED`, `IOERR_VNODE`),
    /// so every later write (and, for a deleted file, read) on it fails. Close
    /// it and reopen later; the reopen gets the file now at the path.
    var isDefunctHandle: Bool { isReadOnly || extendedCode == sqliteIOErrVnode }
    var isConstraint: Bool { code == SQLITE_CONSTRAINT }
    /// Permissions, a missing directory, no space: rebuilding the file would
    /// not help, so these never trigger a quarantine.
    var isEnvironmental: Bool {
        code == SQLITE_CANTOPEN || code == SQLITE_PERM || code == SQLITE_FULL || code == SQLITE_READONLY
            || (code == SQLITE_IOERR && extendedCode != sqliteIOErrShortRead)
    }

    var description: String {
        "SQLiteError(\(context) code=\(code) ext=\(extendedCode): \(message)\(sql.map { " | \($0.prefix(120))" } ?? ""))"
    }

    /// For the log: the codes and the failing call only. The message can name
    /// a path and the SQL can carry a literal, so neither is logged.
    var logReason: String { "sqlite(\(context) code=\(code) ext=\(extendedCode))" }
}

/// Which step of taking `<db>.lock` failed (see `HistoryStoreError.lockUnavailable`).
enum HistoryLockStep: String, Sendable {
    /// Creating the database directory.
    case directory
    /// Opening (creating) the lock file.
    case lockFile
    /// `flock` on the open lock file.
    case flock
}

/// Store-level failures that are not a raw SQLite error.
enum HistoryStoreError: Error, Sendable, CustomStringConvertible {
    /// The file was written by a newer build (`user_version` above the last
    /// known migration). Nothing was modified, nothing is quarantined: moving
    /// it aside would hide the newer build's data from itself.
    case schemaTooNew(found: Int, supported: Int)
    /// A valid SQLite file with another `application_id`, or tables but no
    /// version stamp: somebody else's file at our path.
    case foreignDatabase(applicationID: Int)
    case migrationFailed(version: Int, name: String, underlying: SQLiteError)
    /// Quarantine, or creating the fresh file afterwards, failed (disk full,
    /// permissions). The app runs without history.
    case unrecoverable(SQLiteError)
    /// The file was found damaged and was replaced by an empty database. The
    /// operation that found it did not run; its data re-arrives from the next
    /// scan because the file watermarks went with the old database.
    case rebuilt(quarantinedTo: URL?)
    /// Another process holds `<db>.lock` (an old AgentMeter still quitting
    /// during a Sparkle relaunch, or `make run` next to the installed app).
    case lockedByAnotherInstance
    /// The directory or `<db>.lock` could not be created, or `flock` failed,
    /// for a reason other than another holder. Retried after the interval,
    /// never latched for good: a full disk, a descriptor shortage or a
    /// permission fix heals without a restart, and a volume without `flock`
    /// (ENOTSUP) costs one failed syscall per retry.
    case lockUnavailable(step: HistoryLockStep, errno: Int32)
    /// The linked SQLite predates STRICT tables.
    case sqliteTooOld(found: Int, required: Int)
    /// After `HistoryStore.shutdown()` (or a plain `close()` seen by a scan
    /// that was running): nothing is applied any more.
    case closed

    /// ENOSPC, EDQUOT, EMFILE, ENFILE, ENOMEM, EINTR: the condition passes by
    /// itself. Only the reason's wording depends on it; every lock failure retries.
    static func isTransient(errno code: Int32) -> Bool {
        [ENOSPC, EDQUOT, EMFILE, ENFILE, ENOMEM, EINTR].contains(code)
    }

    private static func errnoName(_ code: Int32) -> String {
        switch code {
        case ENOSPC: "ENOSPC"
        case EDQUOT: "EDQUOT"
        case EMFILE: "EMFILE"
        case ENFILE: "ENFILE"
        case ENOMEM: "ENOMEM"
        case EINTR: "EINTR"
        case ENOTSUP: "ENOTSUP"
        case EOPNOTSUPP: "EOPNOTSUPP"
        case EACCES: "EACCES"
        case EPERM: "EPERM"
        case EROFS: "EROFS"
        case ENOENT: "ENOENT"
        case ENOTDIR: "ENOTDIR"
        default: "errno \(code)"
        }
    }

    var description: String {
        switch self {
        case let .schemaTooNew(found, supported): "schemaTooNew(found=\(found), supported=\(supported))"
        case let .foreignDatabase(id): "foreignDatabase(application_id=\(id))"
        case let .migrationFailed(v, n, e): "migrationFailed(v\(v) \(n): \(e))"
        case let .unrecoverable(e): "unrecoverable(\(e))"
        case let .rebuilt(url): "rebuilt(quarantinedTo=\(url?.lastPathComponent ?? "nil"))"
        case .lockedByAnotherInstance: "lockedByAnotherInstance"
        case let .lockUnavailable(step, code): "lockUnavailable(\(step.rawValue): \(Self.lockDetail(code)))"
        case let .sqliteTooOld(found, required): "sqliteTooOld(found=\(found), required=\(required))"
        case .closed: "closed"
        }
    }

    private static func lockDetail(_ code: Int32) -> String {
        if code == ENOTSUP || code == EOPNOTSUPP { return "\(errnoName(code)), the volume does not support flock" }
        return errnoName(code) + (isTransient(errno: code) ? ", transient" : "")
    }

    /// For the log: the case and its numbers, never a path or a message.
    var logReason: String {
        switch self {
        case let .migrationFailed(v, _, e): "migrationFailed(v\(v), \(e.logReason))"
        case let .unrecoverable(e): "unrecoverable(\(e.logReason))"
        default: description
        }
    }

    /// `logReason` of any error the store meets.
    static func logReason(_ error: any Error) -> String {
        if let e = error as? HistoryStoreError { return e.logReason }
        if let e = error as? SQLiteError { return e.logReason }
        return String(describing: type(of: error))
    }
}
