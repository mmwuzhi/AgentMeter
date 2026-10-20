import Foundation

/// Parses Claude Code local logs for token usage and spend (ccusage-style).
/// Globs `<config>/projects/**/*.jsonl`, counts one record per
/// `message.id|requestId` — the request's final record when there is one
/// (`KeyedUsage.outranks`) — and computes cost from PricingService. Fully
/// local — no network.
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
    static func usageReport(
        completeHistory: Bool, now: Date = Date(), history: (any HistoryIngesting)? = nil
    ) async -> UsageReport {
        let all = jsonlFiles()
        if completeHistory {
            return await usageReport(files: all, completeHistory: true, cache: .shared, history: history)
        }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -usageHistoryDays,
            to: Calendar.current.startOfDay(for: now)
        ) ?? Date.distantPast
        return await usageReport(files: recentLogFiles(all, modifiedSince: cutoff), cache: .shared, history: history)
    }

    /// `completeHistory` says `files` is every log file there is: only then
    /// may the store on disk drop the entries of files not listed, since a
    /// windowed scan lists only recent files and the next complete scan needs
    /// the rest.
    ///
    /// With a `history`, the scan also hands it one `HistoryScanBatch` — a
    /// batch per listed file whose read did not fail, built from the values
    /// the scan holds anyway — after the last file, without waiting for it.
    static func usageReport(
        files: [URL],
        completeHistory: Bool = false,
        cache: ClaudeUsageCache = .memoryOnly,
        history: (any HistoryIngesting)? = nil
    ) async -> UsageReport {
        let startedMs = HistoryTime.ms(Date())
        // Sorted so which file's copy stands for a record shared with another
        // file is the same on every launch: a later file's copy replaces an
        // earlier one's only when it outranks it (`KeyedUsage.outranks`).
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

        // One record per key across every file. Per-file dedup is not enough
        // once a resumed session's transcript replays another file's
        // messages: over the full corpus that double-counted ~10% of all
        // tokens, and nearly doubled the oldest days.
        var selection = UsageSelection()
        var batches: [HistoryFileBatch] = []
        if history != nil { batches.reserveCapacity(fingerprints.count) }
        // A listed file that vanished before it could be stat'ed, or whose read
        // failed, is in no batch: the scan then did not cover the corpus, and
        // the history must not record "requests complete through now".
        var coveredEveryFile = fingerprints.count == files.count
        for (url, fingerprint) in fingerprints {
            let fileScan = await cachedUsage(in: url, fingerprint: fingerprint, cache: cache, scan: scan,
                                             tracksChanges: history != nil)
            selection.add(fileScan.display)
            if fileScan.origin == .readFailed { coveredEveryFile = false }
            if history != nil, let batch = fileScan.historyBatch(scan: scan) { batches.append(batch) }
        }
        // Synchronous and O(1): the history queues the batch and applies it
        // on its own executor; the report never waits for the database.
        history?.submit(scan: HistoryScanBatch(ticket: scan, startedMs: startedMs,
                                               isCompleteHistory: completeHistory && coveredEveryFile,
                                               files: batches))

        // (day, model) -> counts, so cost uses the right model price.
        var byDayModel: [DayModelKey: DayModelUsage] = [:]
        var finality: [Date: RequestFinalityCounts] = [:]
        selection.forEachRecord { record in
            finality[record.usage.day, default: RequestFinalityCounts()].count(record)
            // A zeroed replay — or an iteration that counted nothing —
            // carries nothing, and must not leave an empty (day, model)
            // behind for the ledger.
            guard record.finality != .zeroed else { return }
            record.forEachPart { if $0.counts.total > 0 { accumulate($0, into: &byDayModel) } }
        }
        selection.forEachUnkeyed { if $0.counts.total > 0 { accumulate($0, into: &byDayModel) } }

        // Dollars are computed where they are shown, under the table current
        // then; the rollup prices once now only for the fields older builds
        // still read out of `last-state.json`.
        let table = await PricingService.shared.snapshot()
        var report = UsageRollup.report(provider: .claude, entries: Array(byDayModel.values),
                                        table: table, isCompleteHistory: completeHistory)
        report.requestFinality = finality
        return report
    }

    /// Each of `files`, in the order given, read through `cache` exactly as a
    /// scan reads it (`cachedUsage`): from memory, from the store, or parsed,
    /// resumed where an earlier read stopped. A session row reads its
    /// transcripts here, so the row, the usage report and the history all
    /// count the same records from one parse. Prunes nothing; the scans own
    /// that. The usage is `display` (an unterminated last line folded in); a
    /// file that cannot be stat'ed is `.empty`. Pass each path spelled as the
    /// scan lists it (`ActiveAgentService.scanSpelling`): the cache and the
    /// history key on the path, and a second spelling of one file would be a
    /// second entry and a second history file.
    ///
    /// With a `history`, each file this read resumed and took further goes to
    /// it as a session read (`HistoryScanBatch.isSessionRead`): applied when
    /// its delta sits on exactly what the store holds, so the next scan finds
    /// the file in step; otherwise skipped, and that scan brings it. A file
    /// read from the top, or not read at all, is left to the scans.
    static func fileUsages(
        _ files: [URL], cache: ClaudeUsageCache, history: (any HistoryIngesting)? = nil
    ) async -> [ClaudeFileUsage] {
        let startedMs = HistoryTime.ms(Date())
        let scan = await cache.memory.beginScan()
        var usages: [ClaudeFileUsage] = []
        usages.reserveCapacity(files.count)
        var batches: [HistoryFileBatch] = []
        for url in files {
            guard let fingerprint = LogFileFingerprint.current(for: url) else {
                usages.append(.empty)
                continue
            }
            let fileScan = await cachedUsage(in: url, fingerprint: fingerprint, cache: cache, scan: scan,
                                             tracksChanges: history != nil)
            usages.append(fileScan.display)
            if history != nil, let base = fileScan.resume, base.parsedBytes < fileScan.parsedBytes,
               let batch = fileScan.historyBatch(scan: scan) {
                batches.append(batch)
            }
        }
        if let history, !batches.isEmpty {
            history.submit(scan: HistoryScanBatch(ticket: scan, startedMs: startedMs, isCompleteHistory: false,
                                                   files: batches, isSessionRead: true))
        }
        return usages
    }

    struct DayModelKey: Hashable {
        let day: Date
        let model: String
    }

    /// Picks one record per key out of several files' contributions, the
    /// files added in a fixed order: the report's (every scanned log, in
    /// path order) and a session row's (its transcript, then its subagents').
    /// Holds a reference per key instead of a copy of the record, so a scan
    /// of every log costs about what the set of seen keys it replaced did.
    struct UsageSelection {
        private struct Ref {
            let file: Int32
            let record: Int32
        }

        private var files: [ClaudeFileUsage] = []
        private var chosen: [DedupKey: Ref] = [:]
        /// The day a key keeps when a later file's copy replaced the one it
        /// was first counted from on another day (`KeyedUsage.replacing`).
        /// Copies keep their original timestamps, so this stays empty in
        /// practice.
        private var keptDays: [DedupKey: Date] = [:]

        mutating func add(_ usage: ClaudeFileUsage) {
            let file = Int32(files.count)
            files.append(usage)
            for (index, record) in usage.keyed.enumerated() {
                let ref = Ref(file: file, record: Int32(index))
                // One hash lookup for a key seen for the first time, which is
                // nearly every key; a repeat puts the held record back unless
                // this one outranks it.
                guard let held = chosen.updateValue(ref, forKey: record.key) else { continue }
                let heldRecord = files[Int(held.file)].keyed[Int(held.record)]
                guard record.outranks(heldRecord) else {
                    chosen[record.key] = held
                    continue
                }
                let day = record.replacing(heldRecord).usage.day
                let keptDay = keptDays[record.key] ?? day
                if keptDay != record.usage.day {
                    keptDays[record.key] = keptDay
                }
            }
        }

        /// Each key's record, in no particular order.
        func forEachRecord(_ body: (KeyedUsage) -> Void) {
            for (key, ref) in chosen {
                let record = files[Int(ref.file)].keyed[Int(ref.record)]
                if !keptDays.isEmpty, let day = keptDays[key] {
                    body(record.filed(on: day))
                } else {
                    body(record)
                }
            }
        }

        /// Records without a message id, which cannot be matched across
        /// files and all count.
        func forEachUnkeyed(_ body: (DayModelUsage) -> Void) {
            for file in files {
                for usage in file.unkeyed { body(usage) }
            }
        }

        /// What every chosen record and unkeyed bucket adds up to, per model.
        func countsByModel() -> [String: TokenCounts] {
            var totals: [String: TokenCounts] = [:]
            forEachRecord { record in
                guard record.finality != .zeroed else { return }
                record.forEachPart { totals[$0.model, default: TokenCounts()].add($0.counts) }
            }
            forEachUnkeyed { totals[$0.model, default: TokenCounts()].add($0.counts) }
            return totals
        }
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

    /// What one scan made of one log file: the committed state the cache and
    /// the history hold, the state the report counts, and where it came from.
    struct FileScan: Sendable {
        enum Origin: Sendable, Equatable {
            /// The fingerprint matched what memory holds; nothing was read.
            case memory
            /// The fingerprint matched the store's entry; nothing was read.
            case store
            /// Parsed from byte 0: no base, or a base that could not be resumed.
            case fromTop
            /// Parsed from the end of an earlier parse of the same file.
            case resumed
            /// The read failed; `usage` is what was known before it.
            case readFailed
        }

        /// The base a resumed parse continued from, and the indexes of the
        /// keyed records that differ from it in any field (new keys,
        /// replaced records, stamps whose times or flags grew). The base
        /// itself is not kept.
        struct Resume: Sendable, Equatable {
            let parsedBytes: Int64
            let boundaryDigest: Data
            let changed: [Int]
        }

        let fingerprint: LogFileFingerprint
        /// The line boundary `usage` accounts for: `fingerprint.size` for a
        /// memory or store hit, never past it.
        let parsedBytes: Int64
        /// Committed state, up to `parsedBytes`: what the store holds and the
        /// history ingests.
        let usage: ClaudeFileUsage
        /// `usage` plus an unterminated last line: what the report counts.
        let display: ClaudeFileUsage
        let origin: Origin
        /// Resumed parses that track changes only (a scan with a history).
        let resume: Resume?
    }

    /// Indexes of `now`'s keyed records that are new or differ from `base`'s
    /// in any field. A parse only appends keys or rewrites one in place, so
    /// index i < base.keyed.count still holds base's key.
    static func changedIndexes(from base: ClaudeFileUsage, to now: ClaudeFileUsage) -> [Int] {
        assert(now.keyed.count >= base.keyed.count)
        var changed: [Int] = []
        for i in base.keyed.indices where now.keyed[i] != base.keyed[i] { changed.append(i) }
        changed.append(contentsOf: base.keyed.count..<now.keyed.count)
        return changed
    }

    /// The file's contribution: from memory when the fingerprint matches
    /// exactly, else from the store on disk, else parsed — from the old end
    /// when a prior parse of the same filesystem object can be resumed and
    /// the bytes before that boundary still match, from the top otherwise.
    /// Whatever was parsed goes back to memory and, when it committed new
    /// lines, to the store. Reads stop at `fingerprint.size`: bytes appended
    /// since the fingerprint was taken wait for the next scan, so what is
    /// stored never claims more than the fingerprint it is stored under.
    /// `tracksChanges` computes `FileScan.Resume.changed` for a resumed parse.
    ///
    /// When memory already holds the same file further on than `taken` (a
    /// session row read it after this scan fingerprinted it), the file is
    /// read as it stands now: from `taken`, no base is left to resume from,
    /// and the whole file would be parsed again.
    static func cachedUsage(
        in url: URL,
        fingerprint taken: LogFileFingerprint,
        cache: ClaudeUsageCache,
        scan: UInt64,
        tracksChanges: Bool = false
    ) async -> FileScan {
        var fingerprint = taken
        if let held = await cache.memory.fingerprint(forPath: taken.path), held.size > taken.size,
           held.hasSameStableIdentity(as: taken), let now = LogFileFingerprint.current(for: url),
           now.hasSameStableIdentity(as: held), now.size >= held.size {
            fingerprint = now
        }
        if let cached = await cache.memory.value(for: fingerprint) {
            await cache.stats.memoryHit()
            return FileScan(fingerprint: fingerprint, parsedBytes: fingerprint.size, usage: cached, display: cached,
                            origin: .memory, resume: nil)
        }
        var base = await cache.memory.incrementalBase(for: fingerprint)
        if base == nil, let store = cache.store, let entry = await store.entry(for: fingerprint.path) {
            if entry.fingerprint == fingerprint, entry.parsedBytes == fingerprint.size {
                await cache.memory.store(entry.value, for: fingerprint, parsedBytes: entry.parsedBytes, scan: scan)
                await cache.stats.storeHit()
                return FileScan(fingerprint: fingerprint, parsedBytes: entry.parsedBytes, usage: entry.value,
                                display: entry.value, origin: .store, resume: nil)
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
            result = try JSONLLineReader.forEachCompleteLine(
                in: url, fromOffset: startOffset, upTo: fingerprint.size
            ) { line in
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
        let origin: FileScan.Origin = result == nil ? .readFailed : (base == nil ? .fromTop : .resumed)
        var resume: FileScan.Resume?
        if tracksChanges, origin == .resumed, let base {
            resume = FileScan.Resume(parsedBytes: base.parsedBytes, boundaryDigest: base.value.boundaryDigest,
                                     changed: changedIndexes(from: base.value, to: state.usage))
        }
        var display = state.usage
        if let trailing = result?.trailing {
            var shown = state
            JSONLLineReader.withLine(trailing) { consume(line: $0, into: &shown, calendar: cal) }
            display = shown.usage
        }
        return FileScan(fingerprint: fingerprint, parsedBytes: consumed, usage: state.usage, display: display,
                        origin: origin, resume: resume)
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
    /// plus the indexes that keep one record per key in it, rebuilt from a
    /// cached value when resuming. Everything `KeyedUsage.outranks` compares
    /// is part of the cached value, so a parse resumed at a line boundary
    /// settles on the same records as one from the top.
    ///
    /// Everything a step reads is part of `usage` or rebuilt from it by a
    /// pure function (the indexes and the event id sets), and nothing is
    /// clamped when `usage` is encoded, so a resume from a decoded entry is
    /// the same transition a parse from the top makes.
    struct ParseState: Sendable {
        var usage: ClaudeFileUsage
        /// `collectsCompactEvents` of the scanner, unless a benchmark turns it off.
        let collectsCompactEvents: Bool
        private var keyedIndex: [DedupKey: Int]
        private var unkeyedIndex: [DayModelKey: Int]
        private var attributeIndex: [RecordAttributes: UInt16]
        private var limitEventKeys: Set<String>
        private var usageReportIDs: Set<String>
        private var costStateIDs: Set<CostStateID>
        private var compactEventIDs: Set<String>

        private struct CostStateID: Hashable {
            let startTimeMs: Int64
            let totalDurationMs: Int64
        }

        init(resuming base: ClaudeFileUsage?,
             collectsCompactEvents: Bool = ClaudeJSONLScanner.collectsCompactEvents) {
            usage = base ?? .empty
            self.collectsCompactEvents = collectsCompactEvents
            keyedIndex = Dictionary(
                usage.keyed.enumerated().map { ($0.element.key, $0.offset) },
                uniquingKeysWith: { first, _ in first })
            unkeyedIndex = [:]
            for (index, entry) in usage.unkeyed.enumerated() {
                unkeyedIndex[DayModelKey(day: entry.day, model: entry.model)] = index
            }
            attributeIndex = [:]
            for (offset, set) in usage.attributeSets.enumerated() where attributeIndex[set] == nil {
                attributeIndex[set] = UInt16(offset + 1)
            }
            let extras = usage.extras
            limitEventKeys = Set(extras.limitEvents.map { Self.limitEventKey(uuid: $0.uuid, requestID: $0.requestID) })
            usageReportIDs = Set(extras.usageReports.map(\.uuid))
            costStateIDs = Set(extras.costStates.map { CostStateID(startTimeMs: $0.startTimeMs, totalDurationMs: $0.totalDurationMs) })
            compactEventIDs = Set(extras.compactEvents.map(\.uuid))
        }

        enum Outcome: Equatable { case newKey, replaced, kept }

        /// Files `record` under its key: as the first of the key in the file,
        /// in place of the held record it outranks, or — not counted — only
        /// folding its times and flags into the held record's stamp.
        /// `record.stamp` carries its own times and flags only; the caller
        /// sets attributes and thinking through `index` when it stands.
        mutating func insert(_ record: KeyedUsage) -> (outcome: Outcome, index: Int) {
            guard let index = keyedIndex[record.key] else {
                keyedIndex[record.key] = usage.keyed.count
                usage.keyed.append(record)
                return (.newKey, usage.keyed.count - 1)
            }
            let held = usage.keyed[index]
            guard record.outranks(held) else {
                var merged = held.stamp
                merged.absorb(record.stamp)
                // Written only on a change: an unchanged stamp (every
                // same-time replay) costs no copy of the array.
                if merged != held.stamp { usage.keyed[index].stamp = merged }
                return (.kept, index)
            }
            usage.keyed[index] = record.replacing(held)
            return (.replaced, index)
        }

        /// The standing record's own attributes and thinking tokens.
        mutating func setAttributes(_ attributes: RecordAttributes, thinking: UInt32, at index: Int) {
            let interned = intern(attributes)
            if usage.keyed[index].stamp.attributes != interned { usage.keyed[index].stamp.attributes = interned }
            if usage.keyed[index].stamp.thinking != thinking { usage.keyed[index].stamp.thinking = thinking }
        }

        private mutating func intern(_ attributes: RecordAttributes) -> UInt16 {
            if attributes.version == nil, attributes.effort == nil, attributes.entrypoint == nil { return 0 }
            if let known = attributeIndex[attributes] { return known }
            guard usage.attributeSets.count < Int(UInt16.max) else { return 0 }
            usage.attributeSets.append(attributes)
            let index = UInt16(usage.attributeSets.count)
            attributeIndex[attributes] = index
            return index
        }

        // MARK: Extras

        /// Running MAX over usage records: what a cost state read later is "after".
        mutating func noteUsageTime(_ ms: Int64) {
            if usage.usageHighWaterMs == RecordStamp.noTime || ms > usage.usageHighWaterMs {
                usage.usageHighWaterMs = ms
            }
        }

        /// The file's first cwd / entrypoint / version: the first-of-key
        /// record with the earliest timestamp, ties to the smaller cwd (a
        /// record without one sorts last). Replays of older requests with
        /// another cwd are not first of their key and never take part.
        mutating func noteFirstRecord(_ ms: Int64, cwd rawCWD: Any?, attributes: RecordAttributes) {
            let extras = usage.extras
            if let held = extras.firstCwdMs, ms > held { return }
            let cwd = ClaudeJSONLScanner.cwd(rawCWD)
            if let held = extras.firstCwdMs, ms == held {
                // Equal times: the smaller cwd in UTF-8 byte order (SQLite's
                // BINARY collation) wins; nil loses to any cwd.
                guard let cwd else { return }
                if let heldCWD = extras.firstCwd, !cwd.utf8.lexicographicallyPrecedes(heldCWD.utf8) { return }
            }
            usage.extras.firstCwdMs = ms
            usage.extras.firstCwd = cwd
            usage.extras.firstEntrypoint = attributes.entrypoint
            usage.extras.firstCcVersion = attributes.version
        }

        static func limitEventKey(uuid: String, requestID: String?) -> String {
            requestID.map { "r:" + $0 } ?? "u:" + uuid
        }

        /// A `<synthetic>` 429's `quotaLimits` — or, from Claude Code 2.1.299,
        /// `apiErrorParams.rate_limit_info` — deduplicated by request id
        /// (uuid when there is none), as the history keys it.
        mutating func addLimitEvent(_ obj: [String: Any], tsMs: Int64?) {
            guard let tsMs, usage.extras.limitEvents.count < ClaudeUsageCacheStore.maxEventsPerKind else { return }
            let info: [String: Any]
            let source: String
            if let quota = obj["quotaLimits"] as? [String: Any] {
                (info, source) = (quota, "quotaLimits")
            } else if let params = obj["apiErrorParams"] as? [String: Any],
                      let rateLimit = params["rate_limit_info"] as? [String: Any] {
                (info, source) = (rateLimit, "rate_limit_info")
            } else {
                return
            }
            guard let uuid = ClaudeJSONLScanner.label(obj["uuid"]),
                  let window = ClaudeJSONLScanner.label(info["rateLimitType"]) else { return }
            let requestID = ClaudeJSONLScanner.label(obj["requestId"])
            guard limitEventKeys.insert(Self.limitEventKey(uuid: uuid, requestID: requestID)).inserted else { return }
            usage.extras.limitEvents.append(LimitEventObservation(
                uuid: uuid, requestID: requestID, tsMs: tsMs, windowID: window,
                status: ClaudeJSONLScanner.label(info["status"]),
                resetsAtMs: ClaudeJSONLScanner.integer(info["resetsAt"]).flatMap(ClaudeJSONLScanner.msFromSeconds),
                overageStatus: ClaudeJSONLScanner.label(info["overageStatus"]),
                overageDisabledReason: ClaudeJSONLScanner.label(info["overageDisabledReason"]),
                isUsingOverage: ClaudeJSONLScanner.boolean(info["isUsingOverage"]),
                fallbackAvailable: ClaudeJSONLScanner.boolean(info["unifiedRateLimitFallbackAvailable"]),
                source: source,
                apiError: ClaudeJSONLScanner.label(obj["apiError"]),
                ccVersion: ClaudeJSONLScanner.label(obj["version"])))
        }

        /// A `system/local_command` record carrying `usageReport` (`/usage`).
        mutating func addUsageReport(_ obj: [String: Any]) {
            guard usage.extras.usageReports.count < ClaudeUsageCacheStore.maxEventsPerKind,
                  let report = obj["usageReport"] as? [String: Any],
                  let uuid = ClaudeJSONLScanner.label(obj["uuid"]),
                  let tsMs = ClaudeJSONLScanner.timestampMs(obj["timestamp"]),
                  !usageReportIDs.contains(uuid) else { return }
            usageReportIDs.insert(uuid)
            let rateLimits = report["rate_limits"] as? [String: Any]
            let list = rateLimits?["limits"] as? [Any]
            let extra = rateLimits?["extra_usage"] as? [String: Any]
            var limits: [UsageReportLimit] = []
            for (index, item) in (list ?? []).prefix(ClaudeUsageCacheStore.maxReportLimits).enumerated() {
                guard let limit = item as? [String: Any], let kind = ClaudeJSONLScanner.label(limit["kind"]) else { continue }
                let scope = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
                limits.append(UsageReportLimit(
                    index: index, kind: kind,
                    group: ClaudeJSONLScanner.label(limit["group"]),
                    percent: ClaudeJSONLScanner.finite(limit["percent"]),
                    severity: ClaudeJSONLScanner.label(limit["severity"]),
                    isActive: ClaudeJSONLScanner.boolean(limit["is_active"]),
                    resetsAtMs: ClaudeJSONLScanner.timestampMs(limit["resets_at"]),
                    scopeModel: ClaudeJSONLScanner.label(scope?["display_name"])))
            }
            usage.extras.usageReports.append(UsageReportObservation(
                uuid: uuid, tsMs: tsMs, ccVersion: ClaudeJSONLScanner.label(obj["version"]),
                hasLimits: list != nil,
                extraEnabled: ClaudeJSONLScanner.boolean(extra?["is_enabled"]),
                extraMonthlyLimit: ClaudeJSONLScanner.integer(extra?["monthly_limit"]).map { Int($0) },
                extraUsedCredits: ClaudeJSONLScanner.integer(extra?["used_credits"]).map { Int($0) },
                limits: limits))
        }

        /// A `cost-state` record: Claude Code's cumulative per-session totals,
        /// with no timestamp of its own — `afterTsMs` is the latest usage
        /// record before it in the file.
        mutating func addCostState(_ obj: [String: Any]) {
            guard usage.extras.costStates.count < ClaudeUsageCacheStore.maxEventsPerKind,
                  obj["type"] as? String == "cost-state",
                  let sessionID = ClaudeJSONLScanner.label(obj["sessionId"]),
                  let start = ClaudeJSONLScanner.integer(obj["startTime"]),
                  let total = ClaudeJSONLScanner.integer(obj["totalDuration"]),
                  let cost = ClaudeJSONLScanner.finite(obj["totalCostUSD"]),
                  costStateIDs.insert(CostStateID(startTimeMs: start, totalDurationMs: total)).inserted else { return }
            var models: [CostStateModel] = []
            if let usageByModel = obj["modelUsage"] as? [String: Any] {
                for (key, value) in usageByModel.sorted(by: { $0.key < $1.key }) {
                    guard models.count < ClaudeUsageCacheStore.maxCostStateModels else { break }
                    guard let modelKey = ClaudeJSONLScanner.label(key), let fields = value as? [String: Any] else { continue }
                    func count(_ name: String) -> Int { ClaudeJSONLScanner.integer(fields[name]).map { Int($0) } ?? 0 }
                    models.append(CostStateModel(
                        modelKey: modelKey, input: count("inputTokens"), output: count("outputTokens"),
                        cacheRead: count("cacheReadInputTokens"), cacheCreation: count("cacheCreationInputTokens"),
                        thinking: count("thinkingTokens"), webSearch: count("webSearchRequests"),
                        costUSD: ClaudeJSONLScanner.finite(fields["costUSD"]) ?? 0))
                }
            }
            let after = usage.usageHighWaterMs
            usage.extras.costStates.append(CostStateObservation(
                sessionID: sessionID, startTimeMs: start, totalDurationMs: total,
                totalAPIDurationMs: ClaudeJSONLScanner.integer(obj["totalAPIDuration"]),
                totalCostUSD: cost,
                hasUnknownModelCost: ClaudeJSONLScanner.boolean(obj["hasUnknownModelCost"]) ?? false,
                afterTsMs: after == RecordStamp.noTime ? nil : after,
                models: models))
        }

        /// A `system/compact_boundary` record; replayed copies (same uuid) count once.
        mutating func addCompactEvent(_ obj: [String: Any]) {
            guard usage.extras.compactEvents.count < ClaudeUsageCacheStore.maxEventsPerKind,
                  obj["subtype"] as? String == "compact_boundary",
                  let uuid = ClaudeJSONLScanner.label(obj["uuid"]),
                  let tsMs = ClaudeJSONLScanner.timestampMs(obj["timestamp"]),
                  compactEventIDs.insert(uuid).inserted else { return }
            let meta = obj["compactMetadata"] as? [String: Any]
            usage.extras.compactEvents.append(CompactEventObservation(
                uuid: uuid, tsMs: tsMs, trigger: ClaudeJSONLScanner.label(meta?["trigger"]),
                preTokens: ClaudeJSONLScanner.integer(meta?["preTokens"]).map { Int($0) },
                postTokens: ClaudeJSONLScanner.integer(meta?["postTokens"]).map { Int($0) }))
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

    /// Every non-message record starts with its `type` (in every real
    /// transcript checked), so a cost state is found by an O(1) prefix check
    /// instead of a search of every line.
    private static let costStatePrefix = JSONLLineReader.Marker(#"{"type":"cost-state""#)
    /// User, assistant, attachment and system records start this way.
    private static let parentUUIDPrefix = JSONLLineReader.Marker(#"{"parentUuid""#)
    private static let compactBoundaryMarker = JSONLLineReader.Marker(#""subtype":"compact_boundary""#)
    /// How far into a system record its `subtype` is looked for: after
    /// `parentUuid`, `logicalParentUuid`, `isSidechain` and `type`, about
    /// 170 bytes in. Searching whole lines would cost seconds per cold scan.
    static let compactBoundarySearchLength = 320
    /// Whether the global scan reads `system/compact_boundary` records.
    static let collectsCompactEvents = true

    static func consume(
        line: JSONLLineReader.LogLine,
        into state: inout ParseState,
        calendar cal: Calendar
    ) {
        if line.contains(usageMarker) {
            guard let obj = line.jsonObject() else { return }
            consume(object: obj, into: &state, calendar: cal)
        } else {
            consumeExtrasLine(line, into: &state)
        }
    }

    /// A parsed record without `message.usage`, on the global scan.
    private static func consumeExtrasObject(_ obj: [String: Any], into state: inout ParseState) {
        if obj["usageReport"] != nil {
            state.addUsageReport(obj)
        } else if let type = obj["type"] as? String {
            if type == "cost-state" {
                state.addCostState(obj)
            } else if type == "system", state.collectsCompactEvents, obj["subtype"] as? String == "compact_boundary" {
                state.addCompactEvent(obj)
            }
        }
    }

    /// A line without the usage marker, on the global scan: a cost state, or
    /// a compaction. Anything else costs a prefix compare.
    static func consumeExtrasLine(_ line: JSONLLineReader.LogLine, into state: inout ParseState) {
        if line.hasPrefix(costStatePrefix) {
            if let obj = line.jsonObject() { state.addCostState(obj) }
        } else if state.collectsCompactEvents, line.hasPrefix(parentUUIDPrefix),
                  line.contains(compactBoundaryMarker, withinFirst: compactBoundarySearchLength),
                  let obj = line.jsonObject() {
            state.addCompactEvent(obj)
        }
    }

    /// Most iterations one record is split into; a longer `iterations` list
    /// is read as the top level alone. Two is all Claude Code has written.
    static let maxIterations = 32

    /// Folds one transcript record into `state`. Returns whether it counted:
    /// a usage record that is the first of its key, outranks the one held,
    /// or has no message id to dedup on. The only reader of usage records:
    /// the usage report, the history and the session rows all take their
    /// records from a parse through here (session rows through the scan's
    /// cache, `fileUsages`), so they count the same way.
    @discardableResult
    static func consume(
        object obj: [String: Any],
        into state: inout ParseState,
        calendar cal: Calendar
    ) -> Bool {
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            // A `/usage` report, a cost state or a compaction carries no
            // `message.usage`: read exactly those records here — a usage
            // record never pays for the lookups. A `/usage` record passes
            // the line gate only through `commandRun.command == "usage"`.
            consumeExtrasObject(obj, into: &state)
            return false
        }

        let model = (message["model"] as? String) ?? "default"
        // One timestamp parse per record: it is needed for the day anyway.
        let date: Date? = (obj["timestamp"] as? String).flatMap(CodexRolloutReader.parseISO)
        let ms = date.flatMap(epochMs)
        if let ms { state.noteUsageTime(ms) }
        if model == "<synthetic>" {
            // A 429's window and reset time; the record itself never counts.
            state.addLimitEvent(obj, tsMs: ms)
            return false
        }

        let mid = (message["id"] as? String) ?? ""
        let rid = (obj["requestId"] as? String) ?? ""

        let counts = tokenCounts(in: usage)
        // Judged on the top level only: a zeroed replay keeps the original's
        // `cache_creation` split and `iterations`, and must not count them.
        let cacheCreation = tokenCount(usage["cache_creation_input_tokens"])
            ?? (counts.cacheWrite5m + counts.cacheWrite1h)
        let finality: UsageFinality
        if counts.input == 0, counts.output == 0, counts.cacheRead == 0, cacheCreation == 0 {
            finality = .zeroed
        } else if message["stop_reason"] is String {
            finality = .final
        } else {
            finality = .partial
        }

        // A record without a timestamp is filed under today (the fallback the
        // scan always had; none in the corpus); its stamp states no time.
        let day = cal.startOfDay(for: date ?? Date())
        var entry = DayModelUsage(day: day, model: model, counts: finality == .zeroed ? TokenCounts() : counts)
        var earlier: [DayModelUsage] = []
        // A request that fell back to another model reports each attempt in
        // `iterations`, each under its own model; the top level repeats only
        // the last. Read per iteration, never on top of the top level. The
        // length is checked before the typed cast, which would otherwise
        // bridge the one-element list nearly every record carries.
        if finality != .zeroed,
           let list = usage["iterations"] as? NSArray,
           list.count > 1, list.count <= maxIterations,
           let iterations = list as? [[String: Any]] {
            let parts = iterations.map { iteration in
                DayModelUsage(day: day, model: (iteration["model"] as? String) ?? model,
                              counts: tokenCounts(in: iteration))
            }
            entry = parts[parts.count - 1]
            earlier = Array(parts.dropLast())
        }

        guard !mid.isEmpty else {
            // No message id to dedup on; fold it into the per-(day, model)
            // bucket — unless it is a zeroed replay, which adds nothing.
            guard finality != .zeroed else { return false }
            for part in earlier { state.add(unkeyed: part) }
            state.add(unkeyed: entry)
            return true
        }
        let key = DedupKey(messageID: mid, requestID: rid)
        var record = KeyedUsage(key: key, usage: entry, earlierIterations: earlier, finality: finality)
        record.stamp = .of(ms: ms, finality: finality, flags: recordFlags(obj, usage: usage))
        let (outcome, index) = state.insert(record)
        guard outcome != .kept else { return false }
        // Labels only for a record that stands (about a third of them).
        let attributes = RecordAttributes(
            version: label(obj["version"]), effort: label(obj["effort"]), entrypoint: label(obj["entrypoint"]))
        // A zeroed replay contributes nothing, its thinking count included.
        state.setAttributes(attributes, thinking: finality == .zeroed ? RecordStamp.noThinking : thinkingTokens(usage),
                            at: index)
        if outcome == .newKey, let ms {
            state.noteFirstRecord(ms, cwd: obj["cwd"], attributes: attributes)
        }
        return true
    }

    // MARK: - Values read for the history

    /// Unix ms of a parsed timestamp, nil unless finite and within ±10^15 ms
    /// (so a stamp's arithmetic cannot overflow).
    static func epochMs(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 1e12 else { return nil }
        return HistoryTime.ms(date)
    }

    static func timestampMs(_ value: Any?) -> Int64? {
        (value as? String).flatMap(CodexRolloutReader.parseISO).flatMap(epochMs)
    }

    /// An epoch in seconds (`quotaLimits.resetsAt`) as ms, nil when out of range.
    static func msFromSeconds(_ seconds: Int64) -> Int64? {
        abs(seconds) < 1_000_000_000_000 ? seconds * 1000 : nil
    }

    /// 1–64 printable ASCII bytes, else nil: version, effort, entrypoint,
    /// window and limit kinds, ids. A native copy, so the record's bridged
    /// string is not kept alive.
    static func label(_ value: Any?) -> String? {
        guard var s = value as? String else { return nil }
        var count = 0
        for byte in s.utf8 {
            count += 1
            guard count <= 64, byte >= 0x20, byte <= 0x7E else { return nil }
        }
        guard count > 0 else { return nil }
        s.makeContiguousUTF8()
        return s
    }

    /// A working directory: 1–4,096 UTF-8 bytes, else nil. The history store
    /// holds the session's first cwd to the same constant.
    static func cwd(_ value: Any?) -> String? {
        guard var s = value as? String else { return nil }
        let count = s.utf8.count
        guard count > 0, count <= HistoryEventCheck.maxCwdBytes else { return nil }
        s.makeContiguousUTF8()
        return s
    }

    /// A JSON integer (not a boolean, not a fraction), except `Int64.min`,
    /// which the cache uses for "none".
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        guard let v = value as? Int64, v != Int64.min else { return nil }
        return v
    }

    /// A JSON boolean; a number is not one.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    /// A finite JSON number that is not a boolean.
    static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let v = number.doubleValue
        return v.isFinite ? v : nil
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `usage.output_tokens_details.thinking_tokens`, or `RecordStamp.noThinking`.
    private static func thinkingTokens(_ usage: [String: Any]) -> UInt32 {
        guard let details = usage["output_tokens_details"] as? [String: Any],
              let tokens = integer(details["thinking_tokens"]),
              tokens >= 0, tokens < Int64(RecordStamp.noThinking) else { return RecordStamp.noThinking }
        return UInt32(tokens)
    }

    /// The flags this one record carries; `RecordStamp.absorb` ORs them over the key.
    private static func recordFlags(_ obj: [String: Any], usage: [String: Any]) -> RequestFlags {
        var flags: RequestFlags = []
        if let speed = usage["speed"] as? String, speed == "fast" { flags.insert(.fast) }
        if boolean(obj["isAbortedMidStream"]) == true { flags.insert(.abortedMidStream) }
        return flags
    }

    /// The five counts of one usage block — a record's top level or one of
    /// its `iterations`.
    private static func tokenCounts(in usage: [String: Any]) -> TokenCounts {
        var counts = TokenCounts()
        counts.input = tokenCount(usage["input_tokens"]) ?? 0
        counts.output = tokenCount(usage["output_tokens"]) ?? 0
        counts.cacheRead = tokenCount(usage["cache_read_input_tokens"]) ?? 0
        if let cc = usage["cache_creation"] as? [String: Any] {
            counts.cacheWrite5m = tokenCount(cc["ephemeral_5m_input_tokens"]) ?? 0
            counts.cacheWrite1h = tokenCount(cc["ephemeral_1h_input_tokens"]) ?? 0
        } else {
            counts.cacheWrite5m = tokenCount(usage["cache_creation_input_tokens"]) ?? 0
        }
        return counts
    }

    /// A token count in 0...`HistoryObservationCheck.maxCount`, else nil, as
    /// if the field were absent. The history store refuses an observation
    /// with a count outside that range; a count the usage cache kept and the
    /// store refused would leave a cold scan and an incremental one with
    /// different rows. A JSON boolean still reads as 0 or 1, as the plain
    /// `as? Int` always did; scanner and store see the same value.
    static func tokenCount(_ value: Any?) -> Int? {
        guard let v = value as? Int, v >= 0, v <= HistoryObservationCheck.maxCount else { return nil }
        return v
    }
}
