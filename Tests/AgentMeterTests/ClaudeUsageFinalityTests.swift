import Foundation
@testable import AgentMeter
import XCTest

/// Which record stands for a request. Claude Code writes one assistant record
/// per content block; in subagent and workflow transcripts the early ones
/// carry the `message_start` usage (a few output tokens) and only the record
/// with a `stop_reason` carries the request's real output. Since 2.1.282
/// most sidechain requests have no such record at all. A resumed session
/// can also re-append a message with its top-level counts zeroed. Every
/// scenario here is a shape seen in real transcripts.
final class ClaudeUsageFinalityTests: XCTestCase {
    private let sonnet = "claude-sonnet-5-5"
    private let opus = "claude-opus-4-8"
    private let fable = "claude-fable-5-1"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-finality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixture

    /// An hour ago: inside every rolling window whatever the time of day.
    private let at = Date().addingTimeInterval(-3_600)
    private var today: Date { Calendar.current.startOfDay(for: at) }

    private struct Iteration {
        let model: String?
        let input: Int, output: Int, cacheRead: Int, w5m: Int, w1h: Int
    }

    private func usageBlock(input: Int, output: Int, cacheRead: Int, w5m: Int, w1h: Int) -> [String: Any] {
        [
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": w5m + w1h,
            "cache_creation": ["ephemeral_5m_input_tokens": w5m, "ephemeral_1h_input_tokens": w1h],
        ]
    }

    /// One assistant record as Claude Code writes it. `stop` nil is a record
    /// written mid-stream; `zeroed` is a replay (top level zeroed, the cache
    /// split, stop reason and iterations kept).
    private func record(
        _ mid: String?, rid: String? = nil, model: String? = nil, stop: String? = nil,
        input: Int = 2, output: Int, cacheRead: Int = 1_000, w5m: Int = 50, w1h: Int = 0,
        zeroed: Bool = false, iterations: [Iteration]? = nil, at time: Date? = nil
    ) -> String {
        var usage = usageBlock(input: input, output: output, cacheRead: cacheRead, w5m: w5m, w1h: w1h)
        if zeroed {
            for key in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                usage[key] = 0
            }
        }
        if let iterations {
            usage["iterations"] = iterations.map { iteration -> [String: Any] in
                var block = usageBlock(input: iteration.input, output: iteration.output,
                                       cacheRead: iteration.cacheRead, w5m: iteration.w5m, w1h: iteration.w1h)
                block["type"] = "message"
                if let model = iteration.model { block["model"] = model }
                return block
            }
        }
        var message: [String: Any] = ["model": model ?? sonnet, "usage": usage]
        message["stop_reason"] = stop ?? NSNull()
        var object: [String: Any] = [
            "type": "assistant",
            "timestamp": ISO8601DateFormatter().string(from: time ?? at),
        ]
        if let mid {
            message["id"] = mid
            object["requestId"] = rid ?? "req-\(mid)"
        }
        object["message"] = message
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    private func write(_ name: String, _ lines: [String]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func report(_ files: [URL]) async -> UsageReport {
        await ClaudeJSONLScanner.usageReport(files: files, completeHistory: true, cache: ClaudeUsageCache(store: nil))
    }

    private func counts(_ report: UsageReport, model: String? = nil) -> TokenCounts {
        var total = TokenCounts()
        for entry in report.dayModels where model == nil || entry.model == model {
            total.add(entry.counts)
        }
        return total
    }

    // MARK: - Partial and final records

    func testFinalRecordReplacesTheStreamingRecordsBeforeIt() async throws {
        let file = try write("agent-a.jsonl", [
            record("m1", output: 4),
            record("m1", output: 4),
            record("m1", stop: "tool_use", output: 900),
        ])
        let report = await report([file])

        XCTAssertEqual(counts(report), TokenCounts(input: 2, output: 900, cacheWrite5m: 50, cacheWrite1h: 0, cacheRead: 1_000))
        XCTAssertEqual(report.requestFinality[today], RequestFinalityCounts(final: 1, partial: 0, zeroed: 0, partialOutput: 0))
    }

    /// The pick is one whole record. A per-field maximum over the records of
    /// a key would build a combination no record ever carried.
    func testTheFinalRecordIsTakenWholeNotMergedFieldByField() async throws {
        let file = try write("agent-a.jsonl", [
            record("m1", output: 5, cacheRead: 7_000, w5m: 80),
            record("m1", stop: "end_turn", output: 300, cacheRead: 1_000, w5m: 50),
        ])
        let report = await report([file])

        XCTAssertEqual(counts(report), TokenCounts(input: 2, output: 300, cacheWrite5m: 50, cacheWrite1h: 0, cacheRead: 1_000))
    }

    func testAStreamingRecordAfterTheFinalOneDoesNotDisplaceIt() async throws {
        let file = try write("agent-a.jsonl", [
            record("m1", stop: "tool_use", output: 900),
            record("m1", output: 4),
        ])
        let report = await report([file])

        XCTAssertEqual(counts(report).output, 900)
    }

    /// Claude Code 2.1.282+ leaves most sidechain requests without a final
    /// record. What streamed is all there is: counted, but marked partial —
    /// a lower bound, never mistaken for the request's output.
    func testRequestWithoutAFinalRecordCountsWhatStreamedAndIsMarkedPartial() async throws {
        let file = try write("agent-a.jsonl", [
            record("m1", output: 3),
            record("m1", output: 8),
            record("m1", output: 8),
            record("m2", stop: "tool_use", output: 1_200),
        ])
        let report = await report([file])

        XCTAssertEqual(counts(report).output, 8 + 1_200)
        XCTAssertEqual(counts(report).input, 4, "input and cache counts of a partial request are exact")
        XCTAssertEqual(counts(report).cacheRead, 2_000)
        XCTAssertEqual(report.requestFinality[today], RequestFinalityCounts(final: 1, partial: 1, zeroed: 0, partialOutput: 8))
    }

    /// Of two streaming records the one that streamed further stays, in
    /// whichever order they were written; of two equal ones, the earlier.
    func testStreamingRecordsKeepTheFurthestAndOfEqualsTheEarliest() async throws {
        let further = try write("agent-a.jsonl", [
            record("m1", output: 8),
            record("m1", output: 3),
        ])
        let furtherReport = await report([further])
        XCTAssertEqual(counts(furtherReport).output, 8)

        let equal = try write("agent-b.jsonl", [
            record("m2", output: 8, cacheRead: 1_000),
            record("m2", output: 8, cacheRead: 2_000),
        ])
        let equalReport = await report([equal])
        XCTAssertEqual(counts(equalReport).cacheRead, 1_000, "the earlier of two equals, whole")
    }

    // MARK: - Zeroed replays

    func testZeroedReplayNeverCountsWhereverItLands() async throws {
        let replay = record("m1", stop: "end_turn", output: 0, cacheRead: 0, w5m: 0, w1h: 1_508, zeroed: true,
                            at: at.addingTimeInterval(60))
        let original = record("m1", stop: "end_turn", input: 2, output: 604, cacheRead: 174_101, w5m: 0, w1h: 1_508)
        for (name, lines) in [("after", [original, replay]), ("before", [replay, original])] {
            let file = try write("main-\(name).jsonl", lines)
            let report = await report([file])
            XCTAssertEqual(counts(report), TokenCounts(input: 2, output: 604, cacheWrite5m: 0, cacheWrite1h: 1_508, cacheRead: 174_101),
                           "replay \(name) the original")
            XCTAssertEqual(report.requestFinality[today]?.final, 1, name)
        }
    }

    /// The replay keeps the original's `cache_creation` split even though its
    /// top level says zero; counting that split would add cache writes the
    /// original already counted, on the replay's later day.
    func testZeroOnlyKeyCountsNothingAndLeavesNoEmptyDay() async throws {
        let file = try write("main.jsonl", [
            record("m1", stop: "end_turn", output: 0, w5m: 0, w1h: 1_508, zeroed: true),
            record("m2", stop: "end_turn", output: 10),
        ])
        let report = await report([file])

        XCTAssertEqual(counts(report).cacheWrite1h, 0)
        XCTAssertEqual(counts(report).output, 10)
        XCTAssertEqual(report.dayModels.count, 1)
        XCTAssertEqual(report.requestFinality[today], RequestFinalityCounts(final: 1, partial: 0, zeroed: 1, partialOutput: 0))
    }

    /// The replay sits in another file — a forked or resumed session's — and
    /// that file sorts first. The original still counts, once.
    func testZeroedReplayInAnotherFileNeverCounts() async throws {
        let replay = try write("a-fork.jsonl", [
            record("m1", stop: "end_turn", output: 0, cacheRead: 0, w5m: 0, w1h: 1_508, zeroed: true),
        ])
        let original = try write("b-original.jsonl", [
            record("m1", stop: "end_turn", input: 2, output: 604, cacheRead: 174_101, w5m: 0, w1h: 1_508),
        ])
        let report = await report([replay, original])

        XCTAssertEqual(counts(report), TokenCounts(input: 2, output: 604, cacheWrite5m: 0, cacheWrite1h: 1_508, cacheRead: 174_101))
        XCTAssertEqual(report.requestFinality[today], RequestFinalityCounts(final: 1, partial: 0, zeroed: 0, partialOutput: 0))
    }

    /// A record without a message id cannot be matched, so every copy
    /// counts — except a zeroed one, which carries nothing.
    func testUnkeyedZeroedRecordAddsNothing() async throws {
        let file = try write("main.jsonl", [
            record(nil, stop: "end_turn", output: 0, w5m: 0, w1h: 900, zeroed: true),
        ])
        let report = await report([file])

        XCTAssertEqual(report.dayModels, [], "no empty (day, model) row")
    }

    // MARK: - Iterations

    /// A Fable attempt that fell back to Opus: `iterations` holds both calls,
    /// the top level repeats only the last call's input/output/cache read
    /// (and, as Claude Code writes it, the first call's cache write split).
    func testIterationsAreCountedOneByOneUnderTheirOwnModels() async throws {
        let attempt = Iteration(model: fable, input: 8, output: 7_804, cacheRead: 1_018_342, w5m: 548, w1h: 0)
        let fallback = Iteration(model: opus, input: 8, output: 16_315, cacheRead: 810_092, w5m: 6_140, w1h: 5_996)
        let file = try write("main.jsonl", [
            record("m1", model: opus, stop: "tool_use", input: 8, output: 16_315, cacheRead: 810_092,
                   w5m: 548, w1h: 0, iterations: [attempt, fallback]),
        ])
        let report = await report([file])

        XCTAssertEqual(counts(report, model: fable), TokenCounts(input: 8, output: 7_804, cacheWrite5m: 548, cacheWrite1h: 0, cacheRead: 1_018_342))
        XCTAssertEqual(counts(report, model: opus), TokenCounts(input: 8, output: 16_315, cacheWrite5m: 6_140, cacheWrite1h: 5_996, cacheRead: 810_092))
        XCTAssertEqual(report.requestFinality[today]?.requests, 1, "two calls, one request")
    }

    func testSingleIterationIsReadFromTheTopLevel() async throws {
        let only = Iteration(model: sonnet, input: 2, output: 40, cacheRead: 1_000, w5m: 50, w1h: 0)
        let file = try write("main.jsonl", [
            record("m1", stop: "end_turn", output: 40, iterations: [only]),
        ])
        let report = await report([file])

        XCTAssertEqual(counts(report), TokenCounts(input: 2, output: 40, cacheWrite5m: 50, cacheWrite1h: 0, cacheRead: 1_000))
    }

    func testIterationWithoutAModelFallsUnderTheRecordsModel() async throws {
        let first = Iteration(model: nil, input: 1, output: 10, cacheRead: 100, w5m: 0, w1h: 0)
        let last = Iteration(model: nil, input: 1, output: 20, cacheRead: 200, w5m: 0, w1h: 0)
        let file = try write("main.jsonl", [
            record("m1", model: opus, stop: "end_turn", input: 1, output: 20, cacheRead: 200, w5m: 0,
                   iterations: [first, last]),
        ])
        let report = await report([file])

        XCTAssertEqual(report.dayModels.map(\.model), [opus])
        XCTAssertEqual(counts(report), TokenCounts(input: 2, output: 30, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 300))
    }

    /// An iteration that counted nothing leaves no empty row for its model.
    func testIterationThatCountedNothingLeavesNoRow() async throws {
        let empty = Iteration(model: fable, input: 0, output: 0, cacheRead: 0, w5m: 0, w1h: 0)
        let fallback = Iteration(model: opus, input: 2, output: 50, cacheRead: 1_000, w5m: 0, w1h: 0)
        let file = try write("main.jsonl", [
            record("m1", model: opus, stop: "end_turn", output: 50, w5m: 0, iterations: [empty, fallback]),
        ])
        let report = await report([file])

        XCTAssertEqual(report.dayModels.map(\.model), [opus])
    }

    /// More iterations than a record is ever split into reads as the top
    /// level alone.
    func testOverlongIterationListFallsBackToTheTopLevel() async throws {
        let one = Iteration(model: fable, input: 1, output: 1, cacheRead: 1, w5m: 0, w1h: 0)
        let file = try write("main.jsonl", [
            record("m1", model: opus, stop: "end_turn", output: 70,
                   iterations: Array(repeating: one, count: ClaudeJSONLScanner.maxIterations + 1)),
        ])
        let report = await report([file])

        XCTAssertEqual(report.dayModels.map(\.model), [opus])
        XCTAssertEqual(counts(report).output, 70)
    }

    /// Ranking reads a record's whole output, earlier iterations included,
    /// not just the last call the top level repeats.
    func testRankingCountsEveryIterationsOutput() async throws {
        let attempt = Iteration(model: fable, input: 1, output: 100, cacheRead: 10, w5m: 0, w1h: 0)
        let last = Iteration(model: opus, input: 1, output: 5, cacheRead: 10, w5m: 0, w1h: 0)
        let file = try write("agent-a.jsonl", [
            record("m1", model: opus, input: 1, output: 5, cacheRead: 10, w5m: 0, iterations: [attempt, last]),
            record("m1", model: opus, input: 1, output: 50, cacheRead: 10, w5m: 0),
        ])
        let report = await report([file])

        XCTAssertEqual(counts(report).output, 105, "100 + 5 outranks 50")
        XCTAssertEqual(counts(report, model: fable).output, 100)
    }

    // MARK: - Across files

    /// A fork or worktree store copies a transcript's prefix into another
    /// file. Whichever file sorts first, the request counts once, from the
    /// copy that outranks the other.
    func testRequestInTwoFilesCountsOnceFromTheBetterCopy() async throws {
        let partial = record("m1", output: 4)
        let final = record("m1", stop: "tool_use", output: 900)
        for (first, second, name) in [(partial, final, "partial file sorts first"), (final, partial, "final file sorts first")] {
            let sub = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let a = try write("\(sub.lastPathComponent)/a.jsonl", [first])
            let b = try write("\(sub.lastPathComponent)/b.jsonl", [second])
            let report = await report([b, a])
            XCTAssertEqual(counts(report).output, 900, name)
            XCTAssertEqual(counts(report).cacheRead, 1_000, "\(name): counted once")
            XCTAssertEqual(report.requestFinality[today]?.final, 1, name)
        }
    }

    /// Two equally good copies that disagree (never seen in real data): the
    /// earlier file in path order wins, on every launch and in either order
    /// the files are listed.
    func testTieBetweenFilesGoesToTheEarlierPath() async throws {
        let a = try write("a.jsonl", [record("m1", stop: "end_turn", output: 100)])
        let b = try write("b.jsonl", [record("m1", stop: "end_turn", output: 200)])
        let forward = await report([a, b])
        let backward = await report([b, a])
        XCTAssertEqual(counts(forward).output, 100)
        XCTAssertEqual(counts(backward).output, 100)
    }

    /// No request is shared between a main transcript and its subagents'
    /// (checked over the whole corpus); each counts once, and the subagent's
    /// counts are its final records'.
    func testMainAndSubagentTranscriptsEachCountTheirOwnRequestsOnce() async throws {
        let main = try write("s1.jsonl", [
            record("m1", stop: "tool_use", output: 300),
            record("m1", stop: "tool_use", output: 300),
        ])
        let sub = try write("s1/subagents/agent-a1.jsonl", [
            record("m9", model: opus, output: 6),
            record("m9", model: opus, stop: "end_turn", output: 2_000),
        ])
        let workflow = try write("s1/subagents/workflows/run-1/agent-w1.jsonl", [
            record("m7", output: 9),
        ])
        let report = await report([main, sub, workflow])

        XCTAssertEqual(counts(report, model: sonnet).output, 300 + 9)
        XCTAssertEqual(counts(report, model: opus).output, 2_000)
        XCTAssertEqual(report.requestFinality[today], RequestFinalityCounts(final: 2, partial: 1, zeroed: 0, partialOutput: 9))
    }

    // MARK: - Across midnight

    /// A subagent request streams its first record at 23:59:50 and closes at
    /// 00:00:10. A windowed scan between the two counts it on day D; the next
    /// one must not move it to D+1, or the spend ledger — which a windowed
    /// scan can only raise — keeps it on D as well. It stays on D, through a
    /// resumed parse in the same process and after a restart.
    func testRequestClosingAfterMidnightStaysOnTheDayItStarted() async throws {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date().addingTimeInterval(-2 * 86_400))
        let dayD = cal.startOfDay(for: midnight.addingTimeInterval(-10))
        let file = try write("agent-midnight.jsonl", [
            record("m1", model: opus, input: 2, output: 4, cacheRead: 180_000, w5m: 0,
                   at: midnight.addingTimeInterval(-10)),
        ])
        let store = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: store))
        let table = PriceTable()
        func windowed(_ cache: ClaudeUsageCache) async -> UsageReport {
            await ClaudeJSONLScanner.usageReport(files: [file], completeHistory: false, cache: cache)
        }

        let before = await windowed(cache)
        XCTAssertEqual(before.dayModels.map(\.day), [dayD])
        var ledger = LifetimeSpendTracker.merge(existing: [], reports: [before], table: table)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((record("m1", model: opus, stop: "tool_use", input: 2, output: 700, cacheRead: 180_000,
                                                 w5m: 0, at: midnight.addingTimeInterval(10)) + "\n").utf8))
        try handle.close()

        let restarted = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: store))
        for (name, cache) in [("same process", cache), ("after restart", restarted)] {
            let after = await windowed(cache)
            XCTAssertEqual(after.dayModels.map(\.day), [dayD], "\(name): the request keeps its day")
            XCTAssertEqual(after.dayModels.first?.counts.output, 700, "\(name): with the final record's counts")
        }
        let after = await windowed(cache)
        ledger = LifetimeSpendTracker.merge(existing: ledger, reports: [after], table: table)
        XCTAssertEqual(ledger.reduce(0) { $0 + $1.tokens }, 2 + 700 + 180_000, "the ledger holds the request once")

        let fresh = await report([file])
        XCTAssertEqual(fresh.dayModels.map(\.day), [dayD], "a parse from the top files it the same way")

        // The history's times agree: first seen before midnight (day D),
        // final at the final record's own time, through the store.
        let stored = await ClaudeUsageCacheStore(directory: store).entry(for: file.path)
        let record = try XCTUnwrap(stored?.value.keyed.first)
        XCTAssertEqual(record.stamp.first, HistoryTime.ms(midnight.addingTimeInterval(-10)))
        XCTAssertEqual(record.stamp.finalMs, HistoryTime.ms(midnight.addingTimeInterval(10)))
        XCTAssertEqual(cal.startOfDay(for: HistoryTime.date(ms: try XCTUnwrap(record.stamp.first))), dayD)
    }

    /// The same across files: a later file's final copy replaces an earlier
    /// file's streaming one but keeps the day that copy was counted on.
    func testCopyFromAnotherFileKeepsTheDayTheRequestWasFirstCountedOn() async throws {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date().addingTimeInterval(-2 * 86_400))
        let a = try write("a.jsonl", [record("m1", output: 4, at: midnight.addingTimeInterval(-10))])
        let b = try write("b.jsonl", [record("m1", stop: "end_turn", output: 700, at: midnight.addingTimeInterval(10))])

        let report = await report([a, b])

        XCTAssertEqual(report.dayModels.map(\.day), [cal.startOfDay(for: midnight.addingTimeInterval(-10))])
        XCTAssertEqual(counts(report).output, 700)
    }

    // MARK: - Real corpus (opt-in)

    /// Prints what the scan makes of the real `~/.claude` corpus, for a
    /// side-by-side check against an independent reference script. Read-only;
    /// nothing is cached on disk. Runs with `AGENTMETER_REAL_CORPUS_BENCH=1`.
    func testRealCorpusTotalsAndFinality() async throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_REAL_CORPUS_BENCH"] == "1" else {
            throw XCTSkip("set AGENTMETER_REAL_CORPUS_BENCH=1 to scan the real ~/.claude corpus (read-only)")
        }
        var files = ClaudeJSONLScanner.jsonlFiles()
        guard !files.isEmpty else { throw XCTSkip("no Claude logs on this machine") }
        // A fixed cutoff (epoch seconds) restricts the run to files last
        // written before it, so two builds can be compared on one file set.
        if let cutoff = ProcessInfo.processInfo.environment["AGENTMETER_REAL_CORPUS_QUIET_BEFORE"].flatMap(Double.init) {
            files = files.filter { (LogFileFingerprint.current(for: $0)?.modifiedAt ?? .infinity) < cutoff }
            print("[corpus] quiet before \(cutoff): \(files.count) files, \(files.reduce(Int64(0)) { $0 + (LogFileFingerprint.current(for: $1)?.size ?? 0) }) bytes")
        }
        let report = await report(files)
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        func window(_ days: Int?) -> (TokenCounts, RequestFinalityCounts) {
            let cutoff = days.flatMap { cal.date(byAdding: .day, value: -($0 - 1), to: startOfToday) }
            var counts = TokenCounts()
            for entry in report.dayModels where cutoff.map({ entry.day >= $0 }) ?? true {
                counts.add(entry.counts)
            }
            var finality = RequestFinalityCounts()
            for (day, value) in report.requestFinality where cutoff.map({ day >= $0 }) ?? true {
                finality.add(value)
            }
            return (counts, finality)
        }
        for (label, days) in [("all", nil), ("30d", 30), ("7d", 7), ("1d", 1)] as [(String, Int?)] {
            let (c, f) = window(days)
            print("[corpus] \(label): input \(c.input) output \(c.output) cacheRead \(c.cacheRead) 5m \(c.cacheWrite5m) 1h \(c.cacheWrite1h)"
                  + " | requests final \(f.final) partial \(f.partial) zeroed \(f.zeroed) partialOutput \(f.partialOutput)")
        }
    }
}
