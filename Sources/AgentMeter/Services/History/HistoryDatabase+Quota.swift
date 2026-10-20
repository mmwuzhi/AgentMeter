import Foundation

// Quota samples: natural key (provider, window_id, source, reading_ms), first
// writer wins, conflicts counted on measured fields only, thinning on the
// arrival stream, reset events from consecutive stored Claude OAuth samples.
// Every hook here runs inside the store's transaction.

/// What one quota hook call did (tests and statistics read it).
struct HistoryQuotaOutcome: Sendable, Equatable {
    var stored = 0
    /// Readings that added nothing (unchanged, newer, < heartbeat) and were not written.
    var thinned = 0
    /// Rows whose natural key was already stored with the same measured values.
    var duplicates = 0
    /// Rows whose natural key was stored with a different measured value (first writer kept).
    var conflicts = 0
    /// Providers outside the allowlist.
    var notIngested = 0
    /// Rows with a non-finite number or an unusable time.
    var invalid = 0
    var resetEvents = 0
}

enum HistoryQuotaRules {
    /// An unchanged window is written again after this long (a heartbeat).
    static let heartbeatMs: Int64 = 10 * 60_000

    /// A row with an empty window, a non-finite number or a time the store
    /// does not keep (`HistoryTime.isStorable`) is counted invalid, never stored.
    static func isValid(_ r: QuotaSampleRow) -> Bool {
        func finite(_ v: Double?) -> Bool { v.map(\.isFinite) ?? true }
        let times = [r.readingMs, r.recordedMs, r.resetsAtMs, r.fetchedMs, r.cachedMs]
        return !r.windowID.isEmpty && times.allSatisfy(HistoryTime.isStorable)
            && finite(r.usedPercent) && finite(r.shareUsedOfWeekly) && finite(r.shareAllowanceOfWeekly)
    }

    /// The fields a conflicting second reading is judged on: the measurement
    /// (thinning fingerprint) and the scope, never `recorded_ms` / `fetched_ms`
    /// (a joined flight lands one reading twice with different landing times).
    static func measuredEqual(_ a: QuotaSampleRow, _ b: QuotaSampleRow) -> Bool {
        QuotaSampleFingerprint(a) == QuotaSampleFingerprint(b)
            && a.isModelScoped == b.isModelScoped && a.scopeName == b.scopeName
    }
}

extension HistoryDatabase {
    private static let quotaColumns = """
        q.provider, q.window_id, q.source, q.reading_ms, q.fetched_ms, q.cached_ms, q.recorded_ms, q.used_percent,
        q.resets_at_ms, q.cycle_s, q.scoped, q.one_time, q.is_active, q.severity, q.locked_reason, q.scope_name,
        q.share_used, q.share_allowance, p.value, t.value, q.flags
        FROM quota_sample q LEFT JOIN dict p ON p.id = q.plan_ref LEFT JOIN dict t ON t.id = q.tier_ref
        """

    private static func quotaRow(_ s: SQLiteStatement) -> QuotaSampleRow? {
        guard let provider = s.text(0).flatMap(Provider.init(rawValue:)),
              let source = s.text(2).flatMap(QuotaSampleSource.init(rawValue:)) else { return nil }
        return QuotaSampleRow(
            provider: provider, windowID: s.text(1) ?? "", source: source, readingMs: s.int64(3),
            fetchedMs: s.optionalInt64(4), cachedMs: s.optionalInt64(5), recordedMs: s.int64(6),
            usedPercent: s.optionalDouble(7), resetsAtMs: s.optionalInt64(8), cycleSeconds: s.optionalInt64(9).map(Int.init),
            isModelScoped: s.optionalBool(10), isOneTimeCredit: s.optionalBool(11), isActive: s.optionalBool(12),
            severity: s.text(13), lockedReason: s.text(14), scopeName: s.text(15), shareUsedOfWeekly: s.optionalDouble(16),
            shareAllowanceOfWeekly: s.optionalDouble(17), plan: s.text(18), tier: s.text(19),
            flags: QuotaSampleRow.Flags(rawValue: Int(s.int64(20))))
    }

    // MARK: Applying readings

    /// Stores landed readings, thinned per (provider, window, source) on the
    /// arrival stream. The caller owns `thinning` and keeps the mutated copy
    /// only if the transaction commits.
    func applyQuota(_ rows: [QuotaSampleRow], thinning: inout QuotaThinningState) throws -> HistoryQuotaOutcome {
        var out = HistoryQuotaOutcome()
        var ctx = makeIngestContext()
        for row in rows {
            guard config.quotaProviders.contains(row.provider) else { out.notIngested += 1; continue }
            guard HistoryQuotaRules.isValid(row) else { out.invalid += 1; continue }
            let key = QuotaThinningState.Key(provider: row.provider, windowID: row.windowID, source: row.source)
            var group = try thinning.groups[key] ?? QuotaThinningState.Group(lastStored: newestQuotaRow(key), skipped: nil)
            defer { thinning.groups[key] = group }
            guard let last = group.lastStored else {
                try store(row, &out, &ctx, countConflicts: true)
                group.lastStored = row
                continue
            }
            if row.readingMs <= last.readingMs {
                // Out of order or the same reading again: stored by its own key
                // (a joined flight dedupes there), the thinning state stays.
                try store(row, &out, &ctx, countConflicts: true)
                continue
            }
            let unchanged = QuotaSampleFingerprint(row) == QuotaSampleFingerprint(last)
            if unchanged && row.readingMs - last.readingMs < HistoryQuotaRules.heartbeatMs {
                // Keep the newest skipped reading (by reading time, not arrival).
                if group.skipped.map({ row.readingMs > $0.readingMs }) ?? true { group.skipped = row }
                out.thinned += 1
                continue
            }
            // A change (or the heartbeat). Before a change, the reading just
            // before it: the last reading without the change bounds when it happened.
            if !unchanged, let skipped = group.skipped, skipped.readingMs < row.readingMs {
                try store(skipped, &out, &ctx, countConflicts: true)
            }
            try store(row, &out, &ctx, countConflicts: true)
            group.lastStored = row
            group.skipped = nil
        }
        return out
    }

    /// Imports the legacy `quotaObservations` once per database: natural-key
    /// dedupe, no thinning (they were thinned when kept), no conflict counting
    /// (their values were clamped), reset detection for OAuth rows.
    func applyLegacyQuota(_ rows: [QuotaSampleRow]) throws -> HistoryQuotaOutcome {
        var out = HistoryQuotaOutcome()
        guard try metaInt("legacy_quota_imported") == nil else { return out }
        var ctx = makeIngestContext()
        let ordered = rows.sorted { ($0.windowID, $0.readingMs) < ($1.windowID, $1.readingMs) }
        for row in ordered {
            guard config.quotaProviders.contains(row.provider) else { out.notIngested += 1; continue }
            guard HistoryQuotaRules.isValid(row) else { out.invalid += 1; continue }
            try store(row, &out, &ctx, countConflicts: false)
        }
        try setMeta("legacy_quota_imported", .int(HistoryTime.ms(config.clock())))
        return out
    }

    private func store(_ row: QuotaSampleRow, _ out: inout HistoryQuotaOutcome, _ ctx: inout HistoryIngestContext,
                       countConflicts: Bool) throws {
        let plan = try labelID(.plan, row.plan, &ctx)
        let tier = try labelID(.tier, row.tier, &ctx)
        try conn.withStatement("""
            INSERT INTO quota_sample(provider, window_id, source, reading_ms, fetched_ms, cached_ms, recorded_ms,
                used_percent, resets_at_ms, reset_epoch_s, cycle_s, scoped, one_time, is_active, severity,
                locked_reason, scope_name, share_used, share_allowance, plan_ref, tier_ref, flags)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
            ON CONFLICT(provider, window_id, source, reading_ms) DO NOTHING
            """) { s in
            s.bind(1, row.provider.rawValue)
            s.bind(2, row.windowID)
            s.bind(3, row.source.rawValue)
            s.bind(4, row.readingMs)
            s.bind(5, row.fetchedMs)
            s.bind(6, row.cachedMs)
            s.bind(7, row.recordedMs)
            s.bind(8, row.usedPercent)
            s.bind(9, row.resetsAtMs)
            s.bind(10, row.resetEpochSeconds)
            s.bind(11, row.cycleSeconds.map(Int64.init))
            s.bind(12, row.isModelScoped)
            s.bind(13, row.isOneTimeCredit)
            s.bind(14, row.isActive)
            s.bind(15, row.severity)
            s.bind(16, row.lockedReason)
            s.bind(17, row.scopeName)
            s.bind(18, row.shareUsedOfWeekly)
            s.bind(19, row.shareAllowanceOfWeekly)
            s.bind(20, plan)
            s.bind(21, tier)
            s.bind(22, Int64(row.flags.rawValue))
            try s.step()
        }
        guard conn.lastChanges > 0 else {
            let existing = try quotaRow(provider: row.provider, windowID: row.windowID, source: row.source,
                                        readingMs: row.readingMs)
            if countConflicts, let existing, !HistoryQuotaRules.measuredEqual(existing, row) {
                out.conflicts += 1
                try incrementMeta("quota_conflicts", by: 1)
            } else {
                out.duplicates += 1
            }
            return
        }
        out.stored += 1
        guard row.provider == .claude, row.source == .oauth,
              let previous = try previousOAuthRow(windowID: row.windowID, before: row.readingMs),
              let draft = ResetDetector.draft(previous: previous, next: row) else { return }
        if try insertResetEvent(draft) { out.resetEvents += 1 }
    }

    private func quotaRow(provider: Provider, windowID: String, source: QuotaSampleSource,
                          readingMs: Int64) throws -> QuotaSampleRow? {
        try conn.withStatement("""
            SELECT \(Self.quotaColumns)
            WHERE q.provider = ?1 AND q.window_id = ?2 AND q.source = ?3 AND q.reading_ms = ?4
            """) { s in
            s.bind(1, provider.rawValue)
            s.bind(2, windowID)
            s.bind(3, source.rawValue)
            s.bind(4, readingMs)
            return try s.step() ? Self.quotaRow(s) : nil
        }
    }

    /// The group's newest stored row: where the thinning state starts after a launch.
    func newestQuotaRow(_ key: QuotaThinningState.Key) throws -> QuotaSampleRow? {
        try conn.withStatement("""
            SELECT \(Self.quotaColumns)
            WHERE q.provider = ?1 AND q.window_id = ?2 AND q.source = ?3 ORDER BY q.reading_ms DESC LIMIT 1
            """) { s in
            s.bind(1, key.provider.rawValue)
            s.bind(2, key.windowID)
            s.bind(3, key.source.rawValue)
            return try s.step() ? Self.quotaRow(s) : nil
        }
    }

    private func previousOAuthRow(windowID: String, before readingMs: Int64) throws -> QuotaSampleRow? {
        try conn.withStatement("""
            SELECT \(Self.quotaColumns)
            WHERE q.provider = 'claude' AND q.source = 'oauth' AND q.window_id = ?1 AND q.reading_ms < ?2
            ORDER BY q.reading_ms DESC LIMIT 1
            """) { s in
            s.bind(1, windowID)
            s.bind(2, readingMs)
            return try s.step() ? Self.quotaRow(s) : nil
        }
    }

    @discardableResult
    private func insertResetEvent(_ d: ResetEventDraft) throws -> Bool {
        try conn.withStatement("""
            INSERT INTO reset_event(provider, window_id, kind, detected_ms, prev_sample_ms, prev_percent, new_percent,
                prev_epoch_s, new_epoch_s, detector_version)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) ON CONFLICT DO NOTHING
            """) { s in
            s.bind(1, d.provider.rawValue)
            s.bind(2, d.windowID)
            s.bind(3, d.kind.rawValue)
            s.bind(4, d.detectedMs)
            s.bind(5, d.prevSampleMs)
            s.bind(6, d.prevPercent)
            s.bind(7, d.newPercent)
            s.bind(8, d.prevEpochSeconds)
            s.bind(9, d.newEpochSeconds)
            s.bind(10, Int64(ResetDetector.detectorVersion))
            try s.step()
        }
        return conn.lastChanges > 0
    }

    /// Re-derives every reset event from the stored Claude OAuth samples, in
    /// reading order per window. Equals the incremental result for an in-order
    /// stream. Call inside a transaction. Returns the number of events.
    @discardableResult
    func rebuildResetEvents() throws -> Int {
        try conn.exec("DELETE FROM reset_event")
        let rows = try conn.withTemporaryStatement("""
            SELECT \(Self.quotaColumns)
            WHERE q.provider = 'claude' AND q.source = 'oauth' ORDER BY q.window_id, q.reading_ms
            """) { s -> [QuotaSampleRow] in
            var out: [QuotaSampleRow] = []
            while try s.step() { if let r = Self.quotaRow(s) { out.append(r) } }
            return out
        }
        var count = 0
        for (previous, next) in zip(rows, rows.dropFirst()) where previous.windowID == next.windowID {
            if let d = ResetDetector.draft(previous: previous, next: next), try insertResetEvent(d) { count += 1 }
        }
        return count
    }

    /// Claude OAuth samples of one window, in reading order. The ONLY reading
    /// a calibration may use: it always filters provider = 'claude' AND
    /// source = 'oauth' (legacy `unknown`, CLI echoes and other providers never match).
    func oauthSamples(window: String, fromMs: Int64 = .min, toMs: Int64 = .max) throws -> [QuotaSampleRow] {
        try conn.withStatement("""
            SELECT \(Self.quotaColumns)
            WHERE q.provider = 'claude' AND q.source = 'oauth' AND q.window_id = ?1
              AND q.reading_ms >= ?2 AND q.reading_ms <= ?3
            ORDER BY q.reading_ms
            """) { s in
            s.bind(1, window)
            s.bind(2, fromMs)
            s.bind(3, toMs)
            var out: [QuotaSampleRow] = []
            while try s.step() { if let r = Self.quotaRow(s) { out.append(r) } }
            return out
        }
    }
}
