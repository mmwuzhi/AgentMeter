import Foundation

/// Parses Claude Code local logs for token usage and spend (ccusage-style).
/// Globs `<config>/projects/**/*.jsonl`, dedups by `message.id`, sums usage,
/// computes cost from PricingService. Fully local — no network.
enum ClaudeJSONLScanner {
    /// Keep the always-on menu bar refresh cheap. The UI presents local day,
    /// 7-day, and 30-day windows, so most refreshes only need logs that could
    /// affect those windows.
    private static let usageHistoryDays = 31

    /// ...but a windowed refresh silently drops a day once its files stop being
    /// touched, and the heatmap and the persisted ledger want every day that
    /// ever had activity. So periodically read everything instead. At a few
    /// seconds for a multi-GB corpus that is affordable a handful of times a
    /// day — it was not when this scanner went through `String` per line.
    private static let fullHistoryInterval: TimeInterval = 6 * 3600

    private struct FileUsageSummary: Sendable {
        /// One entry per deduplicated record, keyed by `message.id|requestId`.
        /// Kept per record rather than pre-aggregated so `usageReport(files:)`
        /// can drop a record another file already contributed: resuming a
        /// session copies the earlier transcript into a new file, so the same
        /// assistant message appears in both. Aggregating first hid that and
        /// counted those messages twice.
        var byDedupKey: [String: DayModelUsage] = [:]
        /// Records carrying no `message.id`, which cannot be deduplicated at
        /// all; summed per (day, model) instead.
        var unkeyed: [String: DayModelUsage] = [:]
    }

    private static let usageCache = LogFileParseCache<FileUsageSummary>()

    /// Cheap pre-filter: most records in a transcript carry no usage block, and
    /// parsing them all costs far more than the byte search that skips them.
    private static let usageMarker = JSONLLineReader.Marker("\"usage\"")

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
        let now = Date()
        let all = jsonlFiles()
        if await fullScanClock.claimFullScan(now: now, interval: fullHistoryInterval) {
            return await usageReport(files: all, completeHistory: true)
        }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -usageHistoryDays,
            to: Calendar.current.startOfDay(for: now)
        ) ?? Date.distantPast
        return await usageReport(files: recentLogFiles(all, modifiedSince: cutoff))
    }

    static func usageReport(files: [URL], completeHistory: Bool = false) async -> UsageReport {
        // (day, model) -> counts, so cost uses the right model price.
        var byDayModel: [String: DayModelUsage] = [:]

        // Sorted so which file "wins" a record shared with another file is the
        // same on every launch. The duplicates carry identical usage, so the
        // totals don't depend on the order — only reproducibility does.
        let fingerprints = files.sorted { $0.path < $1.path }
            .compactMap { url -> (URL, LogFileFingerprint)? in
                guard let fingerprint = LogFileFingerprint.current(for: url) else { return nil }
                return (url, fingerprint)
            }
        await usageCache.prune(keeping: fingerprints.map(\.1))

        // Records already contributed by an earlier file. Per-file dedup is not
        // enough once a resumed session's transcript replays another file's
        // messages: over the full corpus that double-counted ~10% of all tokens,
        // and nearly doubled the oldest days.
        var seenDedupKeys = Set<String>()

        for (url, fingerprint) in fingerprints {
            let summary = await cachedUsageSummary(in: url, fingerprint: fingerprint)
            for (dedupKey, usage) in summary.byDedupKey {
                guard seenDedupKeys.insert(dedupKey).inserted else { continue }
                accumulate(usage, into: &byDayModel)
            }
            for (_, usage) in summary.unkeyed {
                accumulate(usage, into: &byDayModel)
            }
        }

        // Dollars are computed where they are shown, under the table current
        // then; the rollup prices once now only for the fields older builds
        // still read out of `last-state.json`.
        let table = await PricingService.shared.snapshot()
        return UsageRollup.report(provider: .claude, entries: Array(byDayModel.values),
                                  table: table, isCompleteHistory: completeHistory)
    }

    private static func accumulate(
        _ usage: DayModelUsage,
        into byDayModel: inout [String: DayModelUsage]
    ) {
        let key = "\(usage.day.timeIntervalSince1970)|\(usage.model)"
        guard var existing = byDayModel[key] else {
            byDayModel[key] = usage
            return
        }
        existing.counts.add(usage.counts)
        byDayModel[key] = existing
    }

    /// Tracks when the last unwindowed scan ran. An actor because overlapping
    /// refreshes can enter `usageReport()` at the same time, and only one of
    /// them should pay for the full read.
    private actor FullScanClock {
        private var lastFullScan: Date?

        /// True at most once per `interval`, and always on the first call after
        /// launch — a fresh process has no ledger-correcting scan behind it.
        func claimFullScan(now: Date, interval: TimeInterval) -> Bool {
            if let lastFullScan, now.timeIntervalSince(lastFullScan) < interval { return false }
            lastFullScan = now
            return true
        }
    }

    private static let fullScanClock = FullScanClock()

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
        JSONLLineReader.withLine(trailing) { consume(line: $0, into: &display, calendar: cal) }
        return display
    }

    private static func consume(
        line: JSONLLineReader.LogLine,
        into summary: inout FileUsageSummary,
        calendar cal: Calendar
    ) {
        guard line.contains(usageMarker),
              let obj = line.jsonObject(),
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }

        let model = (message["model"] as? String) ?? "default"
        if model == "<synthetic>" { return }

        let mid = (message["id"] as? String) ?? ""
        let rid = (obj["requestId"] as? String) ?? ""

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
        let entry = DayModelUsage(day: day, model: model, counts: counts)

        guard !mid.isEmpty else {
            // No message id to dedup on; fold it into the per-(day, model) bucket.
            let key = "\(day.timeIntervalSince1970)|\(model)"
            if var existing = summary.unkeyed[key] {
                existing.counts.add(counts)
                summary.unkeyed[key] = existing
            } else {
                summary.unkeyed[key] = entry
            }
            return
        }
        // First occurrence wins; a repeat inside this file is a replay of the
        // same message, and `usageReport(files:)` drops repeats across files.
        let dedupKey = mid + "|" + rid
        if summary.byDedupKey[dedupKey] == nil {
            summary.byDedupKey[dedupKey] = entry
        }
    }
}
