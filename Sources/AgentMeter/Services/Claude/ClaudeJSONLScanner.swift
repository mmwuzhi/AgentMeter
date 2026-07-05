import Foundation

/// Parses Claude Code local logs for token usage and spend (ccusage-style).
/// Globs `<config>/projects/**/*.jsonl`, dedups by `message.id`, sums usage,
/// computes cost from PricingService. Fully local — no network.
enum ClaudeJSONLScanner {
    /// Keep the always-on menu bar refresh cheap. The UI presents local day,
    /// 7-day, and 30-day windows, so background refreshes only need logs that
    /// could affect those windows. A full historical index should be a separate,
    /// persisted/on-demand feature rather than work done every minute.
    private static let usageHistoryDays = 31

    private struct FileUsageSummary: Sendable {
        var byDayModel: [String: DayModelUsage] = [:]
    }

    private struct DayModelUsage: Sendable {
        let day: Date
        let model: String
        var counts: TokenCounts
    }

    private static let usageCache = LogFileParseCache<FileUsageSummary>()

    /// Resolve config dirs: $CLAUDE_CONFIG_DIR (comma list), XDG, ~/.claude.
    static func configDirs() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            for p in env.split(separator: ",") {
                dirs.append(URL(fileURLWithPath: p.trimmingCharacters(in: .whitespaces)))
            }
        }
        let home = fm.homeDirectoryForCurrentUser
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            dirs.append(URL(fileURLWithPath: xdg).appendingPathComponent("claude"))
        } else {
            dirs.append(home.appendingPathComponent(".config/claude"))
        }
        dirs.append(home.appendingPathComponent(".claude"))
        // Keep only those with a projects/ subdir.
        return dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("projects").path) }
    }

    static func jsonlFiles() -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        var scanned = Set<String>()   // resolve 后的目录去重,避免多个软链指同一 store 重复扫
        for dir in configDirs() {
            let projects = dir.appendingPathComponent("projects", isDirectory: true)
            // projects/<key> 可能是软链(SessionStart hook 把工程历史共享到统一 store)。
            // FileManager 的枚举器不下降进软链目录,所以先 resolve 每个子项再递归。
            guard let entries = try? fm.contentsOfDirectory(
                    at: projects, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let resolved = entry.resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                fm.fileExists(atPath: resolved.path, isDirectory: &isDir)
                if isDir.boolValue {
                    guard scanned.insert(resolved.path).inserted else { continue }
                    guard let en = fm.enumerator(at: resolved, includingPropertiesForKeys: nil) else { continue }
                    for case let url as URL in en where url.pathExtension == "jsonl" {
                        files.append(url)
                    }
                } else if resolved.pathExtension == "jsonl" {
                    files.append(resolved)   // 极少数直接躺在 projects/ 下的 jsonl
                }
            }
        }
        return files
    }

    static func usageReport() async -> UsageReport {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -usageHistoryDays,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date.distantPast
        return await usageReport(files: recentLogFiles(jsonlFiles(), modifiedSince: cutoff))
    }

    static func usageReport(files: [URL]) async -> UsageReport {
        // (day, model) -> counts, so cost uses the right model price.
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
                    existing.counts.output += usage.counts.output
                    existing.counts.cacheRead += usage.counts.cacheRead
                    existing.counts.cacheWrite5m += usage.counts.cacheWrite5m
                    existing.counts.cacheWrite1h += usage.counts.cacheWrite1h
                    byDayModel[key] = existing
                } else {
                    byDayModel[key] = (usage.day, usage.model, usage.counts)
                }
            }
        }

        // Roll up per-day (summing across models, cost computed per model) and
        // per-model (all-time, for the spend breakdown).
        var bucketByDay: [Date: UsageBucket] = [:]
        var modelTotals: [String: (tokens: Int, cost: Double)] = [:]
        var totalCost = 0.0
        for (_, entry) in byDayModel {
            let cost = await PricingService.shared.cost(model: entry.model, counts: entry.counts)
            totalCost += cost
            var b = bucketByDay[entry.day] ?? UsageBucket(day: entry.day, inputTokens: 0, outputTokens: 0,
                        cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: 0)
            b = UsageBucket(day: entry.day,
                            inputTokens: b.inputTokens + entry.counts.input,
                            outputTokens: b.outputTokens + entry.counts.output,
                            cacheWrite5m: b.cacheWrite5m + entry.counts.cacheWrite5m,
                            cacheWrite1h: b.cacheWrite1h + entry.counts.cacheWrite1h,
                            cacheRead: b.cacheRead + entry.counts.cacheRead,
                            costUSD: b.costUSD + cost)
            bucketByDay[entry.day] = b

            let entryTokens = entry.counts.input + entry.counts.output
                + entry.counts.cacheWrite5m + entry.counts.cacheWrite1h + entry.counts.cacheRead
            var mt = modelTotals[entry.model] ?? (0, 0)
            mt.tokens += entryTokens
            mt.cost += cost
            modelTotals[entry.model] = mt
        }

        let buckets = bucketByDay.values.sorted { $0.day < $1.day }
        let totalTokens = buckets.reduce(0) { $0 + $1.totalTokens }
        let byModel = modelTotals
            .map { ModelSpend(model: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted { $0.costUSD > $1.costUSD }
        return UsageReport(provider: .claude, buckets: buckets, totalCostUSD: totalCost,
                           totalTokens: totalTokens, byModel: byModel)
    }

    static func recentLogFiles(_ files: [URL], modifiedSince cutoff: Date) -> [URL] {
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
        let summary = parseUsageSummary(in: url)
        await usageCache.store(summary, for: fingerprint)
        return summary
    }

    private static func parseUsageSummary(in url: URL) -> FileUsageSummary {
        let cal = Calendar.current
        var seen = Set<String>()
        var summary = FileUsageSummary()
        try? JSONLLineReader.forEachLine(in: url) { line in
            guard line.contains("\"usage\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }

            let model = (message["model"] as? String) ?? "default"
            if model == "<synthetic>" { return }

            let mid = (message["id"] as? String) ?? ""
            let rid = (obj["requestId"] as? String) ?? ""
            let dedupKey = mid + "|" + rid
            if !mid.isEmpty {
                guard seen.insert(dedupKey).inserted else { return }
            }

            var counts = TokenCounts()
            counts.input = (usage["input_tokens"] as? Int) ?? 0
            counts.output = (usage["output_tokens"] as? Int) ?? 0
            counts.cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            if let cc = usage["cache_creation"] as? [String: Any] {
                counts.cacheWrite5m = (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
                counts.cacheWrite1h = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
            } else {
                counts.cacheWrite5m = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            }

            let ts = (obj["timestamp"] as? String).flatMap(CodexRolloutReader.parseISO) ?? Date()
            let day = cal.startOfDay(for: ts)
            let key = "\(day.timeIntervalSince1970)|\(model)"
            if var existing = summary.byDayModel[key] {
                existing.counts.input += counts.input
                existing.counts.output += counts.output
                existing.counts.cacheRead += counts.cacheRead
                existing.counts.cacheWrite5m += counts.cacheWrite5m
                existing.counts.cacheWrite1h += counts.cacheWrite1h
                summary.byDayModel[key] = existing
            } else {
                summary.byDayModel[key] = DayModelUsage(day: day, model: model, counts: counts)
            }
        }
        return summary
    }
}
