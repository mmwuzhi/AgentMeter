import Foundation
import SQLite3

/// One forward-only schema step. `apply` runs inside `BEGIN IMMEDIATE ...
/// COMMIT` together with the `PRAGMA user_version = version` bump, so a
/// failure anywhere (a half-applied DDL batch included) rolls back both the
/// DDL and the version: SQLite DDL is transactional, and so is `user_version`.
///
/// Migrations are additive. An older build that meets a newer file refuses it
/// (`HistoryStoreError.schemaTooNew`) instead of downgrading, so there is no
/// per-version file name and no rename-aside.
struct HistoryMigration: Sendable {
    let version: Int
    let name: String
    let apply: @Sendable (SQLiteConnection) throws -> Void

    init(version: Int, name: String, apply: @escaping @Sendable (SQLiteConnection) throws -> Void) {
        self.version = version
        self.name = name
        self.apply = apply
    }
}

enum HistoryMigrator {
    /// Brings `db` to the last migration. Never writes when `user_version` is
    /// newer than the migrations know.
    static func run(_ db: SQLiteConnection, _ migrations: [HistoryMigration]) throws {
        // The list must be 1...n or the user_version arithmetic is meaningless.
        for (i, m) in migrations.enumerated() { precondition(m.version == i + 1, "migrations must be numbered 1...n") }
        let known = migrations.count

        func current() throws -> Int { Int(try db.queryInt("PRAGMA user_version") ?? 0) }

        let start = try current()
        if start > known { throw HistoryStoreError.schemaTooNew(found: start, supported: known) }

        for m in migrations where m.version > start {
            do {
                try db.transaction(.immediate) {
                    // Re-read under the write lock: another connection may have
                    // applied this step between the read above and BEGIN IMMEDIATE.
                    if try current() >= m.version { return }
                    try m.apply(db)
                    try db.setPragma("user_version", "\(m.version)")
                }
            } catch let e as SQLiteError {
                throw HistoryStoreError.migrationFailed(version: m.version, name: m.name, underlying: e)
            }
        }
        let end = try current()
        if end > known { throw HistoryStoreError.schemaTooNew(found: end, supported: known) }
    }
}
