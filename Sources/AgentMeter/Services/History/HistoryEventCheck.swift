import Foundation

// Keys and validation of the whole-file extras. Pure: the store and the tests
// use the same functions.

/// `resetsAt` rounded to the NEAREST 60 s, for `limit_event`,
/// `usage_report_limit` and `QuotaSampleRow.resetEpochSeconds` alike. nil for
/// a time the store does not keep (`HistoryTime.isStorable`), so the rounding
/// cannot overflow.
enum HistoryEpoch {
    static func seconds(ms: Int64?) -> Int64? {
        guard let ms, HistoryTime.isStorable(ms) else { return nil }
        return ((ms + 30_000) / 60_000) * 60
    }
}

/// Validation of the extras before the transaction: a non-finite number, an
/// unusable timestamp or an over-long text drops that one event (counted),
/// never the chunk.
enum HistoryEventCheck {
    /// Every event text: ids, keys and labels the scanner holds to 64 bytes.
    static let maxText = 1_024
    /// The session's first cwd. The scanner's `cwd()` uses this same bound, so
    /// a working directory the usage cache keeps is never refused here.
    static let maxCwdBytes = 4_096

    static func validated(_ e: HistoryFileEvents) -> (HistoryFileEvents, invalid: Int) {
        var out = e
        var invalid = 0
        func ok(_ texts: [String?]) -> Bool { texts.allSatisfy { ($0?.utf8.count ?? 0) <= maxText } }
        func finite(_ v: Double?) -> Bool { v.map(\.isFinite) ?? true }
        func time(_ v: Int64?) -> Bool { HistoryTime.isStorable(v) }

        out.limitEvents = e.limitEvents.filter {
            let keep = time($0.tsMs) && time($0.resetsAtMs)
                && ok([$0.uuid, $0.requestID, $0.windowID, $0.status, $0.overageStatus,
                       $0.overageDisabledReason, $0.source, $0.apiError, $0.ccVersion])
            if !keep { invalid += 1 }
            return keep
        }
        out.usageReports = e.usageReports.filter {
            let keep = time($0.tsMs) && ok([$0.uuid, $0.ccVersion])
                && $0.limits.allSatisfy { finite($0.percent) && time($0.resetsAtMs)
                    && ok([$0.kind, $0.group, $0.severity, $0.scopeModel]) }
            if !keep { invalid += 1 }
            return keep
        }
        out.costStates = e.costStates.filter {
            let keep = time($0.startTimeMs) && time($0.afterTsMs) && $0.totalCostUSD.isFinite
                && ok([$0.sessionID]) && $0.models.allSatisfy { $0.costUSD.isFinite && ok([$0.modelKey]) }
            if !keep { invalid += 1 }
            return keep
        }
        out.compactEvents = e.compactEvents.filter {
            let keep = time($0.tsMs) && ok([$0.uuid, $0.trigger])
            if !keep { invalid += 1 }
            return keep
        }
        let cwdFits = (e.firstCwd?.utf8.count ?? 0) <= maxCwdBytes
        if !cwdFits || !ok([e.firstEntrypoint, e.firstCcVersion]) || !time(e.firstCwdMs) {
            out.firstCwd = nil
            out.firstCwdMs = nil
            out.firstEntrypoint = nil
            out.firstCcVersion = nil
            invalid += 1
        }
        return (out, invalid)
    }

    /// `usage_report_sample.report_key`: `"<ts_ms>|<hex8>"`, hex8 = the first 4
    /// bytes of SHA-256 over the canonical limits. A fork-copied /usage record
    /// gets a new uuid but keeps its time and limits, so it lands once.
    /// `limit_event.event_key`: the request id when present (a fork re-stamps
    /// the uuid, never the request id), else `uuid:<uuid>`.
    static func limitKey(_ e: LimitEventObservation) -> String { e.requestID ?? "uuid:" + e.uuid }

    /// `compact_event.event_key`: `"<ts_ms>|<trigger>|<pre_tokens>|<post_tokens>"`,
    /// empty for a missing value. A fork's copied compact_boundary line gets a
    /// new uuid but keeps all of these; in-file replays (same uuid) are
    /// deduplicated by the scanner.
    static func compactKey(_ c: CompactEventObservation) -> String {
        "\(c.tsMs)|\(c.trigger ?? "")|\(c.preTokens.map(String.init) ?? "")|\(c.postTokens.map(String.init) ?? "")"
    }

    static func reportKey(_ r: UsageReportObservation) -> String {
        var w = HistoryCanonicalBytes()
        w.u32(UInt32(truncatingIfNeeded: r.limits.count))
        for l in r.limits {
            w.i64(Int64(l.index))
            w.string(l.kind)
            w.optional(l.group) { $0.string($1) }
            w.optional(l.percent) { $0.i64(Int64(bitPattern: $1.bitPattern)) }
            w.optional(l.severity) { $0.string($1) }
            w.optional(l.isActive) { $0.u8($1 ? 1 : 0) }
            w.optional(l.resetsAtMs) { $0.i64($1) }
            w.optional(l.scopeModel) { $0.string($1) }
        }
        return "\(r.tsMs)|" + HistoryHex.encode(w.sha256.prefix(4))
    }
}
