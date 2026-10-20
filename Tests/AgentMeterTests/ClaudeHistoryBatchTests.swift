import Foundation
@testable import AgentMeter
import XCTest

/// What a usage scan hands the history: one `HistoryScanBatch` per scan, a
/// file batch per listed file whose read did not fail, the committed state
/// only, and — for a resumed parse — a delta that holds every request whose
/// observation changed. Applying base + delta must always give what a parse
/// from the top gives, at every point a scan can stop.
final class ClaudeHistoryBatchTests: XCTestCase {
    private typealias F = TranscriptFixture
    private var root: URL!
    private var logs: URL!
    private var cacheDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-history-batch-\(UUID().uuidString)", isDirectory: true)
        logs = root.appendingPathComponent("logs", isDirectory: true)
        cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Undo any chmod a test left, so the directory can be removed.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: logs.path) {
            for name in names { chmod(logs.appendingPathComponent(name).path, 0o644) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func persistentCache(at dir: URL? = nil) -> ClaudeUsageCache {
        ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: dir ?? cacheDir))
    }

    private func snapshotCacheDir() throws -> URL {
        let copy = root.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: cacheDir, to: copy)
        return copy
    }

    private func scan(_ files: [URL], cache: ClaudeUsageCache, sink: RecordingHistorySink,
                      completeHistory: Bool = true) async -> (UsageReport, HistoryScanBatch) {
        let report = await ClaudeJSONLScanner.usageReport(files: files, completeHistory: completeHistory,
                                                          cache: cache, history: sink)
        return (report, sink.lastScan!)
    }

    /// A parse of the whole file from the top, through a cache that never saw it.
    private func fresh(_ url: URL) async throws -> HistoryFileBatch {
        let sink = RecordingHistorySink()
        _ = await ClaudeJSONLScanner.usageReport(files: [url], completeHistory: false,
                                                 cache: ClaudeUsageCache(store: nil), history: sink)
        return try XCTUnwrap(sink.lastScan?.file(url))
    }

    private func dictionary(_ requests: [RequestObservation]) -> [DedupKey: RequestObservation] {
        Dictionary(requests.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: - The fixture: every record kind the scan reads

    private let t0 = F.base

    /// Partial → final across local midnight, a zeroed replay, same-file
    /// replays under another version and cwd, a two-iteration record,
    /// records without a timestamp, 429s in both forms, `/usage` in all
    /// three shapes, cost states, replayed compactions, an unkeyed record,
    /// both timestamp forms, and records that change a held key's stamp
    /// without standing (earlier zeroed replay, later partial, a fast flag).
    private func goldenLines() -> [String] {
        let midnight = HistoryTime.ms(Calendar.current.startOfDay(for: Date().addingTimeInterval(-2 * 86_400)))
        let t = t0
        return [
            F.title(),
            F.user(uuid: "u0", ts: F.iso24(t)),
            F.compactBoundary(uuid: "cb1", ts: F.iso24(t + 10)),
            F.assistant(uuid: "a1", ts: F.iso24(midnight - 516), mid: "msg_k1", rid: "req_k1",
                        counts: .init(output: 4), sidechain: true),
            F.assistant(uuid: "a2", ts: F.iso20(t + 1_000), mid: "msg_k2", rid: "req_k2", stop: "end_turn",
                        version: "2.1.300", thinking: 12),
            F.synthetic429(uuid: "q1", ts: F.iso24(t + 1_500), rid: "req_q1", form: .quotaLimits),
            F.assistant(uuid: "a3", ts: F.iso24(midnight + 325), mid: "msg_k1", rid: "req_k1", stop: "tool_use",
                        counts: .init(output: 700), sidechain: true),
            F.usageCommand(uuid: "r1", ts: F.iso24(t + 2_000), shape: .rateLimitsNull),
            F.assistant(uuid: "a4", ts: F.iso24(t + 3_000), mid: "msg_k3", rid: "req_k3", model: "claude-opus-4-8",
                        stop: "tool_use", counts: .init(input: 8, output: 16_315, cacheRead: 810_092, w5m: 548),
                        iterations: [("claude-fable-5-1", .init(input: 8, output: 7_804, cacheRead: 1_018_342, w5m: 548)),
                                     ("claude-opus-4-8", .init(input: 8, output: 16_315, cacheRead: 810_092, w5m: 6_140))]),
            F.assistant(uuid: "a2", ts: F.iso20(t + 1_000), mid: "msg_k2", rid: "req_k2", stop: "end_turn",
                        version: "2.1.301", cwd: "/Users/dev/other", thinking: 12),
            F.costState(start: 1_791_000_000_000, total: 1_000),
            F.compactBoundary(uuid: "cb1", ts: F.iso24(t + 10)),
            F.assistant(uuid: "a5", ts: nil, mid: "msg_k4", rid: "req_k4", stop: "end_turn"),
            F.synthetic429(uuid: "q2", ts: F.iso24(t + 4_000), rid: "req_q2", form: .rateLimitInfo),
            F.usageCommand(uuid: "r2", ts: F.iso24(t + 4_500), shape: .limitsNull),
            F.assistant(uuid: "a6", ts: F.iso24(t + 60_000), mid: "msg_k2", rid: "req_k2", stop: "end_turn",
                        zeroed: true, version: "2.1.301"),
            F.assistant(uuid: "a7", ts: F.iso24(t + 5_000), mid: "msg_k5", rid: "req_k5", counts: .init(output: 2),
                        aborted: true),
            F.assistant(uuid: "a8", ts: F.iso24(t + 5_500), mid: "msg_k5", rid: "req_k5", counts: .init(output: 30),
                        speed: "fast"),
            F.usageCommand(uuid: "r3", ts: F.iso20(t + 6_000), shape: .threeLimits),
            F.costState(start: 1_791_000_000_000, total: 9_000),
            F.compactBoundary(uuid: "cb2", ts: F.iso20(t + 7_000), trigger: "auto"),
            F.assistant(uuid: "a9", ts: F.iso24(t - 86_400_000), mid: "msg_k6", rid: "req_k6", stop: "end_turn"),
            // Does not stand, but lowers k1's first time.
            F.assistant(uuid: "a10", ts: F.iso24(midnight - 9_000), mid: "msg_k1", rid: "req_k1", stop: "tool_use",
                        zeroed: true),
            // Does not stand, but raises k2's last time.
            F.assistant(uuid: "a11", ts: F.iso24(t + 70_000), mid: "msg_k2", rid: "req_k2", counts: .init(output: 1)),
            // Does not stand, but sets k3's fast flag.
            F.assistant(uuid: "a12", ts: F.iso24(t + 3_000), mid: "msg_k3", rid: "req_k3", stop: "tool_use",
                        counts: .init(output: 2), speed: "fast"),
            #"{"parentUuid":null,"type":"assistant","timestamp":"\#(F.iso24(t + 8_000))","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            F.compactBoundary(uuid: "cb2", ts: F.iso20(t + 7_000), trigger: "auto"),
            F.synthetic429(uuid: "q1", ts: F.iso24(t + 1_500), rid: "req_q1", form: .quotaLimits),
            F.assistant(uuid: "a13", ts: nil, mid: "msg_k4", rid: "req_k4", stop: "end_turn", speed: "fast"),
        ]
    }

    /// The whole file parsed from the top: what every resumed path must reach.
    private func reference(_ lines: [String], name: String) async throws -> (HistoryFileBatch, ClaudeFileUsage) {
        let url = root.appendingPathComponent("reference-\(name).jsonl")
        try F.write(lines, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let full = try await fresh(url)
        let fingerprint = try XCTUnwrap(LogFileFingerprint.current(for: url))
        let scan = await ClaudeJSONLScanner.cachedUsage(in: url, fingerprint: fingerprint,
                                                        cache: ClaudeUsageCache(store: nil), scan: 1)
        XCTAssertEqual(scan.usage.keyed, F.parse(lines).keyed, "the file parse is the line parse")
        return (full, scan.usage)
    }

    // MARK: - Resume equivalence

    /// For every line boundary: parse up to it, append the rest, scan again
    /// (same process, and after a restart). The stored entry, every request
    /// and every event equal a single parse from the top, and the history,
    /// fed the first batch and then the second, holds exactly what one
    /// whole ingest of the full file holds.
    func testEverySplitPointResumesToTheSameEntry() async throws {
        let lines = goldenLines()
        let (full, fullUsage) = try await reference(lines, name: "golden")
        let fullRequests = dictionary(full.allRequests())
        XCTAssertEqual(fullRequests.count, 6, "k1…k6")
        XCTAssertEqual(full.events.limitEvents.count, 2)
        XCTAssertEqual(full.events.usageReports.count, 3)
        XCTAssertEqual(full.events.costStates.count, 2)
        XCTAssertEqual(full.events.compactEvents.count, 2)
        XCTAssertEqual(fullUsage.unkeyed.count, 1)

        let url = logs.appendingPathComponent("\(F.session).jsonl")
        for split in 0...lines.count {
            try? FileManager.default.removeItem(at: cacheDir)
            try F.write(Array(lines[..<split]), to: url)
            let cache = persistentCache()
            let sink = RecordingHistorySink()
            let (_, first) = await scan([url], cache: cache, sink: sink)
            var history = ReferenceIngest()
            history.apply(try XCTUnwrap(first.file(url)))
            let snapshot = try snapshotCacheDir()

            try F.append(lines[split...].map { $0 + "\n" }.joined(), to: url)
            for (name, cache) in [("same process", cache), ("after restart", persistentCache(at: snapshot))] {
                let label = "split \(split), \(name)"
                let (_, second) = await scan([url], cache: cache, sink: sink)
                let batch = try XCTUnwrap(second.file(url), label)
                XCTAssertEqual(dictionary(batch.allRequests()), fullRequests, label)
                XCTAssertEqual(batch.events, full.events, label)
                XCTAssertEqual(batch.watermark.parsedBytes, full.watermark.parsedBytes, label)
                XCTAssertEqual(batch.watermark.boundaryDigest, full.watermark.boundaryDigest, label)
                let entry = await cache.store?.entry(for: url.path)
                XCTAssertTrue(entry?.value == fullUsage, "\(label): stored entry")
                if split < lines.count {
                    XCTAssertNotNil(batch.delta, "\(label): a resumed parse carries a delta")
                }
                var fed = history
                fed.apply(batch)
                XCTAssertEqual(fed.requests, fullRequests, "\(label): base + delta")
                if split < lines.count {
                    XCTAssertEqual(fed.deltasApplied, 1, "\(label): the delta applied on its base")
                }
            }
        }
    }

    /// An unterminated half line between two scans: shown, never committed,
    /// and the resume from the line boundary before it ends where a parse
    /// from the top does.
    func testSplitInsideALineResumesToTheSameEntry() async throws {
        let lines = goldenLines()
        let (full, fullUsage) = try await reference(lines, name: "half")
        let fullRequests = dictionary(full.allRequests())
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        let body = lines.map { $0 + "\n" }.joined()
        var offset = 0
        for line in lines {
            let cut = offset + line.utf8.count / 2
            offset += line.utf8.count + 1
            try? FileManager.default.removeItem(at: cacheDir)
            let bytes = Array(body.utf8)
            try Data(bytes[..<cut]).write(to: url)
            let cache = persistentCache()
            let sink = RecordingHistorySink()
            let (_, first) = await scan([url], cache: cache, sink: sink)
            let firstBatch = try XCTUnwrap(first.file(url))
            XCTAssertLessThan(firstBatch.watermark.parsedBytes, Int64(cut), "the half line is not committed")
            var history = ReferenceIngest()
            history.apply(firstBatch)
            try Data(bytes[cut...]).write(to: url.appendingPathExtension("rest"))
            try F.append(String(decoding: bytes[cut...], as: UTF8.self), to: url)
            let (_, second) = await scan([url], cache: cache, sink: sink)
            let batch = try XCTUnwrap(second.file(url))
            XCTAssertEqual(dictionary(batch.allRequests()), fullRequests, "cut at \(cut)")
            let entry = await cache.store?.entry(for: url.path)
            XCTAssertTrue(entry?.value == fullUsage, "cut at \(cut): stored entry")
            history.apply(batch)
            XCTAssertEqual(history.requests, fullRequests, "cut at \(cut): base + delta")
            try? FileManager.default.removeItem(at: url.appendingPathExtension("rest"))
        }
    }

    func testStampsAndExtrasSurviveRestart() async throws {
        let lines = goldenLines()
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        try F.write(lines, to: url)
        let (_, first) = await scan([url], cache: persistentCache(), sink: RecordingHistorySink())
        let restarted = persistentCache()
        let (_, second) = await scan([url], cache: restarted, sink: RecordingHistorySink())
        let stats = await restarted.stats.snapshot()
        XCTAssertEqual(stats.filesOpened, 0)
        XCTAssertEqual(stats.storeHits, 1)
        let a = try XCTUnwrap(first.file(url)), b = try XCTUnwrap(second.file(url))
        XCTAssertEqual(b.allRequests(), a.allRequests())
        XCTAssertEqual(b.events, a.events)
        XCTAssertEqual(b.watermark, a.watermark)
        XCTAssertTrue(b.allRequests().contains { $0.firstMs != nil && $0.lastMs != nil && $0.finalMs != nil && $0.ccVersion != nil })
    }

    // MARK: - Delta and watermark

    func testDeltaHoldsExactlyTheNewAndChangedRecords() async throws {
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        let k1 = DedupKey(messageID: "m1", requestID: "r1"), k2 = DedupKey(messageID: "m2", requestID: "r2")
        let k3 = DedupKey(messageID: "m3", requestID: "r3")
        try F.write([
            F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", counts: .init(output: 3)),
            F.assistant(uuid: "b", ts: F.iso24(t0 + 10), mid: "m2", rid: "r2", stop: "end_turn"),
        ], to: url)
        let cache = persistentCache()
        let sink = RecordingHistorySink()
        _ = await scan([url], cache: cache, sink: sink)
        try F.append([
            F.assistant(uuid: "c", ts: F.iso24(t0 + 20), mid: "m1", rid: "r1", stop: "end_turn"),
            F.assistant(uuid: "d", ts: F.iso24(t0 + 30), mid: "m3", rid: "r3", stop: "end_turn"),
            F.assistant(uuid: "b", ts: F.iso24(t0 + 10), mid: "m2", rid: "r2", stop: "end_turn"),   // replay, same time
        ].map { $0 + "\n" }.joined(), to: url)
        let (_, second) = await scan([url], cache: cache, sink: sink)
        let delta = try XCTUnwrap(second.file(url)?.delta)
        XCTAssertEqual(delta.requests.map(\.key), [k1, k3], "replaced and new; an unchanged replay is not sent")

        try F.append(F.assistant(uuid: "e", ts: F.iso24(t0 + 5), mid: "m2", rid: "r2", stop: "end_turn") + "\n", to: url)
        let (_, third) = await scan([url], cache: cache, sink: sink)
        let lowered = try XCTUnwrap(third.file(url)?.delta)
        XCTAssertEqual(lowered.requests.map(\.key), [k2], "a copy with an earlier time lowers the first time")
        XCTAssertEqual(lowered.requests.first?.firstMs, t0 + 5)
        XCTAssertEqual(lowered.requests.first?.finalMs, t0 + 10, "the standing record's own final time stays")
    }

    /// A record that does not stand but raises the last time changes the observation, so
    /// it must be in the delta although `ParseState.add` says "not counted".
    func testStampOnlyChangeIsInTheDelta() async throws {
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        let k1 = DedupKey(messageID: "m1", requestID: "r1")
        try F.write([F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn")], to: url)
        let cache = persistentCache()
        let sink = RecordingHistorySink()
        let (_, first) = await scan([url], cache: cache, sink: sink)
        var history = ReferenceIngest()
        history.apply(try XCTUnwrap(first.file(url)))

        let later = F.assistant(uuid: "b", ts: F.iso24(t0 + 40_000), mid: "m1", rid: "r1", counts: .init(output: 1))
        var probe = ClaudeJSONLScanner.ParseState(resuming: F.parse([
            F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn"),
        ]))
        let object = try XCTUnwrap(JSONLLineReader.withLine(Data(later.utf8)) { $0.jsonObject() })
        XCTAssertFalse(ClaudeJSONLScanner.consume(object: object, into: &probe, calendar: .current), "it does not count")

        try F.append(later + "\n", to: url)
        let (_, second) = await scan([url], cache: cache, sink: sink)
        let batch = try XCTUnwrap(second.file(url))
        XCTAssertEqual(batch.delta?.requests.map(\.key), [k1])
        XCTAssertEqual(batch.delta?.requests.first?.lastMs, t0 + 40_000)
        XCTAssertEqual(batch.delta?.requests.first?.finalMs, t0)
        history.apply(batch)
        XCTAssertEqual(history.deltasApplied, 1)
        XCTAssertEqual(history.requests[k1]?.lastMs, t0 + 40_000)

        // A flag alone is a change too.
        try F.append(F.assistant(uuid: "c", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn", speed: "fast") + "\n", to: url)
        let (_, third) = await scan([url], cache: cache, sink: sink)
        XCTAssertEqual(third.file(url)?.delta?.requests.map(\.flags), [.fast])
    }

    func testNoDeltaForMemoryStoreAndFromTopScans() async throws {
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        try F.write(goldenLines(), to: url)
        let cache = persistentCache()
        let sink = RecordingHistorySink()
        let (_, cold) = await scan([url], cache: cache, sink: sink)
        XCTAssertNil(try XCTUnwrap(cold.file(url)).delta, "from the top")
        let (_, memory) = await scan([url], cache: cache, sink: sink)
        XCTAssertNil(try XCTUnwrap(memory.file(url)).delta, "memory hit")
        let (_, store) = await scan([url], cache: persistentCache(), sink: sink)
        XCTAssertNil(try XCTUnwrap(store.file(url)).delta, "store hit")
        XCTAssertEqual(memory.file(url)?.watermark, cold.file(url)?.watermark)
        XCTAssertEqual(store.file(url)?.watermark, cold.file(url)?.watermark)
        // Rewritten in place, shorter: parsed from the top again.
        try F.write(Array(goldenLines().prefix(5)), to: url)
        let (_, rewritten) = await scan([url], cache: cache, sink: sink)
        let batch = try XCTUnwrap(rewritten.file(url))
        XCTAssertNil(batch.delta)
        let reparsed = try await fresh(url)
        XCTAssertEqual(dictionary(batch.allRequests()), dictionary(reparsed.allRequests()))
    }

    func testReadFailureSubmitsNothing() async throws {
        let a = logs.appendingPathComponent("a.jsonl"), b = logs.appendingPathComponent("b.jsonl")
        try F.write([F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn")], to: a)
        try F.write([F.assistant(uuid: "b", ts: F.iso24(t0), mid: "m2", rid: "r2", stop: "end_turn")], to: b)
        let cache = persistentCache()
        let sink = RecordingHistorySink()
        _ = await scan([a, b], cache: cache, sink: sink)
        try F.append(F.assistant(uuid: "c", ts: F.iso24(t0 + 1), mid: "m3", rid: "r3", stop: "end_turn") + "\n", to: a)
        XCTAssertEqual(chmod(a.path, 0o000), 0)
        let (_, failed) = await scan([a, b], cache: cache, sink: sink)
        XCTAssertNil(failed.file(a), "a failed read submits nothing for its file")
        XCTAssertNotNil(failed.file(b))
        XCTAssertEqual(failed.files.count, 1)
        XCTAssertFalse(failed.isCompleteHistory, "a complete scan that could not read a file is not complete coverage")
        // Also from a cold cache: no base, read fails, still nothing.
        let (_, coldFailed) = await scan([a, b], cache: ClaudeUsageCache(store: nil), sink: sink)
        XCTAssertNil(coldFailed.file(a))
        XCTAssertEqual(chmod(a.path, 0o644), 0)
        let (_, recovered) = await scan([a, b], cache: cache, sink: sink)
        XCTAssertEqual(recovered.file(a)?.allRequests().count, 2)
        XCTAssertTrue(recovered.isCompleteHistory)
        // A windowed scan is never complete, whatever happened.
        let (_, windowed) = await scan([a, b], cache: cache, sink: sink, completeHistory: false)
        XCTAssertFalse(windowed.isCompleteHistory)
    }

    func testAListedFileThatVanishedMakesACompleteScanIncomplete() async throws {
        let a = logs.appendingPathComponent("a.jsonl"), gone = logs.appendingPathComponent("gone.jsonl")
        try F.write([F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn")], to: a)
        let sink = RecordingHistorySink()
        let (_, batch) = await scan([a, gone], cache: ClaudeUsageCache(store: nil), sink: sink)
        XCTAssertEqual(batch.files.count, 1, "the vanished file has no batch")
        XCTAssertFalse(batch.isCompleteHistory)
        let (_, whole) = await scan([a], cache: ClaudeUsageCache(store: nil), sink: sink)
        XCTAssertTrue(whole.isCompleteHistory)
    }

    func testTrailingHalfLineIsNeverSubmitted() async throws {
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        let committed = F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn")
        let trailing = F.assistant(uuid: "b", ts: F.iso24(t0 + 1), mid: "m2", rid: "r2", stop: "end_turn")
        try Data((committed + "\n" + trailing).utf8).write(to: url)
        let sink = RecordingHistorySink()
        let (report, batchScan) = await scan([url], cache: persistentCache(), sink: sink)
        let batch = try XCTUnwrap(batchScan.file(url))
        XCTAssertEqual(batch.watermark.parsedBytes, Int64(committed.utf8.count + 1))
        XCTAssertLessThan(batch.watermark.parsedBytes, batch.watermark.size)
        XCTAssertEqual(batch.allRequests().map(\.key), [DedupKey(messageID: "m1", requestID: "r1")])
        XCTAssertEqual(report.requestFinality.values.reduce(0) { $0 + $1.final }, 2, "the report still counts it")
    }

    func testWatermarkMatchesTheStoreEntry() async throws {
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        try F.write(goldenLines(), to: url)
        let cache = persistentCache()
        let (_, batchScan) = await scan([url], cache: cache, sink: RecordingHistorySink())
        let watermark = try XCTUnwrap(batchScan.file(url)?.watermark)
        let stored = await cache.store?.entry(for: url.path)
        let entry = try XCTUnwrap(stored)
        XCTAssertEqual(watermark.fileID, entry.fingerprint.fileID)
        XCTAssertEqual(watermark.volumeID, entry.fingerprint.volumeID)
        XCTAssertEqual(watermark.size, entry.fingerprint.size)
        XCTAssertEqual(watermark.modifiedAt, entry.fingerprint.modifiedAt)
        XCTAssertEqual(watermark.parsedBytes, entry.parsedBytes)
        XCTAssertEqual(watermark.boundaryDigest, entry.value.boundaryDigest)
        XCTAssertEqual(watermark.parserVersion, Int(ClaudeUsageCacheStore.formatVersion))
        XCTAssertEqual(watermark.parserVersion, 4, "a parse with absolute stamp times")
        XCTAssertNotNil(watermark.fileID)
    }

    /// Bytes appended after the fingerprint was taken wait for the next
    /// scan: the stored entry never claims more than its fingerprint, so the
    /// next launch resumes it instead of throwing it away (it used to store
    /// `parsedBytes > size`, which every later decode rejected).
    func testReadStopsAtTheFingerprintedSize() async throws {
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        let first = F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn")
        try F.write([first], to: url)
        let stale = try XCTUnwrap(LogFileFingerprint.current(for: url))
        try F.append(F.assistant(uuid: "b", ts: F.iso24(t0 + 1), mid: "m2", rid: "r2", stop: "end_turn") + "\n", to: url)
        let cache = persistentCache()
        let fileScan = await ClaudeJSONLScanner.cachedUsage(in: url, fingerprint: stale, cache: cache, scan: 1)
        XCTAssertEqual(fileScan.parsedBytes, stale.size)
        XCTAssertEqual(fileScan.usage.keyed.count, 1, "the appended line is not read")
        let stored = await cache.store?.entry(for: url.path)
        let entry = try XCTUnwrap(stored, "the entry decodes")
        XCTAssertLessThanOrEqual(entry.parsedBytes, entry.fingerprint.size)

        let relaunched = persistentCache()
        _ = await ClaudeJSONLScanner.usageReport(files: [url], cache: relaunched)
        let stats = await relaunched.stats.snapshot()
        XCTAssertEqual(stats.fullParses, 0, "resumed, not reparsed from the top")
        XCTAssertEqual(stats.resumedParses, 1)
        let invalid = await relaunched.store?.statistics().invalidEntries
        XCTAssertEqual(invalid, 0)
    }

    // MARK: - The hook

    /// The history changes nothing the scan does: the same files opened, the
    /// same hits, the same bytes, the same report, at every step.
    func testScanStatsAreIdenticalWithAndWithoutHistory() async throws {
        let fm = FileManager.default
        let dirs = ["plain", "history"].map { root.appendingPathComponent($0, isDirectory: true) }
        for dir in dirs { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func files(_ dir: URL) -> [URL] {
            ["a.jsonl", "b.jsonl", "c.jsonl"].map { dir.appendingPathComponent($0) }
        }
        let lines = goldenLines()
        for dir in dirs {
            let f = files(dir)
            try F.write(Array(lines[0..<10]), to: f[0])
            try F.write(Array(lines[10..<20]), to: f[1])
            try F.write(Array(lines[20...]), to: f[2])
        }
        let caches = dirs.map { ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: $0.appendingPathComponent("cache"))) }
        let sink = RecordingHistorySink()
        var restarted = caches
        func step(_ name: String, complete: Bool = true, only: Int? = nil) async {
            var reports: [UsageReport] = []
            var snapshots: [ClaudeScanStats.Snapshot] = []
            for (i, dir) in dirs.enumerated() {
                let list = only.map { [files(dir)[$0]] } ?? files(dir)
                await restarted[i].stats.reset()
                reports.append(await ClaudeJSONLScanner.usageReport(
                    files: list, completeHistory: complete, cache: restarted[i], history: i == 1 ? sink : nil))
                snapshots.append(await restarted[i].stats.snapshot())
            }
            XCTAssertEqual(snapshots[0], snapshots[1], name)
            XCTAssertEqual(reports[0].dayModels, reports[1].dayModels, name)
            XCTAssertEqual(reports[0].requestFinality, reports[1].requestFinality, name)
        }
        await step("cold")
        for dir in dirs { try F.append(lines[3] + "\n" + lines[8] + "\n", to: files(dir)[0]) }
        await step("append")
        for dir in dirs {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: files(dir)[1].path)
        }
        await step("touch")
        for dir in dirs { try F.write(Array(lines[20..<23]), to: files(dir)[2]) }
        await step("truncate")
        restarted = dirs.map { ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: $0.appendingPathComponent("cache"))) }
        await step("restart")
        await step("windowed", complete: false, only: 1)
        XCTAssertEqual(sink.scans.count, 6)
    }

    func testReportReturnsWithoutWaitingForTheHistory() async throws {
        let url = logs.appendingPathComponent("\(F.session).jsonl")
        try F.write(goldenLines(), to: url)
        let sink = RecordingHistorySink(gated: true)
        let report = await ClaudeJSONLScanner.usageReport(files: [url], completeHistory: true,
                                                          cache: persistentCache(), history: sink)
        XCTAssertFalse(report.dayModels.isEmpty)
        XCTAssertTrue(sink.scans.isEmpty, "returned while the history had applied nothing")
        XCTAssertEqual(sink.pending.count, 1)
        sink.open()
        XCTAssertEqual(sink.scans.count, 1)
        XCTAssertEqual(sink.lastScan?.file(url)?.allRequests().count, 6)
    }

    /// A batch is plain data: building every request after the transcripts
    /// are gone reads nothing from disk.
    func testHistoryNeverOpensATranscript() async throws {
        let a = logs.appendingPathComponent("a.jsonl"), b = logs.appendingPathComponent("b.jsonl")
        let lines = goldenLines()
        try F.write(Array(lines[..<15]), to: a)
        try F.write(Array(lines[15...]), to: b)
        let expectedA = try await fresh(a), expectedB = try await fresh(b)
        let (_, batchScan) = await scan([a, b], cache: persistentCache(), sink: RecordingHistorySink())
        let wantA = expectedA.allRequests(), wantB = expectedB.allRequests()
        for url in [a, b] {
            XCTAssertEqual(chmod(url.path, 0o000), 0)
        }
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(batchScan.file(a)?.allRequests(), wantA)
        XCTAssertEqual(batchScan.file(b)?.allRequests(), wantB)
        XCTAssertEqual(batchScan.file(a)?.events, expectedA.events)
    }

    func testOneBatchPerListedFilePerScan() async throws {
        let names = ["a.jsonl", "b.jsonl", "c.jsonl", "d.jsonl"]
        let urls = names.map { logs.appendingPathComponent($0) }
        for (i, url) in urls.enumerated() {
            try F.write([F.assistant(uuid: "u\(i)", ts: F.iso24(t0 + Int64(i)), mid: "m\(i)", rid: "r\(i)", stop: "end_turn")], to: url)
        }
        let cache = persistentCache()
        let sink = RecordingHistorySink()
        let before = HistoryTime.ms(Date())
        _ = await ClaudeJSONLScanner.usageReport(files: urls, completeHistory: true, cache: cache, history: sink)
        _ = await ClaudeJSONLScanner.usageReport(files: [urls[2], urls[0]], completeHistory: false, cache: cache, history: sink)
        _ = await ClaudeJSONLScanner.usageReport(files: [], completeHistory: false, cache: cache, history: sink)
        let scans = sink.scans
        XCTAssertEqual(scans.count, 3, "one hand-off per scan")
        XCTAssertEqual(scans[0].files.map(\.path), urls.map(\.path))
        XCTAssertEqual(scans[1].files.map(\.path), [urls[0].path, urls[2].path], "only the windowed files, in path order")
        XCTAssertTrue(scans[2].files.isEmpty)
        XCTAssertEqual(scans.map(\.isCompleteHistory), [true, false, false])
        XCTAssertTrue(scans[0].ticket < scans[1].ticket && scans[1].ticket < scans[2].ticket)
        XCTAssertTrue(scans.allSatisfy { $0.startedMs >= before && $0.startedMs <= HistoryTime.ms(Date()) })
        XCTAssertTrue(scans[0].files.allSatisfy { $0.scan == scans[0].ticket })
    }

    /// Overlapping scans hand over batches in any order; per path, the
    /// newest ticket's batch is the file as a fresh parse sees it, and
    /// applying all of them in arrival order converges on that.
    func testConcurrentScansWithHistoryConvergeToTheFreshDump() async throws {
        let urls = (0..<3).map { logs.appendingPathComponent("s\($0).jsonl") }
        let lines = goldenLines()
        try F.write(Array(lines[..<10]), to: urls[0])
        try F.write(Array(lines[10..<20]), to: urls[1])
        try F.write(Array(lines[20...]), to: urls[2])
        let cache = persistentCache()
        let sink = RecordingHistorySink()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask {
                    _ = await ClaudeJSONLScanner.usageReport(files: urls, completeHistory: i % 2 == 0,
                                                             cache: cache, history: sink)
                }
            }
        }
        XCTAssertEqual(sink.scans.count, 6)
        for url in urls {
            let expected = try await fresh(url)
            var history = ReferenceIngest()
            for scan in sink.scans {
                let batch = try XCTUnwrap(scan.file(url))
                XCTAssertEqual(dictionary(batch.allRequests()), dictionary(expected.allRequests()), url.lastPathComponent)
                XCTAssertEqual(batch.events, expected.events)
                history.apply(batch)
            }
            XCTAssertEqual(history.requests, dictionary(expected.allRequests()))
        }
    }
}
