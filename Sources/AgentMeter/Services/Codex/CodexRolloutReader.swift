import Foundation

/// Reads Codex usage & quota directly from local session rollout logs.
/// Paths: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl (live) and
///        ~/.codex/archived_sessions/rollout-*.jsonl (Codex ≥0.142 moves older
///        sessions here). Both must be read or today's usage/spend collapses the
///        moment Codex archives an active session mid-day.
/// Each `token_count` event embeds `rate_limits` (quota) and `info.total/last_token_usage`.
enum CodexRolloutReader {
    /// Background usage is shown as local day / 7-day / 30-day. Avoid scanning
    /// archived historical rollouts on every refresh; full-history accounting
    /// belongs in a persisted index or explicit on-demand action.
    private static let usageHistoryDays = 31

    private struct DayModelUsage: Sendable {
        let day: Date
        let model: String
        var counts: TokenCounts
    }

    private struct FileUsageSummary: Sendable {
        // (day, model) -> counts, so a day that mixed models prices each correctly
        // instead of last-writer-wins on a single per-day model.
        var byDayModel: [String: DayModelUsage] = [:]
        /// Last model seen while parsing, carried across incremental resumes so a
        /// tail with token_count lines but no fresh model line still attributes to
        /// the session's model rather than the default.
        var lastModel: String = "gpt-5-codex"
    }

    private static let usageCache = LogFileParseCache<FileUsageSummary>()

    /// Roots that may hold rollout logs. `archived_sessions` is a flat directory;
    /// `sessions` is date-nested. The enumerator walks both recursively.
    static var sessionRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]
    }

    /// All rollout files, newest last (sorted by name, which is timestamp-prefixed).
    static func rolloutFiles() -> [URL] {
        rolloutFiles(in: sessionRoots)
    }

    /// Enumerates rollout logs under the given roots, deduped by filename so a
    /// session caught mid-archive in both roots — same `rollout-<ts>-<uuid>.jsonl`
    /// name — is never counted twice. Injectable so tests need not touch $HOME.
    static func rolloutFiles(in roots: [URL]) -> [URL] {
        var byName: [String: URL] = [:]
        for root in roots {
            guard let en = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in en where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                byName[url.lastPathComponent] = url
            }
        }
        return byName.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Quota (latest token_count across newest files)

    static func latestQuota() -> QuotaSnapshot? {
        // Scan newest files first; first file with a token_count wins.
        for url in rolloutFiles().reversed() {
            if let snap = quota(fromFile: url) { return snap }
        }
        return nil
    }

    private static func quota(fromFile url: URL) -> QuotaSnapshot? {
        var last: [String: Any]?
        try? JSONLLineReader.forEachLine(in: url) { line in
            // Rollout logs are mostly non-quota lines; skip the JSON parse unless
            // the line could carry a token_count event.
            guard line.contains("token_count"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  payload["rate_limits"] is [String: Any] else { return }
            last = payload
        }
        guard let payload = last, let rl = payload["rate_limits"] as? [String: Any] else { return nil }

        var windows: [QuotaWindow] = []
        if let primary = rl["primary"] as? [String: Any] {
            windows.append(window(id: "primary", from: primary))
        }
        if let secondary = rl["secondary"] as? [String: Any] {
            windows.append(window(id: "secondary", from: secondary))
        }
        let plan = rl["plan_type"] as? String
        return QuotaSnapshot(provider: .codex, windows: windows, source: .rolloutFile,
                             planType: plan, fetchedAt: Date(),
                             note: "From local session log (updates when Codex runs)")
    }

    private static func window(id: String, from d: [String: Any]) -> QuotaWindow {
        let used = (d["used_percent"] as? Double) ?? 0
        let minutes = (d["window_minutes"] as? Double) ?? 0
        let resets = (d["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return QuotaWindow(id: id, label: Self.label(forMinutes: minutes), usedPercent: used, resetsAt: resets)
    }

    static func label(forMinutes minutes: Double) -> String {
        switch minutes {
        case 0: return "Quota"
        case ..<120: return "\(Int(minutes / 60))-hour"
        case ..<(60 * 24 * 2): return "\(Int(minutes / 60))-hour"
        default: return "\(Int(minutes / (60 * 24)))-day"
        }
    }

    // MARK: - Usage (per-day token deltas across all files)

    static func usageReport() async -> UsageReport {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -usageHistoryDays,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date.distantPast
        return await usageReport(files: recentRolloutFiles(rolloutFiles(), modifiedSince: cutoff))
    }

    static func usageReport(files: [URL]) async -> UsageReport {
        // (day, model) -> counts across all files, so cost uses each model's price.
        var byDayModel: [String: (day: Date, model: String, counts: TokenCounts)] = [:]

        let fingerprints = files.compactMap { url -> (URL, LogFileFingerprint)? in
            guard let fingerprint = LogFileFingerprint.current(for: url) else { return nil }
            return (url, fingerprint)
        }
        await usageCache.prune(keeping: fingerprints.map(\.1))

        for (url, fingerprint) in fingerprints {
            let summary = await cachedUsageSummary(in: url, fingerprint: fingerprint)
            for (key, usage) in summary.byDayModel {
                if var existing = byDayModel[key] {
                    existing.counts.input += usage.counts.input
                    existing.counts.cacheRead += usage.counts.cacheRead
                    existing.counts.output += usage.counts.output
                    byDayModel[key] = existing
                } else {
                    byDayModel[key] = (usage.day, usage.model, usage.counts)
                }
            }
        }

        // totalCostUSD/totalTokens/byModel are surfaced as the "30-day" totals
        // (ModelBreakdown, MenuView's footer), so they must use the same rolling
        // 30-day cutoff as SpendWindows.lastDays(30) — not every day the buffered
        // file scan happened to pick up — or the two "30-day" figures disagree.
        let thirtyDayCutoff = Calendar.current.date(
            byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date())
        ) ?? Date.distantPast

        var bucketByDay: [Date: UsageBucket] = [:]
        var modelTotals: [String: (tokens: Int, cost: Double)] = [:]
        var totalCost = 0.0
        for (_, entry) in byDayModel {
            let cost = await PricingService.shared.cost(model: entry.model, counts: entry.counts)
            let b = bucketByDay[entry.day] ?? UsageBucket(day: entry.day, inputTokens: 0, outputTokens: 0,
                        cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: 0)
            bucketByDay[entry.day] = UsageBucket(day: entry.day,
                            inputTokens: b.inputTokens + entry.counts.input,
                            outputTokens: b.outputTokens + entry.counts.output,
                            cacheWrite5m: b.cacheWrite5m + entry.counts.cacheWrite5m,
                            cacheWrite1h: b.cacheWrite1h + entry.counts.cacheWrite1h,
                            cacheRead: b.cacheRead + entry.counts.cacheRead,
                            costUSD: b.costUSD + cost)

            guard entry.day >= thirtyDayCutoff else { continue }
            totalCost += cost
            let entryTokens = entry.counts.input + entry.counts.output
                + entry.counts.cacheWrite5m + entry.counts.cacheWrite1h + entry.counts.cacheRead
            var mt = modelTotals[entry.model] ?? (0, 0)
            mt.tokens += entryTokens
            mt.cost += cost
            modelTotals[entry.model] = mt
        }
        let buckets = bucketByDay.values.sorted { $0.day < $1.day }
        let totalTokens = buckets
            .filter { $0.day >= thirtyDayCutoff }
            .reduce(0) { $0 + $1.totalTokens }
        let byModel = modelTotals
            .map { ModelSpend(model: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted { $0.costUSD > $1.costUSD }
        return UsageReport(provider: .codex, buckets: buckets, totalCostUSD: totalCost,
                           totalTokens: totalTokens, byModel: byModel)
    }

    static func recentRolloutFiles(_ files: [URL], modifiedSince cutoff: Date) -> [URL] {
        files.filter { url in
            guard let modifiedAt = modificationDate(for: url) else { return false }
            return modifiedAt >= cutoff
        }
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    private static func cachedUsageSummary(
        in url: URL,
        fingerprint: LogFileFingerprint
    ) async -> FileUsageSummary {
        if let cached = await usageCache.value(for: fingerprint) { return cached }
        // Resume from the last parsed line boundary when the file only grew, so an
        // actively-appended session log isn't re-read whole on every refresh tick.
        var summary: FileUsageSummary
        let startOffset: Int64
        if let base = await usageCache.incrementalBase(for: fingerprint) {
            summary = base.value
            startOffset = base.parsedBytes
        } else {
            summary = FileUsageSummary()
            startOffset = 0
        }
        let cal = Calendar.current
        let result = try? JSONLLineReader.forEachCompleteLine(in: url, fromOffset: startOffset) { line in
            consume(line: line, into: &summary, calendar: cal)
        }
        // Cache only the clean line-boundary summary so an incremental resume can't
        // double-count; fold a trailing (not-yet-newline-terminated) record into the
        // value shown now without caching it — the next pass re-reads it once it's
        // complete.
        await usageCache.store(summary, for: fingerprint, parsedBytes: result?.consumed ?? startOffset)
        guard let trailing = result?.trailing else { return summary }
        var display = summary
        consume(line: trailing, into: &display, calendar: cal)
        return display
    }

    private static func consume(line: String, into summary: inout FileUsageSummary, calendar cal: Calendar) {
        // Only model-carrying and token_count lines matter; skip the JSON parse for
        // the majority (user/assistant messages, tool calls).
        guard line.contains("token_count") || line.contains("\"model\""),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Capture model when it appears (turn_context / session_meta); carried in
        // `summary.lastModel` so incremental resumes keep the session's model.
        if let payload = obj["payload"] as? [String: Any], let m = payload["model"] as? String {
            summary.lastModel = m
        }
        guard let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return }
        let input = (last["input_tokens"] as? Int) ?? 0
        let cached = (last["cached_input_tokens"] as? Int) ?? 0
        let output = (last["output_tokens"] as? Int) ?? 0
        var counts = TokenCounts()
        counts.input = max(0, input - cached)
        counts.cacheRead = cached
        counts.output = output
        let ts = (obj["timestamp"] as? String).flatMap(Self.parseISO) ?? Date()
        let day = cal.startOfDay(for: ts)
        let key = "\(day.timeIntervalSince1970)|\(summary.lastModel)"
        if var existing = summary.byDayModel[key] {
            existing.counts.input += counts.input
            existing.counts.cacheRead += counts.cacheRead
            existing.counts.output += counts.output
            summary.byDayModel[key] = existing
        } else {
            summary.byDayModel[key] = DayModelUsage(day: day, model: summary.lastModel, counts: counts)
        }
    }

    // Reused across the (per-line) hot path to avoid allocating a formatter every
    // call. Configured once and only ever read via `date(from:)`, which is safe to
    // share across the concurrent Codex/Claude parse tasks.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }
}
