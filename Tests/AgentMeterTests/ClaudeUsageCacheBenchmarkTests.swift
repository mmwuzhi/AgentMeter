import Foundation
@testable import AgentMeter
import XCTest

/// Cold versus warm scans through the persistent cache. The synthetic case
/// always runs and asserts only facts (equal reports, no log file opened on
/// a warm start); the timings it prints are for the record. The real-corpus
/// case reads `~/.claude/projects` — read-only, with its cache in a temporary
/// directory — and runs only with `AGENTMETER_REAL_CORPUS_BENCH=1`, because
/// one cold pass over a multi-GB corpus is 30 s of CPU.
final class ClaudeUsageCacheBenchmarkTests: XCTestCase {
    private struct Measurement {
        let label: String
        let wall: TimeInterval
        let cpu: TimeInterval
        let residentDelta: Int64
        let stats: ClaudeScanStats.Snapshot

        var line: String {
            String(format: "%@: wall %.3fs  cpu %.3fs  rss %+.1f MB  opened %d  full %d  resumed %d  memoryHits %d  storeHits %d  committed %.1f MB",
                   label, wall, cpu, Double(residentDelta) / 1e6, stats.filesOpened, stats.fullParses,
                   stats.resumedParses, stats.memoryHits, stats.storeHits, Double(stats.bytesCommitted) / 1e6)
        }
    }

    /// Counts what a scan hands the history and keeps nothing, so a
    /// measurement includes building the batches but no store.
    private final class CountingHistorySink: HistoryIngesting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var scans = 0
        private(set) var files = 0
        private(set) var deltas = 0
        private(set) var deltaRequests = 0

        func submit(scan: HistoryScanBatch) {
            lock.lock()
            defer { lock.unlock() }
            scans += 1
            files += scan.files.count
            for file in scan.files {
                if let delta = file.delta {
                    deltas += 1
                    deltaRequests += delta.requests.count
                }
            }
        }

        func submit(quota: [QuotaSampleRow]) {}
        func submit(legacyQuota: [QuotaSampleRow]) {}
        func submit(resetGrants: [ResetGrantObservation], recordedMs: Int64) {}

        var summary: String {
            lock.lock()
            defer { lock.unlock() }
            return "history: \(scans) scans, \(files) file batches, \(deltas) deltas (\(deltaRequests) requests)"
        }
    }

    /// Heap bytes in use over every malloc zone: deterministic, unlike RSS.
    private func heapInUse() -> Int64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int64(stats.size_in_use)
    }

    private func measure(
        _ label: String, cache: ClaudeUsageCache, files: [URL], completeHistory: Bool = true,
        history: (any HistoryIngesting)? = nil
    ) async -> (UsageReport, Measurement) {
        await cache.stats.reset()
        let rssBefore = residentSize()
        let cpuBefore = Double(clock()) / Double(CLOCKS_PER_SEC)
        let wallBefore = Date()
        let report = await ClaudeJSONLScanner.usageReport(files: files, completeHistory: completeHistory, cache: cache,
                                                          history: history)
        let wall = Date().timeIntervalSince(wallBefore)
        let cpu = Double(clock()) / Double(CLOCKS_PER_SEC) - cpuBefore
        let stats = await cache.stats.snapshot()
        return (report, Measurement(label: label, wall: wall, cpu: cpu,
                                    residentDelta: residentSize() - rssBefore, stats: stats))
    }

    private func residentSize() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    private func directorySize(_ dir: URL) -> (files: Int, bytes: Int64) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let bytes = names.reduce(Int64(0)) { sum, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? NSNumber
            return sum + (size?.int64Value ?? 0)
        }
        return (names.count, bytes)
    }

    /// Equal per-(day, model) counts, reported as the entries that differ
    /// rather than two arrays of hundreds of records.
    private func assertSameCounts(_ a: UsageReport, _ b: UsageReport, _ label: String) {
        func keyed(_ r: UsageReport) -> [String: TokenCounts] {
            Dictionary(uniqueKeysWithValues: r.dayModels.map { ("\(Self.day($0.day)) \($0.model)", $0.counts) })
        }
        let (x, y) = (keyed(a), keyed(b))
        var lines: [String] = []
        for key in Set(x.keys).union(y.keys).sorted() where x[key] != y[key] {
            lines.append("  \(key): \(x[key].map { "\($0.total)" } ?? "-") -> \(y[key].map { "\($0.total)" } ?? "-")")
        }
        if !lines.isEmpty {
            XCTFail("\(label): \(lines.count) (day, model) entries differ\n" + lines.prefix(30).joined(separator: "\n"))
        }
        XCTAssertEqual(a.totalTokens, b.totalTokens, "\(label): 30-day tokens")
        XCTAssertEqual(a.buckets.count, b.buckets.count, "\(label): day buckets")
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Synthetic corpus

    /// Transcript-shaped lines: most records carry no usage and are large
    /// (tool results), about one in three is an assistant message with usage,
    /// and a few replay another file's messages.
    private func writeSyntheticCorpus(files: Int, bytesPerFile: Int) throws -> (root: URL, logs: [URL]) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-usage-bench-\(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        let models = ["claude-sonnet-4-5-20250929", "claude-opus-4-1-20250805", "claude-3-5-haiku-20241022"]
        let filler = String(repeating: "x", count: 1_800)
        var urls: [URL] = []
        var generator = SystemRandomNumberGenerator()
        for f in 0..<files {
            var body = ""
            body.reserveCapacity(bytesPerFile + 4_096)
            var n = 0
            let fileStart = Date().addingTimeInterval(-Double(f % 45) * 86_400)
            while body.utf8.count < bytesPerFile {
                let ts = iso.string(from: fileStart.addingTimeInterval(Double(n) * 7))
                if n % 3 == 0 {
                    let model = models[n % models.count]
                    // A tenth of the messages replay the previous file's.
                    let owner = (f > 0 && n % 10 == 0) ? f - 1 : f
                    let mid = "msg_\(owner)_\(n)"
                    body += #"{"timestamp":"\#(ts)","type":"assistant","requestId":"req_\#(owner)_\#(n)","message":{"id":"\#(mid)","model":"\#(model)","usage":{"input_tokens":\#(Int.random(in: 1...3_000, using: &generator)),"output_tokens":\#(Int.random(in: 1...2_000, using: &generator)),"cache_read_input_tokens":\#(Int.random(in: 0...120_000, using: &generator)),"cache_creation":{"ephemeral_5m_input_tokens":\#(Int.random(in: 0...5_000, using: &generator)),"ephemeral_1h_input_tokens":\#(Int.random(in: 0...20_000, using: &generator))}}}}"# + "\n"
                } else {
                    body += #"{"timestamp":"\#(ts)","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"\#(filler)"}]}}"# + "\n"
                }
                n += 1
            }
            let url = logs.appendingPathComponent(String(format: "session-%03d.jsonl", f))
            try body.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        return (root, urls)
    }

    func testSyntheticCorpusWarmStartOpensNoFile() async throws {
        let corpus = try writeSyntheticCorpus(files: 50, bytesPerFile: 2_000_000)
        defer { try? FileManager.default.removeItem(at: corpus.root) }
        let cacheDir = corpus.root.appendingPathComponent("cache", isDirectory: true)
        let logBytes = corpus.logs.reduce(Int64(0)) { $0 + (LogFileFingerprint.current(for: $1)?.size ?? 0) }

        let (reference, fresh) = await measure("fresh (no cache)", cache: ClaudeUsageCache(store: nil), files: corpus.logs)
        let cold = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let (coldReport, coldRun) = await measure("cold (parse + persist)", cache: cold, files: corpus.logs)
        let warm = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let (warmReport, warmRun) = await measure("warm restart (store)", cache: warm, files: corpus.logs)
        let (hotReport, hotRun) = await measure("warm same process (memory)", cache: warm, files: corpus.logs)
        let (windowedReport, windowedRun) = await measure(
            "windowed, 10 files, after restart", cache: ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir)),
            files: Array(corpus.logs.prefix(10)), completeHistory: false)
        let windowedReference = await ClaudeJSONLScanner.usageReport(
            files: Array(corpus.logs.prefix(10)), cache: ClaudeUsageCache(store: nil))

        assertSameCounts(reference, coldReport, "cold")
        assertSameCounts(reference, warmReport, "warm restart")
        assertSameCounts(reference, hotReport, "warm memory")
        assertSameCounts(windowedReference, windowedReport, "windowed")
        XCTAssertEqual(warmRun.stats.filesOpened, 0)
        XCTAssertEqual(hotRun.stats.filesOpened, 0)
        XCTAssertEqual(windowedRun.stats.filesOpened, 0)

        let size = directorySize(cacheDir)
        print("""
        [bench] synthetic corpus: \(corpus.logs.count) files, \(String(format: "%.1f", Double(logBytes) / 1e6)) MB of logs, \
        \(reference.dayModels.reduce(0) { $0 + $1.counts.total }) tokens over \(reference.buckets.count) days
        [bench] \(fresh.line)
        [bench] \(coldRun.line)
        [bench] \(warmRun.line)
        [bench] \(hotRun.line)
        [bench] \(windowedRun.line)
        [bench] cache: \(size.files) entries, \(String(format: "%.2f", Double(size.bytes) / 1e6)) MB \
        (\(String(format: "%.2f", Double(size.bytes) * 100 / Double(logBytes)))% of the logs)
        """)
    }

    // MARK: - Real corpus (opt-in)

    func testRealCorpusColdVersusWarm() async throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_REAL_CORPUS_BENCH"] == "1" else {
            throw XCTSkip("set AGENTMETER_REAL_CORPUS_BENCH=1 to scan the real ~/.claude corpus (read-only, cache in a temp dir)")
        }
        let all = ClaudeJSONLScanner.jsonlFiles()
        guard !all.isEmpty else { throw XCTSkip("no Claude logs on this machine") }
        // Live sessions append to their transcripts between one scan and the
        // next, so cold and warm can only be compared over files nobody has
        // written for a while; the fingerprints are checked again afterwards.
        let quietSince = Date().addingTimeInterval(-3_600)
        let before = Dictionary(uniqueKeysWithValues: all.compactMap { url in
            LogFileFingerprint.current(for: url).map { (url.path, $0) }
        })
        let stable = all.filter { url in
            guard let fp = before[url.path] else { return false }
            return Date(timeIntervalSince1970: fp.modifiedAt) < quietSince
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-usage-real-bench-\(UUID().uuidString)")
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logBytes = stable.reduce(Int64(0)) { $0 + (before[$1.path]?.size ?? 0) }

        let sink = CountingHistorySink()
        func mb(_ bytes: Int64) -> String { String(format: "%+.2f MB", Double(bytes) / 1e6) }

        // Heap retained by the cache after each kind of scan: measured with
        // only that cache alive (the report and its counts are small).
        let heapAtStart = heapInUse()
        var cold: ClaudeUsageCache? = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let (coldReport, coldRun) = await measure("cold (parse + persist)", cache: cold!, files: stable, history: sink)
        let coldHeap = heapInUse() - heapAtStart
        cold = nil
        let heapBeforeWarm = heapInUse()
        let warm = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let (warmReport, warmRun) = await measure("warm restart (store)", cache: warm, files: stable, history: sink)
        let warmHeap = heapInUse() - heapBeforeWarm
        let (hotReport, hotRun) = await measure("warm same process (memory)", cache: warm, files: stable, history: sink)
        let recent = stable.filter { url in
            guard let fp = before[url.path] else { return false }
            return Date(timeIntervalSince1970: fp.modifiedAt) >= Date().addingTimeInterval(-31 * 86_400)
        }
        let windowedCache = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let (_, windowedRun) = await measure(
            "windowed (31-day files) after restart", cache: windowedCache,
            files: recent, completeHistory: false, history: sink)

        // The per-minute scan while a transcript grows: the windowed set plus
        // one synthetic active file of ~7k records (the largest real file's
        // count), grown by 200 records, in the same process and after a restart.
        let active = root.appendingPathComponent("active-7k.jsonl")
        try writeActiveFile(records: 7_000, to: active)
        let growing = recent + [active]
        _ = await measure("windowed + active file (first parse)", cache: windowedCache, files: growing,
                          completeHistory: false, history: sink)
        let snapshotDir = root.appendingPathComponent("cache-snapshot", isDirectory: true)
        try FileManager.default.copyItem(at: cacheDir, to: snapshotDir)
        try appendActiveRecords(200, from: 7_000, to: active)
        let (_, growHot) = await measure("windowed + 200 records on the 7k file, same process", cache: windowedCache,
                                         files: growing, completeHistory: false, history: sink)
        let (_, growRestart) = await measure(
            "windowed + 200 records on the 7k file, after restart",
            cache: ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: snapshotDir)),
            files: growing, completeHistory: false, history: sink)
        XCTAssertEqual(growHot.stats.resumedParses, 1)
        XCTAssertEqual(growRestart.stats.resumedParses, 1)

        let changed = stable.filter { LogFileFingerprint.current(for: $0) != before[$0.path] }
        XCTAssertTrue(changed.isEmpty, "quiet files changed during the benchmark: \(changed.map(\.lastPathComponent))")
        assertSameCounts(coldReport, warmReport, "real corpus, warm restart")
        assertSameCounts(coldReport, hotReport, "real corpus, warm memory")
        XCTAssertEqual(warmRun.stats.filesOpened, 0)
        XCTAssertEqual(hotRun.stats.filesOpened, 0)

        let size = directorySize(cacheDir)
        print("""
        [bench] real corpus: \(all.count) files, \(stable.count) quiet for an hour (\(String(format: "%.2f", Double(logBytes) / 1e9)) GB), \
        \(coldReport.dayModels.reduce(0) { $0 + $1.counts.total }) tokens over \(coldReport.buckets.count) days, \(coldReport.dayModels.count) (day, model) pairs
        [bench] \(coldRun.line)
        [bench] \(warmRun.line)
        [bench] \(hotRun.line)
        [bench] \(windowedRun.line) over \(recent.count) files
        [bench] \(growHot.line)
        [bench] \(growRestart.line)
        [bench] heap retained (malloc bytes in use): cold \(mb(coldHeap)), warm restart \(mb(warmHeap))
        [bench] \(sink.summary)
        [bench] cache: \(size.files) entries, \(String(format: "%.2f", Double(size.bytes) / 1e6)) MB \
        (\(String(format: "%.2f", Double(size.bytes) * 100 / Double(logBytes)))% of the logs)
        """)
    }

    // MARK: - A growing transcript

    /// One usage record and two large non-usage records per request, like a
    /// main transcript; keys `msg_active_<n>`.
    private func activeLines(_ range: Range<Int>, filler fillerLength: Int) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date().addingTimeInterval(-3_600)
        let filler = String(repeating: "x", count: fillerLength)
        var body = ""
        for n in range {
            let ts = iso.string(from: start.addingTimeInterval(Double(n) * 0.25))
            body += #"{"parentUuid":"p\#(n)","isSidechain":false,"userType":"external","cwd":"/tmp/active","sessionId":"active","version":"2.1.301","gitBranch":"main","message":{"model":"claude-opus-5-5","id":"msg_active_\#(n)","type":"message","role":"assistant","content":[{"type":"text","text":"x"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":40,"cache_read_input_tokens":90000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":40},"output_tokens":\#(n % 900 + 1),"service_tier":"standard","speed":"standard","iterations":[]}},"requestId":"req_active_\#(n)","type":"assistant","uuid":"u\#(n)","timestamp":"\#(ts)","entrypoint":"claude-vscode","effort":"high"}"# + "\n"
            body += #"{"parentUuid":"u\#(n)","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"\#(filler)"}]},"uuid":"t\#(n)","timestamp":"\#(ts)"}"# + "\n"
            body += #"{"type":"attachment","sessionId":"active","content":"\#(filler)"}"# + "\n"
        }
        return body
    }

    /// `filler`: bytes of each non-usage record; 1,500 is a main transcript's
    /// proportion (a 7k-record file is then ~38 MB), the synthetic test uses less.
    private func writeActiveFile(records: Int, to url: URL, filler: Int = 1_500) throws {
        try Data(activeLines(0..<records, filler: filler).utf8).write(to: url)
    }

    private func appendActiveRecords(_ count: Int, from start: Int, to url: URL, filler: Int = 1_500) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(activeLines(start..<start + count, filler: filler).utf8))
        try handle.close()
    }

    /// What a scan costs each minute while one transcript grows: a warm
    /// corpus, then 20 records appended to a small file and 200 to a large
    /// one, each scanned in the same process and after a restart, with a
    /// history attached (the delta is built). Asserts the facts — one file
    /// read, resumed, its new records in the delta, the report equal to a
    /// fresh parse — and prints the timings. The default run is a small
    /// corpus (2 background files, a 200- and a 1,000-record file);
    /// `AGENTMETER_HISTORY_PERF=1` times the benchmark size (6 background
    /// files of 500 KB, a 1k- and a 7k-record file).
    func testSyntheticIncrementalGrowth() async throws {
        let full = ProcessInfo.processInfo.environment["AGENTMETER_HISTORY_PERF"] == "1"
        // The background files are filler for this case (the real-corpus
        // benchmarks measure the full corpus); every scan here re-parses them
        // for the reference report, so their size is suite time.
        let corpus = try writeSyntheticCorpus(files: full ? 6 : 2, bytesPerFile: full ? 500_000 : 100_000)
        defer { try? FileManager.default.removeItem(at: corpus.root) }
        let sizes = full ? (small: 1_000, large: 7_000) : (small: 200, large: 1_000)
        let small = corpus.root.appendingPathComponent("logs/active-small.jsonl")
        let large = corpus.root.appendingPathComponent("logs/active-large.jsonl")
        try writeActiveFile(records: sizes.small, to: small, filler: 200)
        try writeActiveFile(records: sizes.large, to: large, filler: 200)
        let files = corpus.logs + [small, large]
        let cacheDir = corpus.root.appendingPathComponent("cache", isDirectory: true)
        let cache = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let sink = CountingHistorySink()
        _ = await measure("cold", cache: cache, files: files, history: sink)
        let (_, steady) = await measure("nothing changed, same process", cache: cache, files: files, history: sink)
        XCTAssertEqual(steady.stats.filesOpened, 0)

        var lines = [steady.line]
        var next = sizes
        for (name, url, count) in [("\(sizes.small)-record file + 20 records", small, 20),
                                   ("\(sizes.large)-record file + 200 records", large, 200)] {
            let snapshot = corpus.root.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: cacheDir, to: snapshot)
            let start = url == small ? next.small : next.large
            try appendActiveRecords(count, from: start, to: url, filler: 200)
            if url == small { next.small += count } else { next.large += count }
            let reference = await ClaudeJSONLScanner.usageReport(files: files, cache: ClaudeUsageCache(store: nil))
            for (when, scanCache) in [("same process", cache),
                                      ("after restart", ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: snapshot)))] {
                let recorder = RecordingHistorySink()
                let (report, run) = await measure("\(name), \(when)", cache: scanCache, files: files, history: recorder)
                assertSameCounts(reference, report, "\(name), \(when)")
                XCTAssertEqual(run.stats.filesOpened, 1, "\(name), \(when)")
                XCTAssertEqual(run.stats.resumedParses, 1, "\(name), \(when)")
                XCTAssertEqual(recorder.lastScan?.file(url)?.delta?.requests.count, count, "\(name), \(when): the delta")
                lines.append(run.line)
                if when == "same process" { continue }
                // Bring the restarted store back in line for the next step.
                _ = await ClaudeJSONLScanner.usageReport(files: files, cache: cache)
            }
        }
        print(lines.map { "[bench] incremental: " + $0 }.joined(separator: "\n"))
    }

    // MARK: - Cost of the compaction search (opt-in)

    /// What reading `system/compact_boundary` costs a cold scan of the real
    /// corpus: the same line pass twice — the usage gate, then the extras
    /// path for every line without usage — once with the compaction search
    /// and once without, alternating, min of 2 each. JSON parses of usage
    /// lines are left out of both, so the difference is the search and the
    /// compaction parses alone. Read-only.
    func testRealCorpusCompactEventCost() async throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_REAL_CORPUS_BENCH"] == "1" else {
            throw XCTSkip("set AGENTMETER_REAL_CORPUS_BENCH=1 to scan the real ~/.claude corpus (read-only)")
        }
        let files = ClaudeJSONLScanner.jsonlFiles()
        guard !files.isEmpty else { throw XCTSkip("no Claude logs on this machine") }
        let usageMarker = JSONLLineReader.Marker("\"usage\"")
        func pass(compact: Bool) -> (cpu: Double, events: Int, costStates: Int) {
            let cpuBefore = Double(clock()) / Double(CLOCKS_PER_SEC)
            var events = 0, costStates = 0
            for url in files {
                var state = ClaudeJSONLScanner.ParseState(resuming: nil, collectsExtras: true, collectsCompactEvents: compact)
                _ = try? JSONLLineReader.forEachCompleteLine(in: url, fromOffset: 0) { line in
                    if !line.contains(usageMarker) { ClaudeJSONLScanner.consumeExtrasLine(line, into: &state) }
                }
                events += state.usage.extras.compactEvents.count
                costStates += state.usage.extras.costStates.count
            }
            return (Double(clock()) / Double(CLOCKS_PER_SEC) - cpuBefore, events, costStates)
        }
        var off: [Double] = [], on: [Double] = []
        var counts = (events: 0, costStates: 0)
        for _ in 0..<2 {
            off.append(pass(compact: false).cpu)
            let result = pass(compact: true)
            on.append(result.cpu)
            counts = (result.events, result.costStates)
        }
        let cost = on.min()! - off.min()!
        print(String(format: "[bench] compaction search over %d files: cpu without %.3f / %.3f s, with %.3f / %.3f s, cost %+.3f s; %d compactions, %d cost states",
                     files.count, off[0], off[1], on[0], on[1], cost, counts.events, counts.costStates))
    }
}
