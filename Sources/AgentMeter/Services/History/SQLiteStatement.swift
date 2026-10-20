import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` is the C macro `((sqlite3_destructor_type)-1)` and is not
/// imported into Swift. The destructor type is a `@convention(c)` function
/// type, which is implicitly Sendable, so a plain global `let` passes strict
/// concurrency without `nonisolated(unsafe)`.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value that can sit in any column; used for ad-hoc binds and in tests.
enum SQLiteValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
    case null
}

/// A prepared statement. Deliberately NOT Sendable: it lives and dies inside
/// the isolation domain of the connection that prepared it (the store actor).
///
/// Rules baked in, each one learnt from a failure in testing:
///  * `deinit` finalizes, so a throw anywhere cannot leak a statement.
///  * `SQLiteConnection.withStatement` resets (and clears bindings) in a
///    `defer`. A statement that stopped halfway through its rows keeps a read
///    snapshot open, which pins the WAL and blocks every checkpoint.
///  * Binds never throw: the first failing bind is remembered and thrown by
///    `step()`, which keeps the per-row hot path free of `try`.
///  * Never hold a statement across an `await`: the actor is reentrant and the
///    next caller may reset the same cached statement under you.
///  * Never nest `withStatement` with the same SQL text: the inner call would
///    reset the cached statement under the outer user.
final class SQLiteStatement {
    private(set) var raw: OpaquePointer?
    let sql: String
    private var bindError: Int32 = SQLITE_OK

    /// Created by `SQLiteConnection.prepare` only.
    init(raw: OpaquePointer, sql: String) {
        self.raw = raw
        self.sql = sql
    }

    deinit { sqlite3_finalize(raw) }

    // MARK: Binds (1-based, like sqlite3_bind_*)

    @inline(__always) private func note(_ rc: Int32) {
        if rc != SQLITE_OK && bindError == SQLITE_OK { bindError = rc }
    }

    func bind(_ i: Int32, _ v: Int64) { note(sqlite3_bind_int64(raw, i, v)) }
    func bind(_ i: Int32, _ v: Int) { note(sqlite3_bind_int64(raw, i, Int64(v))) }
    func bind(_ i: Int32, _ v: Int32) { note(sqlite3_bind_int64(raw, i, Int64(v))) }
    /// SQLite has no unsigned 64-bit type, and `Int64(v)` traps above
    /// `Int64.max`. The bit pattern is stored instead (file ids, volume ids),
    /// so a round trip is `UInt64(bitPattern: int64)`. Order comparisons in
    /// SQL see the signed value.
    func bind(_ i: Int32, _ v: UInt64) { note(sqlite3_bind_int64(raw, i, Int64(bitPattern: v))) }
    /// NaN is stored as NULL by SQLite, so callers must not rely on it.
    func bind(_ i: Int32, _ v: Double) { note(sqlite3_bind_double(raw, i, v)) }
    func bindNull(_ i: Int32) { note(sqlite3_bind_null(raw, i)) }

    /// Binds with an explicit byte count, so an embedded NUL survives.
    func bind(_ i: Int32, _ v: String) {
        var s = v
        let rc = s.withUTF8 { buf -> Int32 in
            // `withUTF8` on an empty string may hand back a nil base address:
            // bind '' explicitly rather than let it become NULL.
            guard let base = buf.baseAddress else { return sqlite3_bind_text(raw, i, "", 0, sqliteTransient) }
            return base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                sqlite3_bind_text(raw, i, $0, Int32(buf.count), sqliteTransient)
            }
        }
        note(rc)
    }

    /// An empty blob must go through `zeroblob(0)`: binding a nil pointer
    /// would store NULL, and a NOT NULL key column would reject it.
    func bind(_ i: Int32, blob v: UnsafeRawBufferPointer) {
        guard let base = v.baseAddress, !v.isEmpty else { note(sqlite3_bind_zeroblob(raw, i, 0)); return }
        note(sqlite3_bind_blob(raw, i, base, Int32(v.count), sqliteTransient))
    }
    func bind(_ i: Int32, blob v: [UInt8]) { v.withUnsafeBytes { bind(i, blob: $0) } }
    func bind(_ i: Int32, blob v: Data) { v.withUnsafeBytes { bind(i, blob: $0) } }

    func bind(_ i: Int32, _ v: SQLiteValue) {
        switch v {
        case let .int(x): bind(i, x)
        case let .double(x): bind(i, x)
        case let .text(x): bind(i, x)
        case let .blob(x): bind(i, blob: x)
        case .null: bindNull(i)
        }
    }

    /// Binds `values` to parameters 1...n.
    func bind(_ values: [SQLiteValue]) {
        for (n, v) in values.enumerated() { bind(Int32(n + 1), v) }
    }

    // MARK: Stepping

    /// `true` = a row is available, `false` = `SQLITE_DONE`.
    @discardableResult
    func step() throws -> Bool {
        if bindError != SQLITE_OK {
            let rc = bindError
            bindError = SQLITE_OK
            throw SQLiteError(handle: sqlite3_db_handle(raw), rc: rc, context: "bind", sql: sql)
        }
        let rc = sqlite3_step(raw)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(handle: sqlite3_db_handle(raw), rc: rc, context: "step", sql: sql)
        }
    }

    /// Rewinds and drops the bindings. Safe at any time, also after a failed step.
    func reset() {
        sqlite3_reset(raw)
        sqlite3_clear_bindings(raw)
        bindError = SQLITE_OK
    }

    /// Cheaper than `reset()` in a per-row loop: rewinds but keeps the
    /// bindings, for callers that rebind every parameter anyway.
    @inline(__always) func rewind() { sqlite3_reset(raw) }

    var isBusy: Bool { sqlite3_stmt_busy(raw) != 0 }

    // MARK: Columns (0-based, like sqlite3_column_*)

    func int64(_ c: Int32) -> Int64 { sqlite3_column_int64(raw, c) }
    func uint64(_ c: Int32) -> UInt64 { UInt64(bitPattern: sqlite3_column_int64(raw, c)) }
    func double(_ c: Int32) -> Double { sqlite3_column_double(raw, c) }
    func isNull(_ c: Int32) -> Bool { sqlite3_column_type(raw, c) == SQLITE_NULL }

    /// Decoded by byte count: `String(cString:)` would stop at an embedded NUL.
    func text(_ c: Int32) -> String? {
        guard sqlite3_column_type(raw, c) != SQLITE_NULL, let p = sqlite3_column_text(raw, c) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(raw, c))), as: UTF8.self)
    }

    func blob(_ c: Int32) -> [UInt8]? {
        guard sqlite3_column_type(raw, c) != SQLITE_NULL else { return nil }
        let n = Int(sqlite3_column_bytes(raw, c))
        guard n > 0, let p = sqlite3_column_blob(raw, c) else { return [] }
        return Array(UnsafeRawBufferPointer(start: p, count: n))
    }
}
