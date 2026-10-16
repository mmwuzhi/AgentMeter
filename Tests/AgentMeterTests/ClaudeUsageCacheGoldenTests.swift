import Foundation
@testable import AgentMeter
import XCTest

/// Golden tests for the persistent parse cache: every scenario parses one
/// controlled corpus twice — once from scratch through a cache that has
/// never seen the files (A), once through the persistent cache (B) — and the
/// two reports must agree on everything the UI and the ledger read. The
/// fixture lives in a temporary directory of its own; nothing here touches
/// `~/.claude` or Application Support.
final class ClaudeUsageCacheGoldenTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let logs: URL
        let cacheDir: URL
        var files: [URL] { Self.list(logs) }

        static func list(_ dir: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .map { $0.resolvingSymlinksInPath() }
                .sorted { $0.path < $1.path }
        }

        func file(_ name: String) -> URL { logs.appendingPathComponent(name) }
    }

    private var fixture: Fixture!

    override func setUpWithError() throws {
        let fm = FileManager.default
        // Resolved once (`/var` is a link to `/private/var`), so the paths the
        // scenarios build and the ones a directory listing returns agree —
        // the store names entries by path.
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-usage-golden-\(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        fixture = Fixture(root: root, logs: logs, cacheDir: cacheDir)
        try writeCorpus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    // MARK: - Corpus

    private static func iso() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    // Anchored to local calendar days (10:00 each) so the four days stay
    // four days whatever the time of day the suite runs at.
    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date()))!
        return start.addingTimeInterval(10 * 3_600)
    }
    private var d0: Date { day(0) }
    private var d1: Date { day(1) }
    private var d2: Date { day(2) }
    private var dOld: Date { day(40) }

    private func record(
        _ at: Date, mid: String?, rid: String?, model: String?,
        input: Int, output: Int, cacheRead: Int = 0, w5m: Int = 0, w1h: Int = 0,
        flatCacheCreation: Bool = false
    ) -> String {
        var usage: [String] = ["\"input_tokens\":\(input)", "\"output_tokens\":\(output)"]
        if cacheRead > 0 { usage.append("\"cache_read_input_tokens\":\(cacheRead)") }
        if flatCacheCreation {
            usage.append("\"cache_creation_input_tokens\":\(w5m)")
        } else if w5m > 0 || w1h > 0 {
            usage.append("\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(w5m),\"ephemeral_1h_input_tokens\":\(w1h)}")
        }
        var message: [String] = []
        if let mid { message.append("\"id\":\"\(mid)\"") }
        if let model { message.append("\"model\":\"\(model)\"") }
        message.append("\"usage\":{\(usage.joined(separator: ","))}")
        var top: [String] = ["\"timestamp\":\"\(Self.iso().string(from: at))\"", "\"type\":\"assistant\""]
        if let rid { top.append("\"requestId\":\"\(rid)\"") }
        top.append("\"message\":{\(message.joined(separator: ","))}")
        return "{\(top.joined(separator: ","))}"
    }

    private func write(_ lines: [String], to url: URL, terminated: Bool = true) throws {
        let body = lines.joined(separator: "\n") + (terminated ? "\n" : "")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ lines: [String], to url: URL, terminated: Bool = true) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + (terminated ? "\n" : "")).utf8))
        try handle.close()
    }

    /// Expected fresh totals: d2 = 412, d1 = 105, d0 = 24, dOld = 3000 (bucket only).
    private func writeCorpus() throws {
        let sonnet = "claude-sonnet-4-20250514", opus = "claude-opus-4-1-20250805", haiku = "claude-3-5-haiku-20241022"
        let a1 = record(d2, mid: "msg-a1", rid: "req-a1", model: sonnet, input: 10, output: 20, cacheRead: 5, w5m: 7, w1h: 11)
        let a2 = record(d2, mid: "msg-a2", rid: "req-a2", model: opus, input: 100, output: 200, cacheRead: 50, w5m: 9, flatCacheCreation: true)
        try write([
            a1,
            a2,
            record(d1, mid: "msg-a3", rid: "req-a3", model: sonnet, input: 1, output: 2),
            // A repeat of a1 inside the same file: the first occurrence wins.
            record(d2, mid: "msg-a1", rid: "req-a1", model: sonnet, input: 999, output: 999),
            record(d1, mid: "msg-syn", rid: "req-syn", model: "<synthetic>", input: 5000, output: 5000),
            // No message id: cannot be deduplicated, so every copy counts.
            record(d1, mid: nil, rid: nil, model: sonnet, input: 3, output: 4),
            record(d1, mid: nil, rid: nil, model: sonnet, input: 3, output: 4),
            #"{"type":"user","timestamp":"\#(Self.iso().string(from: d1))","message":{"role":"user","content":"hello"}}"#,
            "{not json at all",
            record(d1, mid: "msg-a9", rid: "req-a9", model: nil, input: 5, output: 5)
        ], to: fixture.file("a-main.jsonl"))

        try write([
            // A resumed session replays the earlier transcript: both are in a-main already.
            a1,
            a2,
            record(d1, mid: "msg-b3", rid: "req-b3", model: opus, input: 30, output: 40, w1h: 3),
            record(dOld, mid: "msg-b4", rid: "req-b4", model: haiku, input: 1000, output: 2000),
            // Same message id as a3 under a different request id: a distinct key.
            record(d1, mid: "msg-a3", rid: "req-b5", model: sonnet, input: 2, output: 3)
        ], to: fixture.file("b-resumed.jsonl"))

        try write([
            record(d0, mid: "msg-c1", rid: "req-c1", model: haiku, input: 7, output: 8, cacheRead: 9)
        ], to: fixture.file("c-other.jsonl"))

        try write([], to: fixture.file("d-empty.jsonl"), terminated: false)

        try write([
            #"{"type":"user","message":{"role":"user","content":"no usage here"}}"#,
            #"{"type":"progress","data":{"usage":"the marker but no message block"}}"#,
            #"{"type":"summary","summary":"x"}"#
        ], to: fixture.file("e-noise.jsonl"))
    }

    // MARK: - Harness

    /// A: a cache that has never seen the files and persists nothing.
    private func freshReport(_ files: [URL]? = nil, completeHistory: Bool = true) async -> UsageReport {
        await ClaudeJSONLScanner.usageReport(
            files: files ?? fixture.files, completeHistory: completeHistory,
            cache: ClaudeUsageCache(store: nil))
    }

    private func persistentCache(tag: String? = nil, at directory: URL? = nil) -> ClaudeUsageCache {
        let dir = directory ?? fixture.cacheDir
        let store = tag.map { ClaudeUsageCacheStore(directory: dir, calendarTag: $0) }
            ?? ClaudeUsageCacheStore(directory: dir)
        return ClaudeUsageCache(store: store)
    }

    /// A copy of the cache directory as it stands: what a relaunch after
    /// the scenario's change would find, before the same-process rescan
    /// writes the new state back.
    private func snapshotCacheDir() throws -> URL {
        let copy = fixture.root.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.cacheDir, to: copy)
        return copy
    }

    /// The same change seen by the cache that made the first parse and by a
    /// fresh process over a snapshot of its directory.
    private func sameProcessAndRestart(_ cache: ClaudeUsageCache) throws -> [(String, ClaudeUsageCache)] {
        [("same process", cache), ("after restart", persistentCache(at: try snapshotCacheDir()))]
    }

    /// B: through `cache`, which may hold memory entries and a store on disk.
    private func cachedReport(
        _ cache: ClaudeUsageCache, _ files: [URL]? = nil, completeHistory: Bool = true
    ) async -> UsageReport {
        await ClaudeJSONLScanner.usageReport(
            files: files ?? fixture.files, completeHistory: completeHistory, cache: cache)
    }

    private func assertEquivalent(
        _ fresh: UsageReport, _ cached: UsageReport,
        _ scenario: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        XCTAssertEqual(cached.dayModels, fresh.dayModels, "\(scenario): per-(day, model) counts", file: file, line: line)
        XCTAssertEqual(cached.buckets.map(\.day), fresh.buckets.map(\.day), "\(scenario): bucket days", file: file, line: line)
        for (a, b) in zip(fresh.buckets, cached.buckets) {
            XCTAssertEqual(b.inputTokens, a.inputTokens, "\(scenario): input on \(a.day)", file: file, line: line)
            XCTAssertEqual(b.outputTokens, a.outputTokens, "\(scenario): output on \(a.day)", file: file, line: line)
            XCTAssertEqual(b.cacheRead, a.cacheRead, "\(scenario): cache read on \(a.day)", file: file, line: line)
            XCTAssertEqual(b.cacheWrite5m, a.cacheWrite5m, "\(scenario): 5m cache write on \(a.day)", file: file, line: line)
            XCTAssertEqual(b.cacheWrite1h, a.cacheWrite1h, "\(scenario): 1h cache write on \(a.day)", file: file, line: line)
            XCTAssertEqual(b.costUSD, a.costUSD, accuracy: 1e-9, "\(scenario): cost on \(a.day)", file: file, line: line)
        }
        XCTAssertEqual(cached.totalTokens, fresh.totalTokens, "\(scenario): 30-day tokens", file: file, line: line)
        XCTAssertEqual(cached.totalCostUSD, fresh.totalCostUSD, accuracy: 1e-9, "\(scenario): 30-day cost", file: file, line: line)
        XCTAssertEqual(cached.byModel.map { "\($0.model)=\($0.tokens)" }, fresh.byModel.map { "\($0.model)=\($0.tokens)" },
                       "\(scenario): by-model tokens", file: file, line: line)
        XCTAssertEqual(cached.isCompleteHistory, fresh.isCompleteHistory, "\(scenario): provenance", file: file, line: line)

        // What the popover prices and plots, and what the ledger stores.
        let table = await PricingService.shared.snapshot()
        XCTAssertEqual(cached.costUSD(from: nil, table: table), fresh.costUSD(from: nil, table: table), accuracy: 1e-9,
                       "\(scenario): all-days cost", file: file, line: line)
        XCTAssertEqual(cached.modelSpend(from: UsageReport.totalsCutoff(), table: table),
                       fresh.modelSpend(from: UsageReport.totalsCutoff(), table: table),
                       "\(scenario): model spend", file: file, line: line)
        // The ledger's stored dollars (compat output for older builds) are a
        // float sum over a dictionary, whose order differs per instance, so
        // they can differ in the last bits between two equal reports; every
        // count is compared exactly.
        let freshLedger = LifetimeSpendTracker.merge(existing: [], reports: [fresh], table: table)
        let cachedLedger = LifetimeSpendTracker.merge(existing: [], reports: [cached], table: table)
        XCTAssertEqual(cachedLedger.count, freshLedger.count, "\(scenario): ledger days", file: file, line: line)
        for (a, b) in zip(freshLedger, cachedLedger) {
            XCTAssertEqual(b.provider, a.provider, scenario, file: file, line: line)
            XCTAssertEqual(b.day, a.day, "\(scenario): ledger day", file: file, line: line)
            XCTAssertEqual(b.tokens, a.tokens, "\(scenario): ledger tokens on \(a.day)", file: file, line: line)
            XCTAssertEqual(b.models, a.models, "\(scenario): ledger models on \(a.day)", file: file, line: line)
            XCTAssertEqual(b.costUSD, a.costUSD, accuracy: 1e-9, "\(scenario): ledger cost on \(a.day)", file: file, line: line)
        }
        let freshPoints = LifetimeSpendTracker.dayPoints(ledger: freshLedger, report: fresh, table: table)
        let cachedPoints = LifetimeSpendTracker.dayPoints(ledger: cachedLedger, report: cached, table: table)
        XCTAssertEqual(cachedPoints.map(\.day), freshPoints.map(\.day), "\(scenario): activity days", file: file, line: line)
        for (a, b) in zip(freshPoints, cachedPoints) {
            XCTAssertEqual(b.tokens, a.tokens, "\(scenario): activity tokens on \(a.day)", file: file, line: line)
            XCTAssertEqual(b.costUSD, a.costUSD, accuracy: 1e-9, "\(scenario): activity cost on \(a.day)", file: file, line: line)
        }
    }

    private func entryFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: fixture.cacheDir, includingPropertiesForKeys: nil)) ?? [])
    }

    private func entryFile(for log: URL) -> URL {
        fixture.cacheDir.appendingPathComponent(ClaudeUsageCacheStore.entryFileName(for: log.path))
    }

    // MARK: - Scenarios

    func testFixtureParsesToTheExpectedTotals() async {
        let fresh = await freshReport()
        XCTAssertEqual(fresh.buckets.count, 4)
        XCTAssertEqual(fresh.totalTokens, 412 + 105 + 24, "d2 + d1 + d0 inside the 30-day window")
        XCTAssertEqual(fresh.buckets.first?.totalTokens, 3000, "the 40-day-old record stays in buckets only")
        XCTAssertEqual(fresh.dayModels.count, 7)
    }

    func testFirstParsePersistsOneEntryPerFile() async {
        let cache = persistentCache()
        let cached = await cachedReport(cache)
        let fresh = await freshReport()
        await assertEquivalent(fresh, cached, "first parse")

        let stats = await cache.stats.snapshot()
        XCTAssertEqual(stats.fullParses, fixture.files.count, "every file is read once")
        XCTAssertEqual(Set(entryFiles().map(\.lastPathComponent)),
                       Set(fixture.files.map { ClaudeUsageCacheStore.entryFileName(for: $0.path) }),
                       "one entry on disk per log file, nothing else")
    }

    func testRestartReadsNoLogBytesWhenNothingChanged() async {
        _ = await cachedReport(persistentCache())

        // A new process: empty memory, the same directory on disk.
        let relaunched = persistentCache()
        let cached = await cachedReport(relaunched)
        let fresh = await freshReport()
        await assertEquivalent(fresh, cached, "restart")

        let stats = await relaunched.stats.snapshot()
        XCTAssertEqual(stats.fullParses, 0)
        XCTAssertEqual(stats.resumedParses, 0)
        XCTAssertEqual(stats.filesOpened, 0, "an unchanged file is never opened")
        XCTAssertEqual(stats.storeHits, fixture.files.count)

        // And once more inside that process: memory now answers.
        _ = await cachedReport(relaunched)
        let again = await relaunched.stats.snapshot()
        XCTAssertEqual(again.filesOpened, 0)
        XCTAssertEqual(again.memoryHits, fixture.files.count)
    }

    func testAppendParsesOnlyTheTail() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)

        let target = fixture.file("a-main.jsonl")
        let before = try XCTUnwrap(LogFileFingerprint.current(for: target)).size
        try append([
            record(d0, mid: "msg-a10", rid: "req-a10", model: "claude-sonnet-4-20250514", input: 1, output: 1),
            // b-resumed already carries msg-b3; a-main sorts first and now wins it.
            record(d1, mid: "msg-b3", rid: "req-b3", model: "claude-opus-4-1-20250805", input: 30, output: 40, w1h: 3),
            // A repeat of a record this file already holds, across the resume boundary.
            record(d2, mid: "msg-a1", rid: "req-a1", model: "claude-sonnet-4-20250514", input: 10, output: 20)
        ], to: target)
        let after = try XCTUnwrap(LogFileFingerprint.current(for: target)).size

        let fresh = await freshReport()
        XCTAssertEqual(fresh.totalTokens, 412 + 105 + 24 + 2, "only msg-a10 is new usage")
        for (name, cache) in try sameProcessAndRestart(cache) {
            await cache.stats.reset()
            let cached = await cachedReport(cache)
            await assertEquivalent(fresh, cached, "append, \(name)")
            let stats = await cache.stats.snapshot()
            XCTAssertEqual(stats.fullParses, 0, "\(name): the head is not re-read")
            XCTAssertEqual(stats.resumedParses, 1, name)
            XCTAssertEqual(stats.bytesCommitted, after - before, "\(name): exactly the appended bytes")
        }
    }

    func testTruncationReparsesFromTheTop() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)

        let target = fixture.file("b-resumed.jsonl")
        let lines = try String(contentsOf: target, encoding: .utf8).split(separator: "\n").map(String.init)
        try write(Array(lines.prefix(3)), to: target)

        let fresh = await freshReport()
        for (name, cache) in try sameProcessAndRestart(cache) {
            await cache.stats.reset()
            let cached = await cachedReport(cache)
            await assertEquivalent(fresh, cached, "truncation, \(name)")
            let stats = await cache.stats.snapshot()
            XCTAssertEqual(stats.fullParses, 1, name)
            XCTAssertEqual(stats.resumedParses, 0, name)
        }
    }

    func testReplacedFileIsReparsed() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)

        // A new inode at the same path, longer than before: a resume would
        // read the old head out of the cache and only the new tail from disk.
        let target = fixture.file("c-other.jsonl")
        try FileManager.default.removeItem(at: target)
        try write([
            record(d0, mid: "msg-c9", rid: "req-c9", model: "claude-3-5-haiku-20241022", input: 70, output: 80, cacheRead: 90),
            record(d1, mid: "msg-c8", rid: "req-c8", model: "claude-3-5-haiku-20241022", input: 1, output: 1)
        ], to: target)

        let fresh = await freshReport()
        for (name, cache) in try sameProcessAndRestart(cache) {
            await cache.stats.reset()
            let cached = await cachedReport(cache)
            await assertEquivalent(fresh, cached, "replacement, \(name)")
            let stats = await cache.stats.snapshot()
            XCTAssertEqual(stats.fullParses, 1, name)
        }
    }

    func testSameSizeEditIsNotMistakenForAnAppend() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)

        // "input_tokens":1 → "input_tokens":9 — same byte count, same inode.
        let target = fixture.file("a-main.jsonl")
        let before = try XCTUnwrap(LogFileFingerprint.current(for: target))
        let text = try String(contentsOf: target, encoding: .utf8)
        let edited = text.replacingOccurrences(of: #""msg-a3","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1,"#,
                                               with: #""msg-a3","model":"claude-sonnet-4-20250514","usage":{"input_tokens":9,"#)
        XCTAssertNotEqual(edited, text)
        try Data(edited.utf8).write(to: target)   // in place, no rename
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.modifiedAt + 2)],
                                              ofItemAtPath: target.path)
        let after = try XCTUnwrap(LogFileFingerprint.current(for: target))
        XCTAssertEqual(after.size, before.size)
        XCTAssertTrue(after.hasSameStableIdentity(as: before))

        let fresh = await freshReport()
        XCTAssertEqual(fresh.totalTokens, 412 + 105 + 24 + 8, "the edit is visible to a fresh parse")
        for (name, cache) in try sameProcessAndRestart(cache) {
            await cache.stats.reset()
            let cached = await cachedReport(cache)
            await assertEquivalent(fresh, cached, "same-size edit, \(name)")
            let stats = await cache.stats.snapshot()
            XCTAssertEqual(stats.fullParses, 1, name)
        }
    }

    func testTouchedButUnchangedFileStillAgrees() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)
        let target = fixture.file("b-resumed.jsonl")
        let before = try XCTUnwrap(LogFileFingerprint.current(for: target))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.modifiedAt + 5)],
                                              ofItemAtPath: target.path)

        let fresh = await freshReport()
        let cached = await cachedReport(persistentCache())
        await assertEquivalent(fresh, cached, "touch")
    }

    func testInPlaceRewriteThatGrowsIsCaughtAtTheBoundary() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)

        // Same inode, longer, but the bytes before the old boundary changed:
        // the whole file was rewritten, not appended to.
        let target = fixture.file("c-other.jsonl")
        let rewritten = [
            record(d0, mid: "msg-c1", rid: "req-c1", model: "claude-3-5-haiku-20241022", input: 70, output: 80, cacheRead: 90),
            record(d1, mid: "msg-c8", rid: "req-c8", model: "claude-3-5-haiku-20241022", input: 1, output: 1)
        ].joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.close()

        let fresh = await freshReport()
        for (name, cache) in try sameProcessAndRestart(cache) {
            await cache.stats.reset()
            let cached = await cachedReport(cache)
            await assertEquivalent(fresh, cached, "in-place rewrite, \(name)")
            let stats = await cache.stats.snapshot()
            XCTAssertEqual(stats.fullParses, 1, name)
            XCTAssertEqual(stats.resumedParses, 0, name)
        }
    }

    func testDeletedFileLeavesTheReportAndTheStore() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)
        let gone = fixture.file("b-resumed.jsonl")
        let goneEntry = entryFile(for: gone)
        XCTAssertTrue(FileManager.default.fileExists(atPath: goneEntry.path))
        try FileManager.default.removeItem(at: gone)
        try FileManager.default.removeItem(at: fixture.file("d-empty.jsonl"))

        let fresh = await freshReport()
        XCTAssertEqual(fresh.buckets.count, 3, "the 40-day-old day left with its file")
        for (name, cache) in try sameProcessAndRestart(cache) {
            let cached = await cachedReport(cache)
            await assertEquivalent(fresh, cached, "deletion, \(name)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: goneEntry.path),
                       "a complete scan drops the entry of a file that no longer exists")
    }

    func testWindowedScanKeepsEntriesOfFilesOutsideItsWindow() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)
        let all = Set(entryFiles().map(\.lastPathComponent))
        XCTAssertEqual(all.count, fixture.files.count)

        // The minute-by-minute scan reads a few recent files; the others'
        // entries are what the next complete scan needs.
        let window = [fixture.file("a-main.jsonl"), fixture.file("c-other.jsonl")]
        let windowed = await cachedReport(cache, window, completeHistory: false)
        let freshWindowed = await freshReport(window, completeHistory: false)
        await assertEquivalent(freshWindowed, windowed, "windowed")
        XCTAssertEqual(Set(entryFiles().map(\.lastPathComponent)), all, "a windowed scan prunes nothing on disk")

        // The complete scan after it opens no file.
        let relaunched = persistentCache()
        let complete = await cachedReport(relaunched)
        await assertEquivalent(await freshReport(), complete, "complete after windowed")
        let stats = await relaunched.stats.snapshot()
        XCTAssertEqual(stats.filesOpened, 0)

        // Only a complete scan over a smaller list prunes.
        _ = await cachedReport(relaunched, window, completeHistory: true)
        XCTAssertEqual(Set(entryFiles().map(\.lastPathComponent)),
                       Set(window.map { ClaudeUsageCacheStore.entryFileName(for: $0.path) }))
    }

    func testCorruptEntryIsDiscardedAndRebuilt() async throws {
        _ = await cachedReport(persistentCache())
        let entry = entryFile(for: fixture.file("a-main.jsonl"))
        var bytes = try Data(contentsOf: entry)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: entry)

        let fresh = await freshReport()
        let cache = persistentCache()
        let cached = await cachedReport(cache)
        await assertEquivalent(fresh, cached, "corrupt entry")
        let stats = await cache.stats.snapshot()
        XCTAssertEqual(stats.fullParses, 1, "only the file behind the bad entry is re-read")
        let storeStats = await cache.store!.statistics()
        XCTAssertEqual(storeStats.invalidEntries, 1)

        let rebuilt = persistentCache()
        _ = await cachedReport(rebuilt)
        let rebuiltStats = await rebuilt.stats.snapshot()
        XCTAssertEqual(rebuiltStats.filesOpened, 0, "the entry was rewritten")
    }

    func testIncompatibleVersionIsIgnored() async throws {
        _ = await cachedReport(persistentCache())
        let entry = entryFile(for: fixture.file("b-resumed.jsonl"))
        var bytes = try Data(contentsOf: entry)
        // Bytes 4..<8 hold the little-endian format version behind the magic.
        bytes.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        try bytes.write(to: entry)

        let fresh = await freshReport()
        let cache = persistentCache()
        let cached = await cachedReport(cache)
        await assertEquivalent(fresh, cached, "version mismatch")
        let stats = await cache.stats.snapshot()
        XCTAssertEqual(stats.fullParses, 1)
    }

    func testInterruptedWriteLeavesNothingUsable() async throws {
        _ = await cachedReport(persistentCache())
        let entry = entryFile(for: fixture.file("a-main.jsonl"))
        let bytes = try Data(contentsOf: entry)
        try bytes.prefix(bytes.count / 2).write(to: entry)
        let stray = fixture.cacheDir.appendingPathComponent("\(UUID().uuidString).tmp")
        try Data(bytes.prefix(10)).write(to: stray)

        let fresh = await freshReport()
        let cache = persistentCache()
        let cached = await cachedReport(cache)
        await assertEquivalent(fresh, cached, "torn entry")
        let stats = await cache.stats.snapshot()
        XCTAssertEqual(stats.fullParses, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "a complete scan sweeps stray temp files")
    }

    func testCalendarChangeInvalidatesEveryEntry() async throws {
        _ = await cachedReport(persistentCache(tag: "gregorian|Asia/Tokyo"))
        let fresh = await freshReport()
        let moved = persistentCache(tag: "gregorian|Europe/Berlin")
        let cached = await cachedReport(moved)
        await assertEquivalent(fresh, cached, "time zone change")
        let stats = await moved.stats.snapshot()
        XCTAssertEqual(stats.fullParses, fixture.files.count, "day boundaries moved, so nothing cached is trusted")
    }

    func testTrailingPartialLineIsShownButNotPersisted() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)
        let snapshot = try snapshotCacheDir()
        let target = fixture.file("c-other.jsonl")
        let partial = record(d0, mid: "msg-c2", rid: "req-c2", model: "claude-3-5-haiku-20241022", input: 100, output: 100)
        try append([partial], to: target, terminated: false)

        let fresh = await freshReport()
        XCTAssertEqual(fresh.totalTokens, 412 + 105 + 24 + 200, "the unterminated record is shown")
        for (name, cache) in [("same process", cache), ("after restart", persistentCache(at: snapshot))] {
            await cache.stats.reset()
            let cached = await cachedReport(cache)
            await assertEquivalent(fresh, cached, "partial line, \(name)")
            let stats = await cache.stats.snapshot()
            XCTAssertEqual(stats.bytesCommitted, 0, "\(name): nothing newline-terminated was added")
        }

        // The writer finishes the line and adds another.
        try append([], to: target)   // just the newline
        try append([record(d0, mid: "msg-c3", rid: "req-c3", model: "claude-3-5-haiku-20241022", input: 1, output: 1)], to: target)
        let fresh2 = await freshReport()
        XCTAssertEqual(fresh2.totalTokens, fresh.totalTokens + 2)
        for (name, cache) in [("same process", cache), ("after restart", persistentCache(at: snapshot))] {
            await cache.stats.reset()
            let cached = await cachedReport(cache)
            await assertEquivalent(fresh2, cached, "completed line, \(name)")
            let stats = await cache.stats.snapshot()
            XCTAssertEqual(stats.fullParses, 0, name)
        }
    }

    func testConcurrentScansAgreeAndLeaveAValidStore() async throws {
        let cache = persistentCache()
        let fresh = await freshReport()
        let files = fixture.files
        let reports = await withTaskGroup(of: UsageReport.self, returning: [UsageReport].self) { group in
            for i in 0..<6 {
                group.addTask {
                    await ClaudeJSONLScanner.usageReport(files: files, completeHistory: i % 2 == 0, cache: cache)
                }
            }
            var out: [UsageReport] = []
            for await report in group { out.append(report) }
            return out
        }
        for report in reports {
            await assertEquivalent(
                report.isCompleteHistory ? fresh : await freshReport(completeHistory: false),
                report, "concurrent scan")
        }
        let relaunched = persistentCache()
        let cached = await cachedReport(relaunched)
        await assertEquivalent(fresh, cached, "after concurrent scans")
        let stats = await relaunched.stats.snapshot()
        XCTAssertEqual(stats.filesOpened, 0)
    }

    func testOlderScanDoesNotOverwriteANewerEntry() async throws {
        let cache = persistentCache()
        _ = await cachedReport(cache)
        let target = fixture.file("a-main.jsonl")
        let store = try XCTUnwrap(cache.store)
        let stored = await store.entry(for: target.path)
        let newer = try XCTUnwrap(stored)

        // What a scan that fingerprinted the file before the last append, and
        // finished after it, would try to store.
        let older = ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(
                path: newer.fingerprint.path, size: newer.fingerprint.size - 10,
                modifiedAt: newer.fingerprint.modifiedAt - 1,
                fileID: newer.fingerprint.fileID, volumeID: newer.fingerprint.volumeID),
            parsedBytes: newer.parsedBytes - 10,
            value: ClaudeFileUsage(keyed: [], unkeyed: [], boundaryDigest: newer.value.boundaryDigest))
        let accepted = await store.save(older, scan: 0)
        XCTAssertFalse(accepted)
        let afterRejectedSave = await store.entry(for: target.path)
        XCTAssertEqual(afterRejectedSave, newer)
        let stats = await store.statistics()
        XCTAssertEqual(stats.rejectedWrites, 1)
    }
}
