import Foundation
import XCTest
@testable import AgentMeter

/// The real `~/.claude` corpus through the real scanner into a real history
/// store — read-only, every cache and database in a temporary directory, and
/// only with `AGENTMETER_REAL_CORPUS_BENCH=1`. `AGENTMETER_REAL_CORPUS_QUIET_BEFORE`
/// (epoch seconds; default: an hour ago) restricts the run to files last
/// written before it, the same filter `ClaudeUsageFinalityTests` uses, so the
/// scanner and the history see one quiet file set. One synthetic transcript in
/// the temporary tree stands in for a growing file: real transcripts are never
/// written.
final class HistoryEndToEndRealCorpusTests: XCTestCase {
    private func heapInUse() -> Int64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int64(stats.size_in_use)
    }

    private func peakRSS() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)   // bytes on macOS
    }

    private func cpu() -> Double { Double(clock()) / Double(CLOCKS_PER_SEC) }

    private func mb(_ bytes: Int64) -> String { String(format: "%.2f MB", Double(bytes) / 1e6) }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Rows of a two-column (text, int) query.
    private func pairs(_ store: HistoryStore, _ sql: String) async throws -> [(String, Int64)] {
        try await store.withDatabase { db in
            try db.conn.withStatement(sql) { s in
                var out: [(String, Int64)] = []
                while try s.step() { out.append((s.text(0) ?? "nil", s.int64(1))) }
                return out
            }
        }
    }

    private func int(_ store: HistoryStore, _ sql: String) async throws -> Int64 {
        try await store.withDatabase { try $0.conn.queryInt(sql) ?? -1 }
    }

    /// Per model token sums of the stored rows.
    private func modelSums(_ store: HistoryStore) async throws -> [String: TokenCounts] {
        try await store.withDatabase { db in
            try db.conn.withStatement("""
                SELECT m.value, sum(r.input), sum(r.output), sum(r.cache_write_5m), sum(r.cache_write_1h), sum(r.cache_read)
                FROM request r JOIN dict m ON m.id = r.model_ref GROUP BY m.value
                """) { s in
                var out: [String: TokenCounts] = [:]
                while try s.step() {
                    out[s.text(0) ?? ""] = TokenCounts(input: Int(s.int64(1)), output: Int(s.int64(2)),
                                                       cacheWrite5m: Int(s.int64(3)), cacheWrite1h: Int(s.int64(4)),
                                                       cacheRead: Int(s.int64(5)))
                }
                return out
            }
        }
    }

    private func synthetic(_ range: Range<Int>, start: Int64) -> [String] {
        range.map { n in
            E2EFix.rec(9_000_000 + n, start + Int64(n) * 1_000, out: 10 + n % 7, final: n % 3 != 0,
                       model: n % 5 == 0 ? E2EFix.sonnet : E2EFix.opus, tag: "syn")
        }
    }

    func testRealCorpusColdBackfillWarmRestartAndIncrementalWithAHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGENTMETER_REAL_CORPUS_BENCH"] == "1" else {
            throw XCTSkip("set AGENTMETER_REAL_CORPUS_BENCH=1 to scan the real ~/.claude corpus into a temp history (read-only)")
        }
        let all = ClaudeJSONLScanner.jsonlFiles()
        guard !all.isEmpty else { throw XCTSkip("no Claude logs on this machine") }
        let cutoff = env["AGENTMETER_REAL_CORPUS_QUIET_BEFORE"].flatMap(Double.init) ?? Date().timeIntervalSince1970 - 3_600
        let before = Dictionary(uniqueKeysWithValues: all.compactMap { url in
            LogFileFingerprint.current(for: url).map { (url.path, $0) }
        })
        let quiet = all.filter { (before[$0.path]?.modifiedAt ?? .infinity) < cutoff }
        let logBytes = quiet.reduce(Int64(0)) { $0 + (before[$1.path]?.size ?? 0) }

        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("history-real-corpus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDir = root.appendingPathComponent("amcu", isDirectory: true)
        let dbDir = root.appendingPathComponent("db", isDirectory: true)
        let synthDir = root.appendingPathComponent("projects/-synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: synthDir, withIntermediateDirectories: true)
        let synth = synthDir.appendingPathComponent("5e5e5e5e-0000-4000-8000-000000000001.jsonl")
        let synthStart = HistoryTime.ms(Date()) - 3 * 3_600_000
        try TranscriptFixture.write(synthetic(0..<2_000, start: synthStart), to: synth)
        let files = quiet + [synth]
        func makeStore() -> HistoryStore { HistoryStore(directory: dbDir) }

        // 1. Cold: the first v3 launch. The scan returns; the backfill drains behind it.
        let heapAtStart = heapInUse()
        var cold: ClaudeUsageCache? = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        var store: HistoryStore? = makeStore()
        let cpu0 = cpu(), wall0 = Date()
        let report = await ClaudeJSONLScanner.usageReport(files: files, completeHistory: true, cache: cold!, history: store!)
        let scanWall = Date().timeIntervalSince(wall0), scanCPU = cpu() - cpu0
        let returned = Date()
        await store!.flush()
        let drainWall = Date().timeIntervalSince(returned), totalCPU = cpu() - cpu0
        let coldStats = await cold!.stats.snapshot()
        let coldHeap = heapInUse() - heapAtStart
        let counters = await store!.statistics()
        XCTAssertEqual(counters.failedCommands, 0)
        XCTAssertEqual(counters.failedChunks, 0)
        XCTAssertEqual(counters.droppedSubmissions, 0)

        // 2. Equalities between the database and the scan's report.
        let s = store!
        let rows = try await s.historyStatistics().rowCounts
        let dbKeys = try await int(s, "SELECT count(DISTINCT key) FROM request")
        let dbRows = try await int(s, "SELECT count(*) FROM request")
        let twoIteration = try await int(s, "SELECT count(*) FROM request WHERE iteration_idx = 1")
        var finality = RequestFinalityCounts()
        for value in report.requestFinality.values { finality.add(value) }
        let dbFinality = Dictionary(uniqueKeysWithValues: try await pairs(s, """
            SELECT finality, count(*) FROM request WHERE iteration_idx = 0 GROUP BY finality
            """))
        let dbPartialOutput = try await int(s, "SELECT coalesce(sum(output_total), 0) FROM request WHERE iteration_idx = 0 AND finality = 1")
        XCTAssertEqual(Int(dbKeys), finality.requests, "DB distinct keys == the scan's keyed records")
        XCTAssertEqual(Int(dbFinality["2"] ?? 0), finality.final)
        XCTAssertEqual(Int(dbFinality["1"] ?? 0), finality.partial)
        XCTAssertEqual(Int(dbFinality["0"] ?? 0), finality.zeroed)
        XCTAssertEqual(Int(dbPartialOutput), finality.partialOutput)

        var reportByModel: [String: TokenCounts] = [:]
        for e in report.dayModels { reportByModel[e.model, default: TokenCounts()].add(e.counts) }
        let dbByModel = try await modelSums(s).filter { $0.value.total > 0 }
        var modelDiffs: [String] = []
        for m in Set(reportByModel.keys).union(dbByModel.keys).sorted() where reportByModel[m] != dbByModel[m] {
            modelDiffs.append("  \(m): db \(dbByModel[m].map { "\($0)" } ?? "-") report \(reportByModel[m].map { "\($0)" } ?? "-")")
        }
        XCTAssertTrue(modelDiffs.isEmpty, "per-model sums over every day differ:\n" + modelDiffs.joined(separator: "\n"))
        let dayModels = try await s.dayModelUsage()
        e2eAssertDayModels(dayModels, report, "real corpus day x model")

        let crossFile = try await int(s, "SELECT count(*) FROM (SELECT key FROM request_occurrence GROUP BY key HAVING count(*) > 1)")
        let ownerNotPathOrder = try await int(s, """
            WITH multi AS (SELECT key FROM request_occurrence GROUP BY key HAVING count(*) > 1),
            po AS (SELECT o.key, min(f.path) AS ppath FROM request_occurrence o JOIN source_file f ON f.file_ref = o.file_ref
                   WHERE o.key IN (SELECT key FROM multi) AND o.last_ms IS NOT NULL GROUP BY o.key)
            SELECT count(*) FROM po JOIN request r ON r.key = po.key AND r.iteration_idx = 0
            JOIN source_file f ON f.file_ref = r.owner_file_ref WHERE f.path <> po.ppath
            """)
        let output = dayModels.reduce(0) { $0 + $1.counts.output }
        let dbFile = dbDir.appendingPathComponent(HistoryDatabase.fileName)
        let dbSize = fileSize(dbFile), walSize = fileSize(URL(fileURLWithPath: dbFile.path + "-wal"))
        await store!.close()
        store = nil
        cold = nil

        // 3. Warm restart: a new cache and a new store over the same directories.
        let heapBeforeWarm = heapInUse()
        let warm = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir))
        let warmStore = makeStore()
        _ = try await warmStore.withDatabase { _ in () }    // open outside the measurement, as the app has by then
        let changes0 = try await warmStore.withDatabase { $0.conn.totalChanges }
        let wcpu0 = cpu(), wwall0 = Date()
        let warmReport = await ClaudeJSONLScanner.usageReport(files: files, completeHistory: true, cache: warm, history: warmStore)
        let warmWall = Date().timeIntervalSince(wwall0), warmCPU = cpu() - wcpu0
        await warmStore.flush()
        let warmTotalCPU = cpu() - wcpu0
        let warmStats = await warm.stats.snapshot()
        let warmChanges = try await warmStore.withDatabase { $0.conn.totalChanges } - changes0
        let warmHeap = heapInUse() - heapBeforeWarm
        XCTAssertEqual(warmStats.filesOpened, 0, "warm restart opens no transcript")
        XCTAssertLessThanOrEqual(warmChanges, 3, "the launch's complete scan writes only its coverage row and meta")
        XCTAssertEqual(warmReport.dayModels, report.dayModels)
        // The next minute's windowed scan of the unchanged corpus: zero writes.
        let changes1 = try await warmStore.withDatabase { $0.conn.totalChanges }
        _ = await ClaudeJSONLScanner.usageReport(files: files, completeHistory: false, cache: warm, history: warmStore)
        await warmStore.flush()
        let windowedChanges = try await warmStore.withDatabase { $0.conn.totalChanges } - changes1
        XCTAssertEqual(windowedChanges, 0, "an unchanged windowed scan writes nothing")

        // 4. The same process, the synthetic transcript grown by 200 records.
        try TranscriptFixture.append(synthetic(2_000..<2_200, start: synthStart).joined(separator: "\n") + "\n", to: synth)
        await warm.stats.reset()
        let tee = E2ETeeSink(warmStore)
        let icpu0 = cpu(), iwall0 = Date()
        let incReport = await ClaudeJSONLScanner.usageReport(files: files, completeHistory: false, cache: warm, history: tee)
        let incWall = Date().timeIntervalSince(iwall0), incCPU = cpu() - icpu0
        let idrain0 = Date()
        await warmStore.flush()
        let incDrain = Date().timeIntervalSince(idrain0)
        let incStats = await warm.stats.snapshot()
        XCTAssertEqual(incStats.filesOpened, 1)
        XCTAssertEqual(incStats.resumedParses, 1)
        XCTAssertEqual(tee.scans.last?.file(synth)?.delta?.requests.count, 200, "a delta of the 200 new keys")
        let keysAfter = try await int(warmStore, "SELECT count(DISTINCT key) FROM request")
        XCTAssertEqual(keysAfter, dbKeys + 200)
        e2eAssertDayModels(try await warmStore.dayModelUsage(), incReport, "after the increment")
        await warmStore.close()

        let changed = quiet.filter { LogFileFingerprint.current(for: $0) != before[$0.path] }
        XCTAssertTrue(changed.isEmpty, "quiet files changed during the run: \(changed.count)")
        let rowLine = rows.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("""
        [history-real] files \(files.count) (\(quiet.count) quiet before \(Int(cutoff)), \(String(format: "%.2f", Double(logBytes) / 1e9)) GB) + 1 synthetic
        [history-real] cold scan: wall \(String(format: "%.3f", scanWall)) s cpu \(String(format: "%.3f", scanCPU)) s | backfill drain after return \(String(format: "%.3f", drainWall)) s | cpu scan+drain \(String(format: "%.3f", totalCPU)) s | opened \(coldStats.filesOpened)
        [history-real] heap retained cold (cache + store) \(mb(coldHeap)) | db \(mb(dbSize)) + wal \(mb(walSize)) | \(String(format: "%.0f", Double(dbSize) / Double(max(dbRows, 1)))) B/row
        [history-real] rows: \(rowLine)
        [history-real] keys \(dbKeys) rows \(dbRows) two-iteration \(twoIteration) output \(output) | scanner keyed \(finality.requests) final \(finality.final) partial \(finality.partial) zeroed \(finality.zeroed) partialOutput \(finality.partialOutput) | db final \(dbFinality["2"] ?? 0) partial \(dbFinality["1"] ?? 0) zeroed \(dbFinality["0"] ?? 0) partialOutput \(dbPartialOutput)
        [history-real] cross-file keys \(crossFile), owner != path-order owner \(ownerNotPathOrder), partial-only keys \(dbFinality["1"] ?? 0), per-model diffs \(modelDiffs.count), models \(dbByModel.count)
        [history-real] warm restart: wall \(String(format: "%.3f", warmWall)) s cpu \(String(format: "%.3f", warmCPU)) s (with drain \(String(format: "%.3f", warmTotalCPU)) s) opened \(warmStats.filesOpened) storeHits \(warmStats.storeHits) db changes \(warmChanges) (complete) then \(windowedChanges) (unchanged windowed) heap retained \(mb(warmHeap))
        [history-real] increment (+200 records, same process): wall \(String(format: "%.3f", incWall)) s cpu \(String(format: "%.3f", incCPU)) s drain \(String(format: "%.3f", incDrain)) s opened \(incStats.filesOpened) resumed \(incStats.resumedParses)
        [history-real] process peak rss \(mb(peakRSS()))
        """)
    }
}
