import Foundation

// Read queries over the history: the logical dump (the order-independence
// oracle), day x model sums, a session's usage per model and per agent, one
// key's rows, and the table statistics. The quota calibration helper
// (`oauthSamples`) lives with the quota code. All run through `HistoryStore`
// (`HistoryStore+Queries.swift`).

/// `acct_day` x model sums of the stored rows, to compare with `UsageReport.dayModels`.
struct HistoryDayModelUsage: Equatable, Sendable {
    var acctDay: Int64?
    var model: String
    var counts: TokenCounts
    var finalRows: Int
    var partialRows: Int
    var zeroedRows: Int
}

/// What a session's owned requests add up to: per model, and per agent (the
/// owner file) and model.
struct HistorySessionUsage: Equatable, Sendable {
    struct ByModel: Equatable, Sendable {
        var model: String
        var counts: TokenCounts
        var rows: Int
    }

    struct ByAgent: Equatable, Sendable {
        var path: String
        var agentID: String?
        var fileClass: Int64
        var model: String
        var counts: TokenCounts
        var rows: Int
    }

    var byModel: [ByModel] = []
    var byAgent: [ByAgent] = []
}

/// Rows per table plus the persistent counters in `meta`.
struct HistoryContentStatistics: Equatable, Sendable {
    var rowCounts: [String: Int] = [:]
    var quotaConflicts: Int = 0
    /// The store's per-process counters (failed chunks, skipped invalid observations, ...).
    var counters = HistoryStoreStatistics()
}

extension HistoryDatabase {
    private enum Col { case i, d, s, hex }

    private func fields(_ sql: String, _ cols: [Col], bind: (SQLiteStatement) -> Void = { _ in })
        throws -> [[HistoryLogicalDump.Field]] {
        try conn.withStatement(sql) { s in
            bind(s)
            var out: [[HistoryLogicalDump.Field]] = []
            while try s.step() {
                out.append(cols.enumerated().map { n, c in
                    let i = Int32(n)
                    switch c {
                    case .i: return .i(s.optionalInt64(i))
                    case .d: return .d(s.optionalDouble(i))
                    case .s: return .s(s.text(i))
                    case .hex: return .s(s.blob(i).map { HistoryHex.encode($0) })
                    }
                })
            }
            return out
        }
    }

    // MARK: The logical dump

    func logicalDump() throws -> HistoryLogicalDump {
        var dump = HistoryLogicalDump()
        dump.files = try conn.withStatement("""
            SELECT f.path, f.class, s.session_id, f.agent_id, f.run_id, f.birth_ms
            FROM source_file f JOIN session s ON s.session_ref = f.session_ref ORDER BY f.path
            """) { s in
            var out: [HistoryLogicalDump.File] = []
            while try s.step() {
                out.append(.init(path: s.text(0) ?? "", fileClass: s.int64(1), sessionID: s.text(2) ?? "",
                                 agentID: s.text(3), runID: s.text(4), birthMs: s.optionalInt64(5)))
            }
            return out
        }
        dump.sessions = try conn.withStatement("""
            SELECT s.session_id, s.first_cwd, s.first_cwd_ms, e.value, v.value FROM session s
            LEFT JOIN dict e ON e.id = s.entrypoint_ref LEFT JOIN dict v ON v.id = s.cc_version_ref
            ORDER BY s.session_id
            """) { s in
            var out: [HistoryLogicalDump.Session] = []
            while try s.step() {
                out.append(.init(sessionID: s.text(0) ?? "", firstCwd: s.text(1), firstCwdMs: s.optionalInt64(2),
                                 entrypoint: s.text(3), ccVersion: s.text(4)))
            }
            return out
        }
        dump.requests = try requestRows(keyBytes: nil)
        dump.occurrences = try conn.withStatement("""
            SELECT o.key, f.path, o.first_ms, o.last_ms, o.ingest_version, o.att_fin, o.att_out, o.att_sig,
                   cc.value, ef.value, en.value, o.flags
            FROM request_occurrence o JOIN source_file f ON f.file_ref = o.file_ref
            LEFT JOIN dict cc ON cc.id = o.cc_version_ref LEFT JOIN dict ef ON ef.id = o.effort_ref
            LEFT JOIN dict en ON en.id = o.entrypoint_ref
            ORDER BY o.key, f.path
            """) { s in
            var out: [HistoryLogicalDump.Occurrence] = []
            while try s.step() {
                out.append(.init(keyHex: HistoryHex.encode(s.blob(0) ?? []), path: s.text(1) ?? "",
                                 firstMs: s.optionalInt64(2), lastMs: s.optionalInt64(3), ingestVersion: s.int64(4),
                                 attFin: s.int64(5), attOut: s.int64(6), attSig: s.int64(7), ccVersion: s.text(8),
                                 effort: s.text(9), entrypoint: s.text(10), flags: s.int64(11)))
            }
            return out
        }
        dump.events = try eventLines()
        return dump
    }

    /// The rows of one key (or of every key), joined back to logical values.
    func requestRows(keyBytes: [UInt8]?) throws -> [HistoryLogicalDump.Request] {
        let sql = """
            SELECT r.key, r.iteration_idx, m.value, r.input, r.output, r.cache_write_5m, r.cache_write_1h, r.cache_read,
                   r.thinking, r.finality, r.parts, r.output_total, r.rec_sig, r.ingest_version, r.final_ms,
                   r.first_seen_ms, r.last_seen_ms, r.acct_day, f.path, s.session_id, r.class,
                   cc.value, ef.value, en.value, r.flags
            FROM request r JOIN dict m ON m.id = r.model_ref
            JOIN source_file f ON f.file_ref = r.owner_file_ref JOIN session s ON s.session_ref = r.session_ref
            LEFT JOIN dict cc ON cc.id = r.cc_version_ref LEFT JOIN dict ef ON ef.id = r.effort_ref
            LEFT JOIN dict en ON en.id = r.entrypoint_ref
            """ + (keyBytes == nil ? "" : " WHERE r.key = ?1") + " ORDER BY r.key, r.iteration_idx"
        return try conn.withStatement(sql) { s in
            if let keyBytes { s.bind(1, blob: keyBytes) }
            var out: [HistoryLogicalDump.Request] = []
            while try s.step() {
                out.append(.init(
                    keyHex: HistoryHex.encode(s.blob(0) ?? []), idx: s.int64(1), model: s.text(2) ?? "",
                    input: s.int64(3), output: s.int64(4), cacheWrite5m: s.int64(5), cacheWrite1h: s.int64(6),
                    cacheRead: s.int64(7), thinking: s.optionalInt64(8), finality: s.int64(9), parts: s.int64(10),
                    outputTotal: s.int64(11), recSig: s.int64(12), ingestVersion: s.int64(13), finalMs: s.optionalInt64(14),
                    firstSeenMs: s.optionalInt64(15), lastSeenMs: s.optionalInt64(16), acctDay: s.optionalInt64(17),
                    ownerPath: s.text(18) ?? "", sessionID: s.text(19) ?? "", fileClass: s.int64(20),
                    ccVersion: s.text(21), effort: s.text(22), entrypoint: s.text(23), flags: s.int64(24)))
            }
            return out
        }
    }

    private func eventLines() throws -> [String] {
        var lines: [String] = []
        func add(_ table: String, _ sql: String, _ cols: [Col]) throws {
            lines += try fields(sql, cols).map { HistoryLogicalDump.line(table, $0) }
        }
        try add("L", """
            SELECT l.event_key, l.uuid, l.request_id, s.session_id, l.agent_id, l.class, l.ts_ms, l.window_id, l.status,
                   l.resets_at_ms, l.reset_epoch_s, l.overage_status, l.overage_disabled_reason, l.is_using_overage,
                   l.fallback_available, l.source, l.api_error, v.value, f.path
            FROM limit_event l JOIN session s ON s.session_ref = l.session_ref LEFT JOIN dict v ON v.id = l.cc_version_ref
            LEFT JOIN source_file f ON f.file_ref = l.file_ref
            """, [.s, .s, .s, .s, .s, .i, .i, .s, .s, .i, .i, .s, .s, .i, .i, .s, .s, .s, .s])
        try add("U", """
            SELECT u.report_key, u.uuid, s.session_id, u.ts_ms, v.value, u.has_limits, u.extra_enabled,
                   u.extra_monthly_limit, u.extra_used_credits, f.path
            FROM usage_report_sample u JOIN session s ON s.session_ref = u.session_ref LEFT JOIN dict v ON v.id = u.cc_version_ref
            LEFT JOIN source_file f ON f.file_ref = u.file_ref
            """, [.s, .s, .s, .i, .s, .i, .i, .i, .i, .s])
        try add("UL", """
            SELECT report_key, idx, window_id, kind, grp, percent, severity, is_active, resets_at_ms, reset_epoch_s, scope_model
            FROM usage_report_limit
            """, [.s, .i, .s, .s, .s, .d, .s, .i, .i, .i, .s])
        try add("C", """
            SELECT s.session_id, c.start_time_ms, c.total_duration_ms, c.total_api_duration_ms, c.total_cost_usd,
                   c.has_unknown_model_cost, c.after_ts_ms
            FROM cost_state_sample c JOIN session s ON s.session_ref = c.session_ref
            """, [.s, .i, .i, .i, .d, .i, .i])
        try add("CM", """
            SELECT s.session_id, c.start_time_ms, c.total_duration_ms, c.model_key, c.input, c.output, c.cache_read,
                   c.cache_creation, c.thinking, c.web_search, c.cost_usd
            FROM cost_state_model c JOIN session s ON s.session_ref = c.session_ref
            """, [.s, .i, .i, .s, .i, .i, .i, .i, .i, .i, .d])
        try add("X", """
            SELECT c.event_key, s.session_id, c.ts_ms, c.trigger, c.pre_tokens, c.post_tokens, f.path
            FROM compact_event c JOIN session s ON s.session_ref = c.session_ref
            LEFT JOIN source_file f ON f.file_ref = c.file_ref
            """, [.s, .s, .i, .s, .i, .i, .s])
        return lines.sorted(by: historyBinaryLess)
    }

    // MARK: Usage queries

    private static let sums = """
        sum(r.input), sum(r.output), sum(r.cache_write_5m), sum(r.cache_write_1h), sum(r.cache_read), count(*)
        """

    private static func counts(_ s: SQLiteStatement, from c: Int32) -> TokenCounts {
        TokenCounts(input: Int(s.int64(c)), output: Int(s.int64(c + 1)), cacheWrite5m: Int(s.int64(c + 2)),
                    cacheWrite1h: Int(s.int64(c + 3)), cacheRead: Int(s.int64(c + 4)))
    }

    func dayModelUsage() throws -> [HistoryDayModelUsage] {
        try conn.withStatement("""
            SELECT r.acct_day, m.value, \(Self.sums),
                   sum(r.finality = 2), sum(r.finality = 1), sum(r.finality = 0)
            FROM request r JOIN dict m ON m.id = r.model_ref
            GROUP BY r.acct_day, m.value ORDER BY r.acct_day, m.value
            """) { s in
            var out: [HistoryDayModelUsage] = []
            while try s.step() {
                out.append(.init(acctDay: s.optionalInt64(0), model: s.text(1) ?? "", counts: Self.counts(s, from: 2),
                                 finalRows: Int(s.int64(8)), partialRows: Int(s.int64(9)), zeroedRows: Int(s.int64(10))))
            }
            return out
        }
    }

    /// The requests a session OWNS (the request owner rule), per model and per
    /// agent (`GROUP BY owner_file_ref, model_ref`).
    func sessionUsage(sessionID: String) throws -> HistorySessionUsage {
        var usage = HistorySessionUsage()
        usage.byModel = try conn.withStatement("""
            SELECT m.value, \(Self.sums) FROM request r JOIN dict m ON m.id = r.model_ref
            WHERE r.session_ref = (SELECT session_ref FROM session WHERE session_id = ?1)
            GROUP BY m.value ORDER BY m.value
            """) { s in
            s.bind(1, sessionID)
            var out: [HistorySessionUsage.ByModel] = []
            while try s.step() {
                out.append(.init(model: s.text(0) ?? "", counts: Self.counts(s, from: 1), rows: Int(s.int64(6))))
            }
            return out
        }
        usage.byAgent = try conn.withStatement("""
            SELECT f.path, f.agent_id, f.class, m.value, \(Self.sums)
            FROM request r JOIN dict m ON m.id = r.model_ref JOIN source_file f ON f.file_ref = r.owner_file_ref
            WHERE r.session_ref = (SELECT session_ref FROM session WHERE session_id = ?1)
            GROUP BY r.owner_file_ref, r.model_ref ORDER BY f.path, m.value
            """) { s in
            s.bind(1, sessionID)
            var out: [HistorySessionUsage.ByAgent] = []
            while try s.step() {
                out.append(.init(path: s.text(0) ?? "", agentID: s.text(1), fileClass: s.int64(2), model: s.text(3) ?? "",
                                 counts: Self.counts(s, from: 4), rows: Int(s.int64(9))))
            }
            return out
        }
        return usage
    }

    func contentStatistics() throws -> HistoryContentStatistics {
        var stats = HistoryContentStatistics()
        for table in HistorySchema.tableNames {
            stats.rowCounts[table] = Int(try conn.queryInt("SELECT count(*) FROM \(table)") ?? 0)
        }
        stats.quotaConflicts = Int(try metaInt("quota_conflicts") ?? 0)
        return stats
    }
}
