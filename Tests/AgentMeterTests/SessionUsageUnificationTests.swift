import Foundation
import XCTest
@testable import AgentMeter

/// A session row, the usage report and the history count the same records
/// from one parse: the row reads its transcripts through the usage scan's
/// cache (`ClaudeJSONLScanner.fileUsages`), and what it takes further reaches
/// the history as a session read, a delta on what the store holds.
final class SessionUsageUnificationTests: XCTestCase {
    private let t0 = "2026-07-05T14:58:00Z"

    private func record(_ id: String, _ ts: String, model: String, input: Int, output: Int,
                        final: Bool, effort: String? = nil, iterations: String? = nil) -> String {
        let stop = final ? #","stop_reason":"end_turn""# : ""
        let effortField = effort.map { #","effort":"\#($0)""# } ?? ""
        let iterationsField = iterations.map { #","iterations":\#($0)"# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"r-\#(id)"\#(effortField),"message":{"id":"\#(id)","model":"\#(model)"\#(stop),"usage":{"input_tokens":\#(input),"output_tokens":\#(output)\#(iterationsField)}}}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    private func session(_ main: URL) -> ActiveAgentSession {
        ActiveAgentSession(id: main.deletingPathExtension().lastPathComponent, projectPath: "/p", projectName: "p",
                           branch: nil, lastUpdatedAt: nil, source: "test", logPath: main.path)
    }

    private func sum(_ byModel: [String: TokenCounts]) -> [String: Int] {
        byModel.mapValues(\.total).filter { $0.value > 0 }
    }

    private func scalar(_ store: HistoryStore, _ sql: String) async throws -> String? {
        try await store.withDatabase { try $0.conn.queryText(sql) }
    }

    /// One session: a main transcript with a Fable request that fell back to
    /// Sonnet (two iterations), a streaming record whose final one lands
    /// later, and a zeroed replay; a subagent whose request a workflow agent
    /// replays as an unfinished copy; a workflow `journal.jsonl` beside it.
    /// The history is fed by the scan, as in the app.
    func testTheRowTheReportAndTheHistoryCountTheSameRequests() async throws {
        let root = historyTempDirectory()
        let main = root.appendingPathComponent("s-unify.jsonl")
        let subagents = root.appendingPathComponent("s-unify/subagents", isDirectory: true)
        let a1 = subagents.appendingPathComponent("agent-a1.jsonl")
        let w1 = subagents.appendingPathComponent("workflows/wf_1/agent-w1.jsonl")
        let journal = subagents.appendingPathComponent("workflows/wf_1/journal.jsonl")
        let fallback = #"[{"model":"claude-fable-5-1","input_tokens":50,"output_tokens":5},{"model":"claude-sonnet-4","input_tokens":60,"output_tokens":20}]"#
        try write([
            #"{"type":"ai-title","sessionId":"s-unify","aiTitle":"Unify"}"#,
            record("m1", "2026-07-05T14:58:00Z", model: "claude-sonnet-4", input: 100, output: 10, final: false),
            record("m2", "2026-07-05T14:59:00Z", model: "claude-sonnet-4", input: 60, output: 20, final: true,
                   effort: "low", iterations: fallback),
            record("m1", "2026-07-05T15:01:00Z", model: "claude-sonnet-4", input: 100, output: 40, final: true,
                   effort: "high"),
            // A zeroed replay of m2, written last: counted nowhere.
            record("m2", "2026-07-05T15:02:00Z", model: "claude-sonnet-4", input: 0, output: 0, final: true),
        ], to: main)
        try write([
            record("m9", "2026-07-05T14:58:30Z", model: "claude-haiku-4", input: 20, output: 3, final: false),
            record("m9", "2026-07-05T14:58:40Z", model: "claude-haiku-4", input: 20, output: 9, final: true),
        ], to: a1)
        try write([
            record("m9", "2026-07-05T14:58:30Z", model: "claude-haiku-4", input: 20, output: 3, final: false),
            record("m7", "2026-07-05T14:58:50Z", model: "claude-haiku-4", input: 5, output: 5, final: true),
        ], to: w1)
        try write([#"{"type":"journal","agent":"w1"}"#], to: journal)

        let cache = ClaudeUsageCache(store: nil)
        let store = HistoryStore(directory: root.appendingPathComponent("db", isDirectory: true))
        let report = await ClaudeJSONLScanner.usageReport(files: [main, a1, w1, journal], cache: cache, history: store)
        await store.flush()
        let applied = await store.statistics().appliedCommands
        let row = await ActiveAgentService.sessionWithUsage(session(main), provider: .claude, observedAt: Date(),
                                                            claudeCache: cache, history: store)
        await store.flush()

        // m1 final 140 + m2's two iterations 55 + 80 + m9 final 29 + m7 10.
        XCTAssertEqual(row.tokenCount, 314)
        XCTAssertEqual(row.title, "Unify")
        XCTAssertEqual(row.model, "claude-sonnet-4", "m1's final record is the request counted last")
        XCTAssertEqual(row.effort, "high")
        let rows = Dictionary(uniqueKeysWithValues: row.subagents.map { ($0.id, $0.tokenCount) })
        XCTAssertEqual(rows["a1"], 29)
        XCTAssertEqual(rows["w1"], 33, "a subagent row counts its own copy (m9 unfinished) as before")
        let applied2 = await store.statistics().appliedCommands
        XCTAssertEqual(applied2, applied, "a read that parsed nothing hands the history nothing")

        var reportByModel: [String: TokenCounts] = [:]
        for entry in report.dayModels { reportByModel[entry.model, default: TokenCounts()].add(entry.counts) }
        let expected = ["claude-fable-5-1": 55, "claude-sonnet-4": 220, "claude-haiku-4": 39]
        XCTAssertEqual(sum(reportByModel), expected)

        let history = try await store.sessionUsage(sessionID: "s-unify")
        var historyByModel: [String: TokenCounts] = [:]
        for entry in history.byModel { historyByModel[entry.model, default: TokenCounts()].add(entry.counts) }
        XCTAssertEqual(sum(historyByModel), expected)
        e2eAssertDayModels(try await store.dayModelUsage(), report, "history vs report")
        await store.close()
    }

    /// A streaming record the scan put into the history, its final record
    /// appended after midnight and read first by a session row: the row
    /// counts it once at its final counts, the history takes it as a delta on
    /// the scan's watermark, still on the day it was first counted on, the
    /// read records no scan coverage, and the next scan finds the file in step.
    func testARowReadHandsTheHistoryItsDeltaAndRecordsNoCoverage() async throws {
        let root = historyTempDirectory()
        let main = root.appendingPathComponent("s-resume.jsonl")
        let iso = ISO8601DateFormatter()
        let midnight = Calendar.current.startOfDay(for: iso.date(from: t0)!.addingTimeInterval(86_400))
        let before = iso.string(from: midnight.addingTimeInterval(-120))
        let after = iso.string(from: midnight.addingTimeInterval(120))
        try write([record("m1", before, model: "claude-sonnet-4", input: 100, output: 10, final: false)], to: main)

        let cache = ClaudeUsageCache(store: nil)
        let store = HistoryStore(directory: root.appendingPathComponent("db", isDirectory: true))
        _ = await ClaudeJSONLScanner.usageReport(files: [main], cache: cache, history: store)
        await store.flush()
        let row = "SELECT finality || ':' || output || ':' || acct_day FROM request"
        let partial = try await scalar(store, row)
        let coverage = "SELECT (SELECT count(*) FROM ingest_scan) || ':' || "
            + "ifnull((SELECT value FROM meta WHERE key = 'latest_scan_ms'), '-') || ':' || "
            + "ifnull((SELECT value FROM meta WHERE key = 'complete_scan_ms'), '-')"
        let coverageBefore = try await scalar(store, coverage)

        try append([record("m1", after, model: "claude-sonnet-4", input: 100, output: 40, final: true)], to: main)
        await cache.stats.reset()
        let read = await ActiveAgentService.sessionWithUsage(session(main), provider: .claude, observedAt: Date(),
                                                             claudeCache: cache, history: store)
        await store.flush()
        let stats = await cache.stats.snapshot()
        XCTAssertEqual(stats.resumedParses, 1, "read from where the scan stopped")
        XCTAssertEqual(read.tokenCount, 140)
        let day = e2eDayNumber(midnight.addingTimeInterval(-120))
        XCTAssertEqual(partial, "1:10:\(day)")
        let final = try await scalar(store, row)
        XCTAssertEqual(final, "2:40:\(day)", "final now, still on the day it was first counted on")
        let coverageAfter = try await scalar(store, coverage)
        XCTAssertEqual(coverageAfter, coverageBefore, "a session read is no scan")

        let changes = try await store.withDatabase { $0.conn.totalChanges }
        _ = await ClaudeJSONLScanner.usageReport(files: [main], cache: cache, history: store)
        await store.flush()
        let changesAfter = try await store.withDatabase { $0.conn.totalChanges }
        XCTAssertLessThanOrEqual(changesAfter - changes, 1, "at most the scan's coverage stamp, no row rewritten")

        let cold = await ActiveAgentService.sessionWithUsage(session(main), provider: .claude, observedAt: Date(),
                                                             claudeCache: ClaudeUsageCache(store: nil))
        XCTAssertEqual(cold.tokenCount, read.tokenCount)
        await store.close()
    }

    /// A session read that runs while a scan is in flight on the same file.
    /// (a) The scan, holding an older fingerprint, does not parse the whole
    /// file again after the row read it further. (b) A row's delta on a
    /// state the in-flight scan has not submitted yet is not applied whole:
    /// it is skipped, the next scan brings the file, and the history ends up
    /// as a scan alone would have built it.
    func testARowReadBesideAnInFlightScan() async throws {
        let root = historyTempDirectory()
        let main = root.appendingPathComponent("s-race.jsonl")
        try write([record("m1", t0, model: "claude-sonnet-4", input: 10, output: 1, final: true)], to: main)
        let cache = ClaudeUsageCache(store: nil)
        let store = HistoryStore(directory: root.appendingPathComponent("db", isDirectory: true))
        _ = await ClaudeJSONLScanner.usageReport(files: [main], cache: cache, history: store)
        await store.flush()

        // (a) A scan fingerprints the file; it grows; a row reads it further.
        try append([record("m2", "2026-07-05T15:00:00Z", model: "claude-sonnet-4", input: 20, output: 2, final: true)], to: main)
        let stale = try XCTUnwrap(LogFileFingerprint.current(for: main))
        try append([record("m3", "2026-07-05T15:01:00Z", model: "claude-sonnet-4", input: 30, output: 3, final: true)], to: main)
        _ = await ClaudeJSONLScanner.fileUsages([main], cache: cache)
        await cache.stats.reset()
        let inFlight = await ClaudeJSONLScanner.cachedUsage(in: main, fingerprint: stale, cache: cache,
                                                            scan: await cache.memory.beginScan())
        let opened = await cache.stats.snapshot().filesOpened
        XCTAssertEqual(inFlight.origin, .memory, "the newer state, not a parse from the top")
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(inFlight.usage.keyed.count, 3)

        // (b) The in-flight scan's state is in memory but not in the history;
        // the file grows again and a row resumes from that state.
        try append([record("m4", "2026-07-05T15:02:00Z", model: "claude-sonnet-4", input: 40, output: 4, final: true)], to: main)
        let rows = "SELECT count(*) FROM request"
        let before = try await scalar(store, rows)
        _ = await ActiveAgentService.sessionWithUsage(session(main), provider: .claude, observedAt: Date(),
                                                      claudeCache: cache, history: store)
        await store.flush()
        let skipped = await store.statistics().skippedFileBatches
        let afterRow = try await scalar(store, rows)
        XCTAssertEqual(afterRow, before, "the delta is not on what the store holds: skipped, not applied whole")
        XCTAssertGreaterThan(skipped, 0)

        _ = await ClaudeJSONLScanner.usageReport(files: [main], cache: cache, history: store)
        await store.flush()
        let afterScan = try await scalar(store, rows)
        XCTAssertEqual(afterScan, "4")
        let fed = try await store.logicalDump()
        await store.close()

        let alone = HistoryStore(directory: root.appendingPathComponent("db-alone", isDirectory: true))
        _ = await ClaudeJSONLScanner.usageReport(files: [main], cache: ClaudeUsageCache(store: nil), history: alone)
        await alone.flush()
        e2eAssertDump(fed, try await alone.logicalDump(), "row reads beside scans vs a scan alone")
        await alone.close()
    }

    /// A session's `logPath` through a symlinked `projects/<key>`: the row
    /// reads the file under the spelling the scan lists, so the cache and the
    /// history hold it once.
    func testARowReadThroughASymlinkedProjectRecordsTheFileOnce() async throws {
        let root = historyTempDirectory()
        let store0 = root.appendingPathComponent("store/real", isDirectory: true)
        let link = root.appendingPathComponent("projects/key", isDirectory: false)
        try FileManager.default.createDirectory(at: store0, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store0)
        let real = store0.appendingPathComponent("s-link.jsonl")
        try write([record("m1", t0, model: "claude-sonnet-4", input: 10, output: 1, final: true)], to: real)
        let aliased = link.appendingPathComponent("s-link.jsonl")
        XCTAssertEqual(ActiveAgentService.scanSpelling(aliased).path, real.path)

        let cache = ClaudeUsageCache(store: nil)
        let store = HistoryStore(directory: root.appendingPathComponent("db", isDirectory: true))
        _ = await ClaudeJSONLScanner.usageReport(files: [real], cache: cache, history: store)
        await store.flush()
        try append([record("m2", "2026-07-05T15:00:00Z", model: "claude-sonnet-4", input: 20, output: 2, final: true)], to: real)
        await cache.stats.reset()
        let row = await ActiveAgentService.sessionWithUsage(session(aliased), provider: .claude, observedAt: Date(),
                                                            claudeCache: cache, history: store)
        await store.flush()
        let stats = await cache.stats.snapshot()
        XCTAssertEqual(stats.resumedParses, 1, "resumed from the scan's entry, not a second one")
        XCTAssertEqual(row.tokenCount, 33)
        XCTAssertEqual(row.logPath, aliased.path)
        let files = try await scalar(store, "SELECT count(*) || ':' || (SELECT count(*) FROM request_occurrence) FROM source_file")
        XCTAssertEqual(files, "1:2")
        await store.close()
    }

    /// The row's model and effort are those of the request the file counted
    /// last: a replacing record counts as new, a zeroed replay of an earlier
    /// request does not, replays first seen here go by their own time, and
    /// records without a time go by file order. Records without a message id
    /// are not keyed and do not take part (none in the corpus).
    func testModelAndEffortFollowTheRequestCountedLast() async throws {
        let root = historyTempDirectory()
        func latest(_ lines: [String]) async throws -> (model: String, effort: String?)? {
            let url = root.appendingPathComponent("f-\(UUID().uuidString).jsonl")
            try write(lines, to: url)
            return await ClaudeJSONLScanner.fileUsages([url], cache: ClaudeUsageCache(store: nil))[0].latestCounted
        }

        let replaced = try await latest([
            record("m1", "2026-07-05T00:00:00Z", model: "claude-opus-4", input: 1, output: 1, final: false, effort: "high"),
            record("m2", "2026-07-05T00:01:00Z", model: "claude-haiku-4", input: 1, output: 1, final: true, effort: "low"),
            record("m1", "2026-07-05T00:02:00Z", model: "claude-opus-4", input: 1, output: 5, final: true, effort: "max"),
            record("m2", "2026-07-05T00:03:00Z", model: "claude-haiku-4", input: 0, output: 0, final: true, effort: "low"),
        ])
        XCTAssertEqual(replaced?.model, "claude-opus-4")
        XCTAssertEqual(replaced?.effort, "max")

        let replays = try await latest([
            record("m2", "2026-07-05T00:01:00Z", model: "claude-haiku-4", input: 0, output: 0, final: true),
            record("m1", "2026-07-05T00:00:00Z", model: "claude-opus-4", input: 0, output: 0, final: true),
        ])
        XCTAssertEqual(replays?.model, "claude-haiku-4", "a replay first seen here counts, by its own time")

        let untimed = try await latest([
            #"{"requestId":"r1","effort":"high","message":{"id":"m1","model":"claude-opus-4","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            #"{"requestId":"r2","message":{"id":"m2","model":"claude-haiku-4","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ])
        XCTAssertEqual(untimed?.model, "claude-haiku-4")
        XCTAssertNil(untimed?.effort)

        let unkeyed = try await latest([
            record("m1", "2026-07-05T00:00:00Z", model: "claude-opus-4", input: 1, output: 1, final: true, effort: "high"),
            #"{"type":"assistant","timestamp":"2026-07-05T00:05:00Z","effort":"low","message":{"model":"claude-haiku-4","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ])
        XCTAssertEqual(unkeyed?.model, "claude-opus-4")
        XCTAssertEqual(unkeyed?.effort, "high")

        let none = try await latest([#"{"type":"user","message":{"role":"user","content":"hi"}}"#])
        XCTAssertNil(none?.model)
    }

    /// A row's read leaves the scan's cache to the scans: an entry of a file
    /// no session holds stays where the last scan put it.
    func testARowReadPrunesNothingFromTheScanCache() async throws {
        let root = historyTempDirectory()
        let main = root.appendingPathComponent("s-prune.jsonl")
        let other = root.appendingPathComponent("other.jsonl")
        try write([record("m1", t0, model: "claude-sonnet-4", input: 1, output: 1, final: true)], to: main)
        try write([record("m2", t0, model: "claude-sonnet-4", input: 2, output: 2, final: true)], to: other)
        let cache = ClaudeUsageCache(store: nil)
        _ = await ClaudeJSONLScanner.usageReport(files: [main, other], cache: cache)

        _ = await ActiveAgentService.sessionWithUsage(session(main), provider: .claude, observedAt: Date(),
                                                      claudeCache: cache)
        await cache.stats.reset()
        _ = await ClaudeJSONLScanner.usageReport(files: [main, other], cache: cache)
        let stats = await cache.stats.snapshot()
        XCTAssertEqual(stats.memoryHits, 2)
        XCTAssertEqual(stats.filesOpened, 0)
    }
}
