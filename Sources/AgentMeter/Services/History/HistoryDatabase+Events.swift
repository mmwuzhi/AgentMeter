import Foundation

// The whole-file extras of a transcript: 429 limit events, /usage reports,
// cost states, compactions, and the session's first cwd. Keys and validation
// are in `HistoryEventCheck.swift`.
//
// A fork copies records into a new transcript with new uuids, so one event can
// arrive from several files with different uuid / session / agent / class.
// Keeping the first arrival (`ON CONFLICT DO NOTHING`) would make those
// columns depend on ingest order. Instead every keyed event row belongs to the
// copy in the file that ranks first by `HistoryFileRank` (the owner rule of the
// requests): a copy replaces the stored row only when its file ranks strictly
// better, the same file keeps it. Cost states have no per-copy columns except
// `after_ts_ms`, which merges as a NULL-aware MAX. Children (`usage_report_limit`,
// `cost_state_model`) are written only together with their winning parent.

extension HistoryDatabase {
    func applyEvents(_ e: HistoryFileEvents, file: HistoryRegisteredFile, _ ctx: inout HistoryIngestContext) throws {
        for event in e.limitEvents { try upsertLimitEvent(event, file: file, &ctx) }
        for report in e.usageReports { try upsertUsageReport(report, file: file, &ctx) }
        for state in e.costStates { try mergeCostState(state) }
        for compact in e.compactEvents { try upsertCompactEvent(compact, file: file) }
        if file.fileClass == Int64(HistoryFileClass.main.rawValue), let cwd = e.firstCwd {
            try foldFirstCwd(session: file.sessionRef, cwd: cwd, ms: e.firstCwdMs,
                             entrypoint: e.firstEntrypoint, ccVersion: e.firstCcVersion, &ctx)
        }
    }

    private enum Slot { case absent, replace, keep }

    /// Whether a copy from `file` goes into the row keyed `key` of `table`.
    private func slot(_ table: String, _ keyColumn: String, _ key: String, file: HistoryRegisteredFile) throws -> Slot {
        try conn.withStatement("""
            SELECT f.birth_ms, f.path FROM \(table) e LEFT JOIN source_file f ON f.file_ref = e.file_ref
            WHERE e.\(keyColumn) = ?1
            """) { s -> Slot in
            s.bind(1, key)
            guard try s.step() else { return .absent }
            if config.mergeMutations.contains(.firstArrivalEvents) { return .keep }
            guard let path = s.text(1) else { return .replace }      // no owning file recorded
            return file.rank < HistoryFileRank(birthMs: s.optionalInt64(0), path: path) ? .replace : .keep
        }
    }

    private func upsertLimitEvent(_ e: LimitEventObservation, file: HistoryRegisteredFile,
                                  _ ctx: inout HistoryIngestContext) throws {
        let key = HistoryEventCheck.limitKey(e)
        guard try slot("limit_event", "event_key", key, file: file) != .keep else { return }
        let cc = try labelID(.ccVersion, e.ccVersion, &ctx)
        try conn.withStatement("""
            INSERT INTO limit_event(event_key, uuid, request_id, session_ref, agent_id, class, ts_ms, window_id,
                status, resets_at_ms, reset_epoch_s, overage_status, overage_disabled_reason, is_using_overage,
                fallback_available, source, api_error, cc_version_ref, file_ref)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
            ON CONFLICT(event_key) DO UPDATE SET
                uuid = excluded.uuid, request_id = excluded.request_id, session_ref = excluded.session_ref,
                agent_id = excluded.agent_id, class = excluded.class, ts_ms = excluded.ts_ms,
                window_id = excluded.window_id, status = excluded.status, resets_at_ms = excluded.resets_at_ms,
                reset_epoch_s = excluded.reset_epoch_s, overage_status = excluded.overage_status,
                overage_disabled_reason = excluded.overage_disabled_reason, is_using_overage = excluded.is_using_overage,
                fallback_available = excluded.fallback_available, source = excluded.source,
                api_error = excluded.api_error, cc_version_ref = excluded.cc_version_ref, file_ref = excluded.file_ref
            """) { s in
            s.bind(1, key)
            s.bind(2, e.uuid)
            s.bind(3, e.requestID)
            s.bind(4, file.sessionRef)
            s.bind(5, file.agentID)
            s.bind(6, file.fileClass)
            s.bind(7, e.tsMs)
            s.bind(8, e.windowID)
            s.bind(9, e.status)
            s.bind(10, e.resetsAtMs)
            s.bind(11, HistoryEpoch.seconds(ms: e.resetsAtMs))
            s.bind(12, e.overageStatus)
            s.bind(13, e.overageDisabledReason)
            s.bind(14, e.isUsingOverage)
            s.bind(15, e.fallbackAvailable)
            s.bind(16, e.source)
            s.bind(17, e.apiError)
            s.bind(18, cc)
            s.bind(19, file.fileRef)
            try s.step()
        }
    }

    private func upsertUsageReport(_ r: UsageReportObservation, file: HistoryRegisteredFile,
                                   _ ctx: inout HistoryIngestContext) throws {
        let key = HistoryEventCheck.reportKey(r)
        let slot = try slot("usage_report_sample", "report_key", key, file: file)
        guard slot != .keep else { return }
        let cc = try labelID(.ccVersion, r.ccVersion, &ctx)
        try conn.withStatement("""
            INSERT INTO usage_report_sample(report_key, uuid, session_ref, ts_ms, cc_version_ref, has_limits,
                extra_enabled, extra_monthly_limit, extra_used_credits, file_ref)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(report_key) DO UPDATE SET
                uuid = excluded.uuid, session_ref = excluded.session_ref, ts_ms = excluded.ts_ms,
                cc_version_ref = excluded.cc_version_ref, has_limits = excluded.has_limits,
                extra_enabled = excluded.extra_enabled, extra_monthly_limit = excluded.extra_monthly_limit,
                extra_used_credits = excluded.extra_used_credits, file_ref = excluded.file_ref
            """) { s in
            s.bind(1, key)
            s.bind(2, r.uuid)
            s.bind(3, file.sessionRef)
            s.bind(4, r.tsMs)
            s.bind(5, cc)
            s.bind(6, Int64(r.hasLimits ? 1 : 0))
            s.bind(7, r.extraEnabled)
            s.bind(8, r.extraMonthlyLimit.map(Int64.init))
            s.bind(9, r.extraUsedCredits.map(Int64.init))
            s.bind(10, file.fileRef)
            try s.step()
        }
        // The limits follow the winning report.
        if slot == .replace {
            try conn.withStatement("DELETE FROM usage_report_limit WHERE report_key = ?1") { s in
                s.bind(1, key)
                try s.step()
            }
        }
        for l in r.limits {
            guard let window = l.windowID else { continue }   // unknown kind / unnamed scope: OAuth skips it too
            try conn.withStatement("""
                INSERT INTO usage_report_limit(report_key, idx, window_id, kind, grp, percent, severity, is_active,
                    resets_at_ms, reset_epoch_s, scope_model)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) ON CONFLICT(report_key, idx) DO NOTHING
                """) { s in
                s.bind(1, key)
                s.bind(2, Int64(l.index))
                s.bind(3, window)
                s.bind(4, l.kind)
                s.bind(5, l.group)
                s.bind(6, l.percent)
                s.bind(7, l.severity)
                s.bind(8, l.isActive)
                s.bind(9, l.resetsAtMs)
                s.bind(10, HistoryEpoch.seconds(ms: l.resetsAtMs))
                s.bind(11, l.scopeModel)
                try s.step()
            }
        }
    }

    private func upsertCompactEvent(_ c: CompactEventObservation, file: HistoryRegisteredFile) throws {
        let key = HistoryEventCheck.compactKey(c)
        guard try slot("compact_event", "event_key", key, file: file) != .keep else { return }
        try conn.withStatement("""
            INSERT INTO compact_event(event_key, session_ref, ts_ms, trigger, pre_tokens, post_tokens, file_ref)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(event_key) DO UPDATE SET
                session_ref = excluded.session_ref, ts_ms = excluded.ts_ms, trigger = excluded.trigger,
                pre_tokens = excluded.pre_tokens, post_tokens = excluded.post_tokens, file_ref = excluded.file_ref
            """) { s in
            s.bind(1, key)
            s.bind(2, file.sessionRef)
            s.bind(3, c.tsMs)
            s.bind(4, c.trigger)
            s.bind(5, c.preTokens.map(Int64.init))
            s.bind(6, c.postTokens.map(Int64.init))
            s.bind(7, file.fileRef)
            try s.step()
        }
    }

    /// Keyed by the RECORD's session id (a cost state is restored on resume).
    /// Every copy carries the same totals; only `after_ts_ms` (the running max
    /// timestamp before the line, per file) differs, and merges as a NULL-aware MAX.
    private func mergeCostState(_ c: CostStateObservation) throws {
        let session = try sessionRef(for: c.sessionID)
        let exists = try conn.withStatement("""
            SELECT 1 FROM cost_state_sample WHERE session_ref = ?1 AND start_time_ms = ?2 AND total_duration_ms = ?3
            """) { s -> Bool in
            s.bind(1, session)
            s.bind(2, c.startTimeMs)
            s.bind(3, c.totalDurationMs)
            return try s.step()
        }
        if exists {
            guard !config.mergeMutations.contains(.firstArrivalEvents), let after = c.afterTsMs else { return }
            try conn.withStatement("""
                UPDATE cost_state_sample SET after_ts_ms = ?4
                WHERE session_ref = ?1 AND start_time_ms = ?2 AND total_duration_ms = ?3
                  AND (after_ts_ms IS NULL OR after_ts_ms < ?4)
                """) { s in
                s.bind(1, session)
                s.bind(2, c.startTimeMs)
                s.bind(3, c.totalDurationMs)
                s.bind(4, after)
                try s.step()
            }
            return
        }
        try conn.withStatement("""
            INSERT INTO cost_state_sample(session_ref, start_time_ms, total_duration_ms, total_api_duration_ms,
                total_cost_usd, has_unknown_model_cost, after_ts_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """) { s in
            s.bind(1, session)
            s.bind(2, c.startTimeMs)
            s.bind(3, c.totalDurationMs)
            s.bind(4, c.totalAPIDurationMs)
            s.bind(5, c.totalCostUSD)
            s.bind(6, Int64(c.hasUnknownModelCost ? 1 : 0))
            s.bind(7, c.afterTsMs)
            try s.step()
        }
        for m in c.models {
            try conn.withStatement("""
                INSERT INTO cost_state_model(session_ref, start_time_ms, total_duration_ms, model_key, input, output,
                    cache_read, cache_creation, thinking, web_search, cost_usd)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) ON CONFLICT DO NOTHING
                """) { s in
                s.bind(1, session)
                s.bind(2, c.startTimeMs)
                s.bind(3, c.totalDurationMs)
                s.bind(4, m.modelKey)
                s.bind(5, Int64(m.input))
                s.bind(6, Int64(m.output))
                s.bind(7, Int64(m.cacheRead))
                s.bind(8, Int64(m.cacheCreation))
                s.bind(9, Int64(m.thinking))
                s.bind(10, Int64(m.webSearch))
                s.bind(11, m.costUSD)
                try s.step()
            }
        }
    }

    /// The session's first cwd: replaced iff the candidate is earlier (a nil
    /// time is latest), ties broken by the smaller cwd, then entrypoint and
    /// version (nil first), all in byte order, so the result never depends on
    /// which main file arrived first.
    private func foldFirstCwd(session: Int64, cwd: String, ms: Int64?, entrypoint: String?, ccVersion: String?,
                              _ ctx: inout HistoryIngestContext) throws {
        struct Candidate {
            let ms: Int64?
            let cwd: String
            let entrypoint: String?
            let cc: String?
            func precedes(_ o: Candidate) -> Bool {
                let a = ms ?? .max, b = o.ms ?? .max
                if a != b { return a < b }
                if !cwd.utf8.elementsEqual(o.cwd.utf8) { return historyBinaryLess(cwd, o.cwd) }
                func key(_ s: String?) -> [UInt8] { s.map { [1] + Array($0.utf8) } ?? [0] }
                if key(entrypoint) != key(o.entrypoint) { return key(entrypoint).lexicographicallyPrecedes(key(o.entrypoint)) }
                return key(cc).lexicographicallyPrecedes(key(o.cc))
            }
        }
        let current = try conn.withStatement("""
            SELECT s.first_cwd, s.first_cwd_ms, e.value, v.value FROM session s
            LEFT JOIN dict e ON e.id = s.entrypoint_ref LEFT JOIN dict v ON v.id = s.cc_version_ref
            WHERE s.session_ref = ?1
            """) { s -> Candidate? in
            s.bind(1, session)
            guard try s.step(), let cwd = s.text(0) else { return nil }
            return Candidate(ms: s.optionalInt64(1), cwd: cwd, entrypoint: s.text(2), cc: s.text(3))
        }
        let candidate = Candidate(ms: ms, cwd: cwd, entrypoint: entrypoint, cc: ccVersion)
        if let current, !candidate.precedes(current) { return }
        let entry = try labelID(.entrypoint, entrypoint, &ctx)
        let cc = try labelID(.ccVersion, ccVersion, &ctx)
        try conn.withStatement("""
            UPDATE session SET first_cwd = ?2, first_cwd_ms = ?3, entrypoint_ref = ?4, cc_version_ref = ?5
            WHERE session_ref = ?1
            """) { s in
            s.bind(1, session)
            s.bind(2, cwd)
            s.bind(3, ms)
            s.bind(4, entry)
            s.bind(5, cc)
            try s.step()
        }
    }
}
