import Foundation

// The per-observation merge, run inside the chunk's transaction: occurrence
// upsert -> rank-guarded row upsert -> stale cleanup -> derived UPDATE per
// row. Every step runs for every observation, also when an earlier step
// changed nothing (a key-level skip is order-dependent). The derived values
// are read once, right after the occurrence upsert (they depend on
// occurrences only), and serve both a new row's INSERT and the UPDATE.

extension SQLiteStatement {
    func bind(_ i: Int32, _ v: Int64?) { if let v { bind(i, v) } else { bindNull(i) } }
    func bind(_ i: Int32, _ v: String?) { if let v { bind(i, v) } else { bindNull(i) } }
    func bind(_ i: Int32, _ v: Double?) { if let v { bind(i, v) } else { bindNull(i) } }
    func bind(_ i: Int32, _ v: Bool?) { if let v { bind(i, Int64(v ? 1 : 0)) } else { bindNull(i) } }
    func optionalInt64(_ c: Int32) -> Int64? { isNull(c) ? nil : int64(c) }
    func optionalDouble(_ c: Int32) -> Double? { isNull(c) ? nil : double(c) }
    func optionalBool(_ c: Int32) -> Bool? { isNull(c) ? nil : int64(c) != 0 }
}

/// A `source_file` row the current transaction may reference.
struct HistoryRegisteredFile: Sendable {
    let fileRef: Int64
    let sessionRef: Int64
    let fileClass: Int64
    let agentID: String?
    let path: String
    /// As stored at registration (never rewritten).
    let birthMs: Int64?

    var rank: HistoryFileRank { HistoryFileRank(birthMs: birthMs, path: path) }
}

/// State of ONE transaction: dict ids resolved in it (never kept past it, a
/// rolled-back chunk takes its new dict rows with it) and the day cache.
struct HistoryIngestContext {
    private struct LabelKey: Hashable {
        let kind: HistoryLabelKind
        let value: String
    }

    private var labels: [LabelKey: Int64] = [:]
    var days: HistoryAccountingDays
    let mutations: HistoryMergeMutations

    init(timeZone: TimeZone, mutations: HistoryMergeMutations) {
        days = HistoryAccountingDays(timeZone: timeZone)
        self.mutations = mutations
    }

    fileprivate func cached(_ kind: HistoryLabelKind, _ value: String) -> Int64? { labels[LabelKey(kind: kind, value: value)] }
    fileprivate mutating func remember(_ kind: HistoryLabelKind, _ value: String, _ id: Int64) {
        labels[LabelKey(kind: kind, value: value)] = id
    }
}

extension HistoryDatabase {
    func makeIngestContext() -> HistoryIngestContext {
        HistoryIngestContext(timeZone: config.timeZone, mutations: config.mergeMutations)
    }

    // MARK: Dictionary and registration

    /// The `dict` id of a label, inserting it when new. nil for nil.
    func labelID(_ kind: HistoryLabelKind, _ value: String?, _ ctx: inout HistoryIngestContext) throws -> Int64? {
        guard let value else { return nil }
        if let id = ctx.cached(kind, value) { return id }
        let found = try conn.withStatement("SELECT id FROM dict WHERE kind = ?1 AND value = ?2") { s -> Int64? in
            s.bind(1, kind.rawValue)
            s.bind(2, value)
            return try s.step() ? s.int64(0) : nil
        }
        let id = try found ?? conn.withStatement("INSERT INTO dict(kind, value) VALUES (?1, ?2) RETURNING id") { s in
            s.bind(1, kind.rawValue)
            s.bind(2, value)
            _ = try s.step()
            return s.int64(0)
        }
        ctx.remember(kind, value, id)
        return id
    }

    /// The `session_ref` of a session id, inserting the row when new.
    func sessionRef(for sessionID: String) throws -> Int64 {
        if let ref = try conn.withStatement("SELECT session_ref FROM session WHERE session_id = ?1", { s -> Int64? in
            s.bind(1, sessionID)
            return try s.step() ? s.int64(0) : nil
        }) { return ref }
        return try conn.withStatement("INSERT INTO session(session_id) VALUES (?1) RETURNING session_ref") { s in
            s.bind(1, sessionID)
            _ = try s.step()
            return s.int64(0)
        }
    }

    /// The file's row, inserting it (and its session) when the path is new.
    /// `source.birthMs` is used only for a new path: birth is never rewritten.
    func registerFile(_ source: HistorySourceFile) throws -> HistoryRegisteredFile {
        let sql = "SELECT file_ref, session_ref, class, agent_id, birth_ms FROM source_file WHERE path = ?1"
        if let found = try conn.withStatement(sql, { s -> HistoryRegisteredFile? in
            s.bind(1, source.path)
            guard try s.step() else { return nil }
            return HistoryRegisteredFile(fileRef: s.int64(0), sessionRef: s.int64(1), fileClass: s.int64(2),
                                         agentID: s.text(3), path: source.path, birthMs: s.optionalInt64(4))
        }) { return found }
        let session = try sessionRef(for: source.sessionID)
        let ref = try conn.withStatement("""
            INSERT INTO source_file(path, class, session_ref, agent_id, run_id, birth_ms, parser_version)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0) RETURNING file_ref
            """) { s in
            s.bind(1, source.path)
            s.bind(2, Int64(source.fileClass.rawValue))
            s.bind(3, session)
            s.bind(4, source.agentID)
            s.bind(5, source.runID)
            s.bind(6, source.birthMs)
            _ = try s.step()
            return s.int64(0)
        }
        return HistoryRegisteredFile(fileRef: ref, sessionRef: session, fileClass: Int64(source.fileClass.rawValue),
                                     agentID: source.agentID, path: source.path, birthMs: source.birthMs)
    }

    // MARK: One observation

    /// Merges one validated observation of `file`.
    func applyObservation(_ o: RequestObservation, file: HistoryRegisteredFile, ingestVersion: Int64,
                          _ ctx: inout HistoryIngestContext) throws {
        let key = o.key.historyBytes
        let outputTotal = o.parts.reduce(Int64(0)) { $0 + Int64($1.counts.output) }
        let cc = try labelID(.ccVersion, o.ccVersion, &ctx)
        let effort = try labelID(.effort, o.effort, &ctx)
        let entry = try labelID(.entrypoint, o.entrypoint, &ctx)

        let sig = HistoryRecordSignature.compute(o)

        // 1. The file's occurrence: NULL-aware MIN/MAX, attributes of the
        //    file's standing record iff (version, finality, output, att_sig)
        //    is greater, flags OR.
        let occurrence = ctx.mutations.contains(.noAttSigTieBreak)
            ? Self.occurrenceUpsertSQL(attSigTieBreak: false) : Self.occurrenceUpsertDefaultSQL
        try conn.withStatement(occurrence) { s in
            s.bind(1, blob: key)
            s.bind(2, file.fileRef)
            s.bind(3, o.firstMs)
            s.bind(4, o.lastMs)
            s.bind(5, ingestVersion)
            s.bind(6, Int64(o.finality.rawValue))
            s.bind(7, outputTotal)
            s.bind(8, cc)
            s.bind(9, effort)
            s.bind(10, entry)
            s.bind(11, Int64(o.flags.rawValue))
            s.bind(12, HistoryAttributeSignature.compute(o, recSig: sig))
            try s.step()
        }

        // The derived values depend on the occurrences only, so they are known
        // now: a new row is INSERTed with its final values instead of
        // placeholders that the UPDATE below would move in two indexes. Step 4
        // still runs after the cleanup for every row (an existing row's owner
        // or first_seen may have changed with this occurrence).
        guard let derived = try computeDerived(key: key, &ctx) else { return }
        let inserted = ctx.mutations.contains(.keyLevelDerivedSkip)
            ? Derived(firstSeen: nil, lastSeen: nil, acctDay: nil, owner: file.fileRef, session: file.sessionRef,
                      fileClass: file.fileClass, cc: nil, effort: nil, entry: nil, flags: 0)   // the observing file's values
            : derived

        // 2. The record's rows, each guarded by the record rank.
        let upsert = ctx.mutations.isEmpty ? Self.requestUpsertDefaultSQL : Self.requestUpsertSQL(ctx.mutations)
        for (idx, part) in o.parts.enumerated() {
            let model = try labelID(.model, part.model, &ctx) ?? 0
            try conn.withStatement(upsert) { s in
                s.bind(1, blob: key)
                s.bind(2, Int64(idx))
                s.bind(3, model)
                s.bind(4, Int64(part.counts.input))
                s.bind(5, Int64(part.counts.output))
                s.bind(6, Int64(part.counts.cacheWrite5m))
                s.bind(7, Int64(part.counts.cacheWrite1h))
                s.bind(8, Int64(part.counts.cacheRead))
                s.bind(9, idx == o.parts.count - 1 ? o.thinkingTokens.map(Int64.init) : nil)
                s.bind(10, Int64(o.finality.rawValue))
                s.bind(11, Int64(o.parts.count))
                s.bind(12, outputTotal)
                s.bind(13, sig)
                s.bind(14, ingestVersion)
                s.bind(15, o.finalMs)
                s.bind(16, inserted.firstSeen)
                s.bind(17, inserted.lastSeen)
                s.bind(18, inserted.acctDay)
                s.bind(19, inserted.owner)
                s.bind(20, inserted.session)
                s.bind(21, inserted.fileClass)
                s.bind(22, inserted.cc)
                s.bind(23, inserted.effort)
                s.bind(24, inserted.entry)
                s.bind(25, inserted.flags)
                try s.step()
            }
        }

        // 3. Stale rows: anything not of the idx-0 row's record.
        if !ctx.mutations.contains(.noStaleCleanup) {
            try conn.withStatement("""
                DELETE FROM request WHERE key = ?1
                  AND rec_sig <> (SELECT rec_sig FROM request WHERE key = ?1 AND iteration_idx = 0)
                """) { s in
                s.bind(1, blob: key)
                try s.step()
            }
        }

        // 4. Derived columns, per row (a no-op for rows that already hold them).
        try updateDerived(key: key, derived)
    }

    private struct Derived: Equatable {
        var firstSeen: Int64?
        var lastSeen: Int64?
        var acctDay: Int64?
        var owner: Int64
        var session: Int64
        var fileClass: Int64
        var cc: Int64?
        var effort: Int64?
        var entry: Int64?
        var flags: Int64
    }

    /// first = MIN over occurrences; owner = argmin (last IS NULL, birth ?? +inf,
    /// path); last and attributes = the owner occurrence's; flags = OR.
    private func computeDerived(key: [UInt8], _ ctx: inout HistoryIngestContext) throws -> Derived? {
        try conn.withStatement("""
            SELECT o.file_ref, o.first_ms, o.last_ms, o.cc_version_ref, o.effort_ref, o.entrypoint_ref, o.flags,
                   s.birth_ms, s.path, s.session_ref, s.class
            FROM request_occurrence o JOIN source_file s ON s.file_ref = o.file_ref
            WHERE o.key = ?1
            """) { s -> Derived? in
            s.bind(1, blob: key)
            var first: Int64?
            var flags: Int64 = 0
            var best: (lastNull: Bool, birth: Int64, path: String, row: Derived)?
            while try s.step() {
                first = HistoryNullAware.min(first, s.optionalInt64(1))
                flags |= s.int64(6)
                let last = s.optionalInt64(2)
                let birth = s.optionalInt64(7) ?? Int64.max
                let path = s.text(8) ?? ""
                if let b = best {
                    let better = (last == nil) != b.lastNull ? (last != nil)
                        : birth != b.birth ? birth < b.birth : historyBinaryLess(path, b.path)
                    if !better { continue }
                }
                best = (last == nil, birth, path, Derived(
                    firstSeen: nil, lastSeen: last, acctDay: nil, owner: s.int64(0), session: s.int64(9),
                    fileClass: s.int64(10), cc: s.optionalInt64(3), effort: s.optionalInt64(4),
                    entry: s.optionalInt64(5), flags: 0))
            }
            guard var row = best?.row else { return nil }
            row.firstSeen = first
            row.acctDay = ctx.days.day(first)
            row.flags = flags
            return row
        }
    }

    private func updateDerived(key: [UInt8], _ d: Derived) throws {
        if config.mergeMutations.contains(.keyLevelDerivedSkip) {
            let current = try conn.withStatement("""
                SELECT first_seen_ms, last_seen_ms, acct_day, owner_file_ref, session_ref, class,
                       cc_version_ref, effort_ref, entrypoint_ref, flags
                FROM request WHERE key = ?1 AND iteration_idx = 0
                """) { s -> Derived? in
                s.bind(1, blob: key)
                guard try s.step() else { return nil }
                return Derived(firstSeen: s.optionalInt64(0), lastSeen: s.optionalInt64(1), acctDay: s.optionalInt64(2),
                               owner: s.int64(3), session: s.int64(4), fileClass: s.int64(5), cc: s.optionalInt64(6),
                               effort: s.optionalInt64(7), entry: s.optionalInt64(8), flags: s.int64(9))
            }
            if current == d { return }
        }

        try conn.withStatement("""
            UPDATE request SET first_seen_ms = ?2, last_seen_ms = ?3, acct_day = ?4, owner_file_ref = ?5,
                session_ref = ?6, class = ?7, cc_version_ref = ?8, effort_ref = ?9, entrypoint_ref = ?10, flags = ?11
            WHERE key = ?1 AND (first_seen_ms IS NOT ?2 OR last_seen_ms IS NOT ?3 OR acct_day IS NOT ?4
                OR owner_file_ref IS NOT ?5 OR session_ref IS NOT ?6 OR class IS NOT ?7 OR cc_version_ref IS NOT ?8
                OR effort_ref IS NOT ?9 OR entrypoint_ref IS NOT ?10 OR flags IS NOT ?11)
            """) { s in
            s.bind(1, blob: key)
            s.bind(2, d.firstSeen)
            s.bind(3, d.lastSeen)
            s.bind(4, d.acctDay)
            s.bind(5, d.owner)
            s.bind(6, d.session)
            s.bind(7, d.fileClass)
            s.bind(8, d.cc)
            s.bind(9, d.effort)
            s.bind(10, d.entry)
            s.bind(11, d.flags)
            try s.step()
        }
    }

    // MARK: SQL

    private static let occurrenceUpsertDefaultSQL = occurrenceUpsertSQL(attSigTieBreak: true)

    /// Every SET expression reads the OLD row, so the repeated `attributesWin`
    /// decides all attribute columns together. The rank tells any two
    /// contents of one file apart (`att_sig` hashes the content and labels it
    /// decides between) except for a 2^-32 tie of its label half, so the
    /// stored attributes are a function of the set of observations.
    private static func occurrenceUpsertSQL(attSigTieBreak: Bool) -> String {
        let rank = ["ingest_version", "att_fin", "att_out"] + (attSigTieBreak ? ["att_sig"] : [])
        let attributesWin = "(\(rank.map { "excluded.\($0)" }.joined(separator: ", "))) "
            + "> (\(rank.map { "request_occurrence.\($0)" }.joined(separator: ", ")))"
        return """
            INSERT INTO request_occurrence(key, file_ref, first_ms, last_ms, ingest_version, att_fin, att_out,
                cc_version_ref, effort_ref, entrypoint_ref, flags, att_sig)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(key, file_ref) DO UPDATE SET
                first_ms = CASE WHEN request_occurrence.first_ms IS NULL THEN excluded.first_ms
                                WHEN excluded.first_ms IS NULL THEN request_occurrence.first_ms
                                ELSE min(request_occurrence.first_ms, excluded.first_ms) END,
                last_ms = CASE WHEN request_occurrence.last_ms IS NULL THEN excluded.last_ms
                               WHEN excluded.last_ms IS NULL THEN request_occurrence.last_ms
                               ELSE max(request_occurrence.last_ms, excluded.last_ms) END,
                ingest_version = CASE WHEN \(attributesWin) THEN excluded.ingest_version ELSE request_occurrence.ingest_version END,
                att_fin = CASE WHEN \(attributesWin) THEN excluded.att_fin ELSE request_occurrence.att_fin END,
                att_out = CASE WHEN \(attributesWin) THEN excluded.att_out ELSE request_occurrence.att_out END,
                att_sig = CASE WHEN \(attributesWin) THEN excluded.att_sig ELSE request_occurrence.att_sig END,
                cc_version_ref = CASE WHEN \(attributesWin) THEN excluded.cc_version_ref ELSE request_occurrence.cc_version_ref END,
                effort_ref = CASE WHEN \(attributesWin) THEN excluded.effort_ref ELSE request_occurrence.effort_ref END,
                entrypoint_ref = CASE WHEN \(attributesWin) THEN excluded.entrypoint_ref ELSE request_occurrence.entrypoint_ref END,
                flags = request_occurrence.flags | excluded.flags
            WHERE excluded.first_ms < request_occurrence.first_ms
               OR (request_occurrence.first_ms IS NULL AND excluded.first_ms IS NOT NULL)
               OR excluded.last_ms > request_occurrence.last_ms
               OR (request_occurrence.last_ms IS NULL AND excluded.last_ms IS NOT NULL)
               OR \(attributesWin)
               OR (request_occurrence.flags | excluded.flags) <> request_occurrence.flags
            """
    }

    private static let requestUpsertDefaultSQL = requestUpsertSQL([])

    /// `-COALESCE(final_ms, MAXINT)`: NULL ranks as +inf (smaller final wins); never Int64.min.
    private static func requestUpsertSQL(_ m: HistoryMergeMutations) -> String {
        var rank = ["ingest_version", "finality", "output_total"]
        if !m.contains(.noRecSigTieBreak) { rank.append("rec_sig") }
        let newRank = rank.map { "excluded.\($0)" }
            + (m.contains(.noFinalMsTieBreak) ? [] : ["-COALESCE(excluded.final_ms, 9223372036854775807)"])
        let oldRank = rank.map { "request.\($0)" }
            + (m.contains(.noFinalMsTieBreak) ? [] : ["-COALESCE(request.final_ms, 9223372036854775807)"])
        return """
            INSERT INTO request(key, iteration_idx, model_ref, input, output, cache_write_5m, cache_write_1h, cache_read,
                thinking, finality, parts, output_total, rec_sig, ingest_version, final_ms,
                first_seen_ms, last_seen_ms, acct_day, owner_file_ref, session_ref, class,
                cc_version_ref, effort_ref, entrypoint_ref, flags)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
                    ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25)
            ON CONFLICT(key, iteration_idx) DO UPDATE SET
                model_ref = excluded.model_ref, input = excluded.input, output = excluded.output,
                cache_write_5m = excluded.cache_write_5m, cache_write_1h = excluded.cache_write_1h,
                cache_read = excluded.cache_read, thinking = excluded.thinking, finality = excluded.finality,
                parts = excluded.parts, output_total = excluded.output_total, rec_sig = excluded.rec_sig,
                ingest_version = excluded.ingest_version, final_ms = excluded.final_ms
            WHERE (\(newRank.joined(separator: ", "))) > (\(oldRank.joined(separator: ", ")))
            """
    }
}
