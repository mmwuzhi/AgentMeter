import Foundation
import SQLite3

// The actor-level drivers of the write hooks. A scan is driven by
// `HistoryStore+Scan.swift` (one transaction per <= `scanChunkObservations`
// (1,000) observations, a yield between transactions); quota, legacy quota and
// reset grants each run inside ONE `BEGIN IMMEDIATE` transaction and never
// suspend; maintenance runs after every scan, outside a transaction, and its
// failure never fails the scan.
extension HistoryStore {
    /// Quota, legacy quota and reset grants (the drain applies a scan through
    /// `applyScanCommand`). Synchronous on purpose: `shutdown()` applies the
    /// queued ones without giving a scan in flight a chance to run in between.
    func applyRecord(_ command: Command) throws {
        switch command {
        case let .quota(rows):
            try applyQuotaCommand(rows)
        case let .legacyQuota(rows):
            try guarded { db in
                try prepareDatabase(db)
                let outcome = try db.conn.transaction(.immediate) { try db.applyLegacyQuota(rows) }
                counters.skippedInvalidEvents += outcome.invalid
                // Imported rows may be newer than what the thinning state was seeded with.
                memory.thinning = QuotaThinningState()
            }
        case let .resetGrants(grants, recordedMs):
            try guarded { db in
                try prepareDatabase(db)
                _ = try db.conn.transaction(.immediate) { try db.applyResetGrants(grants, recordedMs: recordedMs) }
            }
        case .scan, .barrier, .custom:
            break   // the scan driver and the drain handle these
        }
    }

    /// Memory in step with the open connection; meta seeded once per open;
    /// and the accounting zone re-read from `timeZoneSource` on EVERY call.
    /// A zone other than the database's (a relaunch in another zone, or the
    /// system zone changed while the app runs) recomputes every `acct_day` in
    /// ONE transaction before anything else is applied or read, so the days
    /// agree with the usage ledger's `Calendar.current` days. Cheap when
    /// nothing changed: one zone read and a string compare. Every write
    /// command and every read wrapper (`HistoryStore+Queries.swift`) calls it.
    func prepareDatabase(_ db: HistoryDatabase) throws {
        syncMemory()
        if adoptCurrentTimeZone(db) { memory.metaReady = false }
        guard !memory.metaReady else { return }
        try db.conn.transaction(.immediate) { try db.ensureMeta() }
        memory.metaReady = true
    }

    func applyQuotaCommand(_ rows: [QuotaSampleRow]) throws {
        try guarded { db in
            try prepareDatabase(db)
            var thinning = memory.thinning
            let outcome = try db.conn.transaction(.immediate) { try db.applyQuota(rows, thinning: &thinning) }
            memory.thinning = thinning               // only after the commit
            counters.skippedInvalidEvents += outcome.invalid
        }
    }

    // MARK: Maintenance

    /// At most once a day (the hook decides): prune, optimize. Weekly, and once
    /// after an unclean shutdown, `integrity_check` on the separate read-only
    /// connection off this executor; a failed check quarantines and rebuilds
    /// the database through `guarded` (status `.rebuilt`).
    func maintainIfDue() async {
        let now = clock()
        guard let outcome = try? guarded({ db in try db.runMaintenance(now: now) }) else { return }
        let unclean = ((try? guarded { $0.openedAfterUncleanShutdown }) ?? false) && !memory.uncleanCheckDone
        guard (outcome.ran && outcome.integrityCheckDue) || unclean else { return }
        memory.uncleanCheckDone = true
        counters.integrityChecks += 1
        guard let findings = try? await runIntegrityCheck() else { return }
        if findings == ["ok"] {
            _ = try? guarded { db in try db.setMeta("last_integrity_check_ms", .int(HistoryTime.ms(now))) }
            return
        }
        counters.failedIntegrityChecks += 1
        let reason = "integrity_check: " + findings.prefix(3).joined(separator: "; ")
        _ = try? guarded { _ -> Void in
            throw SQLiteError(code: SQLITE_CORRUPT, message: reason, context: "integrity_check")
        }
    }

    // MARK: Explicit rebuilds

    /// Truncates the request tables and every watermark; the next scan
    /// re-ingests every file whole. Never automatic. Private: as an isolated
    /// call it could land between two chunks of a scan, which would then write
    /// a watermark claiming a whole file whose earlier pieces were just
    /// deleted. Only `submitRebuildRequests()` reaches it, in inbox order.
    private func rebuildRequests() throws {
        try guarded { db in
            try prepareDatabase(db)
            try db.rebuildRequests()
        }
        memory.scanTickets = [:]
    }

    /// Queues the request rebuild behind everything submitted before it, so
    /// it runs between two commands, never inside a scan.
    nonisolated func submitRebuildRequests() {
        enqueue { store in try store.rebuildRequests() }
    }

    /// Re-derives `reset_event` from the stored Claude OAuth samples.
    @discardableResult
    func rebuildResetEvents() throws -> Int {
        try guarded { db in
            try prepareDatabase(db)
            return try db.conn.transaction(.immediate) { try db.rebuildResetEvents() }
        }
    }
}
