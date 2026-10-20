import Foundation

// meta, the accounting zone, maintenance and the explicit request rebuild.

enum HistoryMaintenance {
    /// Maintenance runs at most this often (`meta.last_maintenance_ms`).
    static let interval: Int64 = 24 * 3_600_000
    /// `integrity_check` at most this often (`meta.last_integrity_check_ms`),
    /// plus once after an unclean shutdown.
    static let integrityInterval: Int64 = 7 * 24 * 3_600_000
    /// `meta.ingest_version`: the version of the store's own merge logic (the
    /// `rec_sig` and `att_sig` encodings and the merge rules), so a later build
    /// can tell which logic derived the stored rows. The per-row
    /// `ingest_version` column is the AMCU parser version of the observation
    /// instead.
    static let ingestLogicVersion: Int64 = 1
}

/// What one `runMaintenance` call did.
struct HistoryMaintenanceOutcome: Sendable, Equatable {
    var ran = false
    var prunedQuotaSamples = 0
    var prunedResetEvents = 0
    /// `ingest_scan` rows of windowed scans past `windowedScanDays`.
    var prunedWindowedScans = 0
    /// `ingest_scan` rows of complete-history scans past `quotaSampleDays`.
    var prunedCompleteScans = 0
    /// The weekly integrity check is due (the store runs it off its executor).
    var integrityCheckDue = false
}

extension HistoryDatabase {
    // MARK: meta

    func metaInt(_ key: String) throws -> Int64? {
        try conn.withStatement("SELECT value FROM meta WHERE key = ?1") { s in
            s.bind(1, key)
            return try s.step() ? s.optionalInt64(0) : nil
        }
    }

    func metaText(_ key: String) throws -> String? {
        try conn.withStatement("SELECT value FROM meta WHERE key = ?1") { s in
            s.bind(1, key)
            return try s.step() ? s.text(0) : nil
        }
    }

    func setMeta(_ key: String, _ value: SQLiteValue) throws {
        try conn.withStatement("""
            INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """) { s in
            s.bind(1, key)
            s.bind(2, value)
            try s.step()
        }
    }

    /// Sets an integer meta value only when it grows (coverage never moves back).
    func advanceMeta(_ key: String, to value: Int64) throws {
        if let current = try metaInt(key), current >= value { return }
        try setMeta(key, .int(value))
    }

    func incrementMeta(_ key: String, by n: Int64) throws {
        guard n != 0 else { return }
        try setMeta(key, .int((try metaInt(key) ?? 0) + n))
    }

    /// Seeds meta on a new database and switches the accounting zone when the
    /// configured one differs from the stored one. Call inside a transaction.
    func ensureMeta() throws {
        let zone = config.timeZone.identifier
        if try metaInt("created_ms") == nil {
            let now = HistoryTime.ms(config.clock())
            try setMeta("created_ms", .int(now))
            try setMeta("schema_writer_app_version", .text(config.appVersion))
            try setMeta("ingest_version", .int(HistoryMaintenance.ingestLogicVersion))
            // A new file has nothing to prune and nothing to check: the first
            // maintenance is due a day later, the first integrity check a week later.
            try setMeta("last_maintenance_ms", .int(now))
            try setMeta("last_integrity_check_ms", .int(now))
        }
        guard let stored = try metaText("acct_tz") else {
            try setMeta("acct_tz", .text(zone))
            return
        }
        if stored != zone { try rebuildAccountingDays(timeZone: config.timeZone) }
    }

    /// Recomputes every `acct_day` under `timeZone` and switches `meta.acct_tz`,
    /// in the caller's ONE transaction (no yield, so no ingest can interleave
    /// and leave rows on the old zone). One UPDATE per local day present.
    func rebuildAccountingDays(timeZone: TimeZone) throws {
        let firsts = try conn.withTemporaryStatement("""
            SELECT DISTINCT first_seen_ms FROM request WHERE first_seen_ms IS NOT NULL ORDER BY first_seen_ms
            """) { s -> [Int64] in
            var out: [Int64] = []
            while try s.step() { out.append(s.int64(0)) }
            return out
        }
        var days = HistoryAccountingDays(timeZone: timeZone)
        var runs: [(lo: Int64, hi: Int64, day: Int64)] = []
        for ms in firsts {
            guard let day = days.day(ms) else { continue }
            if let last = runs.last, last.day == day { runs[runs.count - 1].hi = ms } else { runs.append((ms, ms, day)) }
        }
        for run in runs {
            try conn.withStatement("""
                UPDATE request SET acct_day = ?3 WHERE first_seen_ms BETWEEN ?1 AND ?2 AND acct_day IS NOT ?3
                """) { s in
                s.bind(1, run.lo)
                s.bind(2, run.hi)
                s.bind(3, run.day)
                try s.step()
            }
        }
        try setMeta("acct_tz", .text(timeZone.identifier))
    }

    // MARK: Maintenance

    /// At most once a day: prune quota samples, reset events and the scan
    /// coverage rows older than the retention, `PRAGMA optimize`. Request,
    /// occurrence, file, session and event rows are never deleted.
    /// Runs its own transaction (the caller holds none). Reports whether the
    /// weekly integrity check is due; the store runs that on its own reader.
    func runMaintenance(now: Date) throws -> HistoryMaintenanceOutcome {
        var outcome = HistoryMaintenanceOutcome()
        let nowMs = HistoryTime.ms(now)
        if let last = try metaInt("last_maintenance_ms"), nowMs - last < HistoryMaintenance.interval, nowMs >= last {
            return outcome
        }
        outcome.ran = true
        try conn.transaction(.immediate) {
            if let days = config.retention.quotaSampleDays {
                let cutoff = nowMs - Int64(days) * 86_400_000
                try conn.withStatement("DELETE FROM quota_sample WHERE reading_ms < ?1") { s in
                    s.bind(1, cutoff)
                    try s.step()
                }
                outcome.prunedQuotaSamples = Int(conn.lastChanges)
                try conn.withStatement("DELETE FROM reset_event WHERE detected_ms < ?1") { s in
                    s.bind(1, cutoff)
                    try s.step()
                }
                outcome.prunedResetEvents = Int(conn.lastChanges)
                try conn.withStatement("DELETE FROM ingest_scan WHERE complete = 1 AND started_ms < ?1") { s in
                    s.bind(1, cutoff)
                    try s.step()
                }
                outcome.prunedCompleteScans = Int(conn.lastChanges)
            }
            if let days = config.retention.windowedScanDays {
                try conn.withStatement("DELETE FROM ingest_scan WHERE complete = 0 AND started_ms < ?1") { s in
                    s.bind(1, nowMs - Int64(days) * 86_400_000)
                    try s.step()
                }
                outcome.prunedWindowedScans = Int(conn.lastChanges)
            }
            try setMeta("last_maintenance_ms", .int(nowMs))
        }
        try conn.exec("PRAGMA optimize")
        let lastCheck = try metaInt("last_integrity_check_ms")
        outcome.integrityCheckDue = lastCheck.map { nowMs - $0 >= HistoryMaintenance.integrityInterval || nowMs < $0 } ?? true
        return outcome
    }

    // MARK: Explicit rebuild of the request tables

    /// Deletes every request, occurrence and scan-coverage row and clears every
    /// file watermark, so the next scan re-ingests every file whole from AMCU.
    /// Explicit only (a parser fix that must correct timestamps); never called
    /// automatically: rows of transcripts already deleted from disk are lost.
    /// Files, sessions, birth times and events stay. One transaction.
    func rebuildRequests() throws {
        try conn.transaction(.immediate) {
            try conn.exec("DELETE FROM request")
            try conn.exec("DELETE FROM request_occurrence")
            try conn.exec("DELETE FROM ingest_scan")
            try conn.exec("""
                UPDATE source_file SET file_id = NULL, volume_id = NULL, size = NULL, mtime = NULL,
                    parsed_bytes = NULL, boundary_digest = NULL, parser_version = 0, ingested_ms = NULL
                """)
            try conn.exec("DELETE FROM meta WHERE key IN ('complete_scan_ms', 'latest_scan_ms')")
        }
    }
}
