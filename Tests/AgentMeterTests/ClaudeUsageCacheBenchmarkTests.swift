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

    private func measure(
        _ label: String, cache: ClaudeUsageCache, files: [URL], completeHistory: Bool = true
    ) async -> (UsageReport, Measurement) {
        await cache.stats.reset()
        let rssBefore = residentSize()
        let cpuBefore = Double(clock()) / Double(CLOCKS_PER_SEC)
        let wallBefore = Date()
        let report = await ClaudeJSONLScanner.usageReport(files: files, completeHistory: completeHistory, cache: cache)
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

        let cold = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let (coldReport, coldRun) = await measure("cold (parse + persist)", cache: cold, files: stable)
        let warm = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let (warmReport, warmRun) = await measure("warm restart (store)", cache: warm, files: stable)
        let (hotReport, hotRun) = await measure("warm same process (memory)", cache: warm, files: stable)
        let recent = stable.filter { url in
            guard let fp = before[url.path] else { return false }
            return Date(timeIntervalSince1970: fp.modifiedAt) >= Date().addingTimeInterval(-31 * 86_400)
        }
        let (_, windowedRun) = await measure(
            "windowed (31-day files) after restart",
            cache: ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir)),
            files: recent, completeHistory: false)

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
        [bench] cache: \(size.files) entries, \(String(format: "%.2f", Double(size.bytes) / 1e6)) MB \
        (\(String(format: "%.2f", Double(size.bytes) * 100 / Double(logBytes)))% of the logs)
        """)
    }
}
