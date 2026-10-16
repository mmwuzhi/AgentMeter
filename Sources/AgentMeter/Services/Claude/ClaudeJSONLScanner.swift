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
    /// ever had activity. So periodically read everything instead. With the
    /// persistent cache that is a stat of every file and a read of the few
    /// that changed; it was 30–40 s of parsing before. `RefreshCoordinator`
    /// keeps the clock for the app (see `usageReport(completeHistory:)`);
    /// `usageReport()` keeps its own.
    static let fullHistoryInterval: TimeInterval = 6 * 3600

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

    /// Decides on its own clock whether this read is the periodic complete
    /// one. The app does not come through here: `RefreshCoordinator` decides
    /// per scan with `usageReport(completeHistory:)`, so a complete report
    /// that never lands is not counted as done.
    static func usageReport() async -> UsageReport {
        let now = Date()
        let completeHistory = await fullScanClock.claimFullScan(now: now, interval: fullHistoryInterval)
        return await usageReport(completeHistory: completeHistory, now: now)
    }

    /// Every log file when `completeHistory`, marking the report so the spend
    /// ledger may lower a day from it; otherwise only files touched in the last
    /// `usageHistoryDays`. Both read through the app's persistent cache.
    static func usageReport(completeHistory: Bool, now: Date = Date()) async -> UsageReport {
        let all = jsonlFiles()
        if completeHistory {
            return await usageReport(files: all, completeHistory: true, cache: .shared)
        }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -usageHistoryDays,
            to: Calendar.current.startOfDay(for: now)
        ) ?? Date.distantPast
        return await usageReport(files: recentLogFiles(all, modifiedSince: cutoff), cache: .shared)
    }

    /// `completeHistory` says `files` is every log file there is: only then
    /// may the store on disk drop the entries of files not listed, since a
    /// windowed scan lists only recent files and the next complete scan needs
    /// the rest.
    static func usageReport(
        files: [URL],
        completeHistory: Bool = false,
        cache: ClaudeUsageCache = .memoryOnly
    ) async -> UsageReport {
        // (day, model) -> counts, so cost uses the right model price.
        var byDayModel: [DayModelKey: DayModelUsage] = [:]

        // Sorted so which file "wins" a record shared with another file is the
        // same on every launch. The duplicates carry identical usage, so the
        // totals don't depend on the order — only reproducibility does.
        let fingerprints = files.sorted { $0.path < $1.path }
            .compactMap { url -> (URL, LogFileFingerprint)? in
                guard let fingerprint = LogFileFingerprint.current(for: url) else { return nil }
                return (url, fingerprint)
            }
        let scan = await cache.memory.beginScan()
        await cache.memory.prune(keeping: fingerprints.map(\.1))
        if completeHistory, let store = cache.store {
            await store.prune(keeping: fingerprints.map(\.1.path))
        }

        // Records already contributed by an earlier file. Per-file dedup is not
        // enough once a resumed session's transcript replays another file's
        // messages: over the full corpus that double-counted ~10% of all tokens,
        // and nearly doubled the oldest days.
        var seenDedupKeys = Set<DedupKey>()

        for (url, fingerprint) in fingerprints {
            let usage = await cachedUsage(in: url, fingerprint: fingerprint, cache: cache, scan: scan)
            for record in usage.keyed where seenDedupKeys.insert(record.key).inserted {
                accumulate(record.usage, into: &byDayModel)
            }
            for usage in usage.unkeyed {
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

    private struct DayModelKey: Hashable {
        let day: Date
        let model: String
    }

    private static func accumulate(
        _ usage: DayModelUsage,
        into byDayModel: inout [DayModelKey: DayModelUsage]
    ) {
        let key = DayModelKey(day: usage.day, model: usage.model)
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

    // MARK: - One file

    /// The file's contribution: from memory when the fingerprint matches
    /// exactly, else from the store on disk, else parsed — from the old end
    /// when a prior parse of the same filesystem object can be resumed and
    /// the bytes before that boundary still match, from the top otherwise.
    /// Whatever was parsed goes back to memory and, when it committed new
    /// lines, to the store.
    private static func cachedUsage(
        in url: URL,
        fingerprint: LogFileFingerprint,
        cache: ClaudeUsageCache,
        scan: UInt64
    ) async -> ClaudeFileUsage {
        if let cached = await cache.memory.value(for: fingerprint) {
            await cache.stats.memoryHit()
            return cached
        }
        var base = await cache.memory.incrementalBase(for: fingerprint)
        if base == nil, let store = cache.store, let entry = await store.entry(for: fingerprint.path) {
            if entry.fingerprint == fingerprint, entry.parsedBytes == fingerprint.size {
                await cache.memory.store(entry.value, for: fingerprint, parsedBytes: entry.parsedBytes, scan: scan)
                await cache.stats.storeHit()
                return entry.value
            }
            if LogFileParseCache<ClaudeFileUsage>.canResume(
                from: entry.fingerprint, parsedBytes: entry.parsedBytes, to: fingerprint) {
                base = (entry.value, entry.parsedBytes)
            }
        }
        // A grown file is resumed only while it still ends, at the old
        // boundary, the way it did: a file rewritten in place to something
        // longer would otherwise keep its old head out of the cache.
        if let candidate = base,
           !boundaryMatches(url, parsedBytes: candidate.parsedBytes, digest: candidate.value.boundaryDigest) {
            base = nil
        }

        var state = ParseState(resuming: base?.value)
        let startOffset = base?.parsedBytes ?? 0
        let cal = Calendar.current
        await cache.stats.opened()
        let result: JSONLLineReader.IncrementalResult?
        do {
            result = try JSONLLineReader.forEachCompleteLine(in: url, fromOffset: startOffset) { line in
                consume(line: line, into: &state, calendar: cal)
            }
        } catch {
            // A read that failed partway must not leave half its lines in the
            // cache: keep what was known before it.
            state = ParseState(resuming: base?.value)
            result = nil
        }
        let consumed = result?.consumed ?? startOffset
        let committed = consumed - startOffset
        if committed > 0 {
            state.usage.boundaryDigest = boundaryDigest(of: url, endingAt: consumed) ?? ClaudeFileUsage.empty.boundaryDigest
        }
        await cache.stats.parsed(resumed: base != nil, bytes: committed)
        // Cache only the clean line-boundary summary so an incremental resume can't
        // double-count; fold a trailing (not-yet-newline-terminated) record into the
        // value shown now without caching it — the next pass re-reads it once it's
        // complete.
        await cache.memory.store(state.usage, for: fingerprint, parsedBytes: consumed, scan: scan)
        if result != nil, committed > 0 || base == nil, let store = cache.store {
            await store.save(
                ClaudeUsageCacheStore.Entry(fingerprint: fingerprint, parsedBytes: consumed, value: state.usage),
                scan: scan)
        }
        guard let trailing = result?.trailing else { return state.usage }
        var display = state
        JSONLLineReader.withLine(trailing) { consume(line: $0, into: &display, calendar: cal) }
        return display.usage
    }

    /// The last `ClaudeUsageCacheStore.boundarySampleLength` bytes before
    /// `end`, digested; nil when the file cannot be read that far.
    private static func boundaryDigest(of url: URL, endingAt end: Int64) -> Data? {
        guard let sample = boundarySample(of: url, endingAt: end) else { return nil }
        return ClaudeUsageCacheStore.boundaryDigest(of: sample)
    }

    private static func boundaryMatches(_ url: URL, parsedBytes: Int64, digest: Data) -> Bool {
        boundaryDigest(of: url, endingAt: parsedBytes) == digest
    }

    private static func boundarySample(of url: URL, endingAt end: Int64) -> Data? {
        let length = Int(min(end, Int64(ClaudeUsageCacheStore.boundarySampleLength)))
        guard length > 0 else { return Data() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(end - Int64(length)))) != nil,
              let sample = try? handle.read(upToCount: length),
              sample.count == length else { return nil }
        return sample
    }

    /// A file's usage while it is being parsed: the value under construction
    /// plus the indexes that keep repeats out of it, rebuilt from a cached
    /// value when resuming.
    private struct ParseState {
        var usage: ClaudeFileUsage
        var seen: Set<DedupKey>
        var unkeyedIndex: [DayModelKey: Int]

        init(resuming base: ClaudeFileUsage?) {
            usage = base ?? .empty
            seen = Set(usage.keyed.map(\.key))
            unkeyedIndex = [:]
            for (index, entry) in usage.unkeyed.enumerated() {
                unkeyedIndex[DayModelKey(day: entry.day, model: entry.model)] = index
            }
        }

        mutating func add(unkeyed entry: DayModelUsage) {
            let key = DayModelKey(day: entry.day, model: entry.model)
            if let index = unkeyedIndex[key] {
                usage.unkeyed[index].counts.add(entry.counts)
            } else {
                unkeyedIndex[key] = usage.unkeyed.count
                usage.unkeyed.append(entry)
            }
        }
    }

    private static func consume(
        line: JSONLLineReader.LogLine,
        into state: inout ParseState,
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
            state.add(unkeyed: entry)
            return
        }
        // First occurrence wins; a repeat inside this file is a replay of the
        // same message, and `usageReport(files:)` drops repeats across files.
        let key = DedupKey(messageID: mid, requestID: rid)
        guard state.seen.insert(key).inserted else { return }
        state.usage.keyed.append(KeyedUsage(key: key, usage: entry))
    }
}
