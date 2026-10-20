import Foundation
import os
import XCTest
@testable import AgentMeter

/// Scanner -> usage cache -> history, end to end. After every step the
/// store's logical dump must equal the dump of a FRESH store that ingested
/// the current transcripts in one cold complete scan (the stored rows depend
/// only on the contributions seen, never on the order or the schedule they
/// arrived in), and on these time-ordered fixtures the store's `acct_day` x
/// model sums must equal the scan's `UsageReport.dayModels`.
final class HistoryEndToEndTests: XCTestCase {
    typealias F = E2EFix

    /// After a step: dump == oracle, DB day x model == the report's.
    func check(_ lane: E2ELane, _ report: UsageReport, files: [URL]? = nil, _ label: String,
               file: StaticString = #filePath, line: UInt = #line) async throws {
        let got = try await lane.dump()
        let oracle = try await e2eOracle(lane.tree, files: files, timeZone: lane.timeZone, realBirth: lane.realBirth)
        e2eAssertDump(got, oracle.dump, label, file: file, line: line)
        e2eAssertDayModels(try await lane.dayModels(), report, label, file: file, line: line)
        let stats = await lane.store.statistics()
        XCTAssertEqual(stats.failedCommands, 0, "\(label): failed commands", file: file, line: line)
        XCTAssertEqual(stats.failedChunks, 0, "\(label): failed chunks", file: file, line: line)
        XCTAssertEqual(stats.skippedInvalidObservations, 0, "\(label): invalid observations", file: file, line: line)
        XCTAssertEqual(stats.skippedInvalidEvents, 0, "\(label): invalid events", file: file, line: line)
    }

    /// Main transcript + one subagent with every record shape the history
    /// reads: partial -> final, a 2-iteration fallback, a zeroed replay, a 429,
    /// a /usage report, a cost state and a compaction.
    func writeRichSession(_ tree: E2ETree) throws -> (main: URL, agent: URL) {
        let t = F.t0
        let main = tree.main()
        let agent = tree.subagent("a1b2c3")
        try tree.write([
            TranscriptFixture.title(),
            F.user(t),
            F.rec(1, t + 1_000, out: 3, final: false),
            F.rec(1, t + 2_000, out: 40, thinking: 12),
            F.rec(2, t + 3_000, out: 7, effort: "max"),
            F.rec(3, t + 4_000, iterations: [(F.fable, F.counts(5, input: 3)), (F.opus, F.counts(9, input: 4))]),
            F.rec(2, t + 3_000, out: 7, effort: "max"),             // same-file replay
            F.rec(1, t + 2_000, zeroed: true, version: "2.1.310"),  // zeroed replay, a newer CLI
            TranscriptFixture.usageCommand(uuid: "usage-1", ts: TranscriptFixture.iso24(t + 5_000), shape: .threeLimits),
            TranscriptFixture.compactBoundary(uuid: "compact-1", ts: TranscriptFixture.iso24(t + 6_000)),
            TranscriptFixture.compactBoundary(uuid: "compact-1", ts: TranscriptFixture.iso24(t + 6_000)),
            TranscriptFixture.costState(start: t - 60_000, total: 70_000),
        ], to: main)
        try tree.write([
            F.rec(10, t + 1_500, out: 2, final: false, model: F.sonnet, sidechain: true),
            F.rec(10, t + 2_500, out: 9, final: false, model: F.sonnet, sidechain: true),
            TranscriptFixture.synthetic429(uuid: "lim-1", ts: TranscriptFixture.iso24(t + 7_000), rid: "req_lim_1", form: .quotaLimits),
            TranscriptFixture.synthetic429(uuid: "lim-2", ts: TranscriptFixture.iso24(t + 8_000), rid: "req_lim_2", form: .rateLimitInfo),
        ], to: agent)
        return (main, agent)
    }

    // MARK: (a) cold full scan

    func testColdFullScanStoresEveryShapeAndMatchesAnIndependentCold() async throws {
        let tree = try e2eTree()
        let (main, agent) = try writeRichSession(tree)
        // Real st_birthtime here (every other test injects births).
        let lane = E2ELane(tree: tree, name: "a", realBirth: true)
        let report = await lane.scan()
        try await check(lane, report, "cold")

        let dump = try await lane.dump()
        XCTAssertEqual(Set(dump.requests.map(\.keyHex)).count, 4)
        XCTAssertEqual(dump.requests.count, 5, "the 2-iteration request has two rows")
        XCTAssertEqual(dump.files.map(\.path), [main.path, agent.path])
        XCTAssertEqual(dump.files.map(\.fileClass), [0, 1])
        XCTAssertNotNil(dump.files[0].birthMs, "real birth time read")
        XCTAssertEqual(dump.sessions.count, 1)
        XCTAssertEqual(dump.sessions[0].firstCwd, TranscriptFixture.cwd)
        XCTAssertEqual(dump.sessions[0].firstCwdMs, F.t0 + 1_000)
        let k1 = DedupKey(messageID: "msg_e2e_1", requestID: "req_e2e_1").historyHex
        let row1 = try XCTUnwrap(dump.requests.first { $0.keyHex == k1 })
        XCTAssertEqual(row1.output, 40)
        XCTAssertEqual(row1.finality, 2)
        XCTAssertEqual(row1.thinking, 12)
        XCTAssertEqual(row1.firstSeenMs, F.t0 + 1_000)
        XCTAssertEqual(row1.lastSeenMs, F.t0 + 2_000)
        XCTAssertEqual(row1.finalMs, F.t0 + 2_000)
        XCTAssertEqual(row1.ccVersion, "2.1.301", "the zeroed replay's newer version never stands")
        let k10 = DedupKey(messageID: "msg_e2e_10", requestID: "req_e2e_10").historyHex
        let row10 = try XCTUnwrap(dump.requests.first { $0.keyHex == k10 })
        XCTAssertEqual(row10.finality, 1)
        XCTAssertEqual(row10.output, 9, "partial-only: the record that streamed furthest")
        XCTAssertEqual(row10.ownerPath, agent.path)

        let stats = try await lane.store.historyStatistics()
        XCTAssertEqual(stats.rowCounts["limit_event"], 2)
        XCTAssertEqual(stats.rowCounts["usage_report_sample"], 1)
        XCTAssertEqual(stats.rowCounts["usage_report_limit"], 3)
        XCTAssertEqual(stats.rowCounts["cost_state_sample"], 1)
        XCTAssertEqual(stats.rowCounts["cost_state_model"], 2)
        XCTAssertEqual(stats.rowCounts["compact_event"], 1, "in-file replays of one compaction count once")
        XCTAssertTrue(dump.events.contains { $0.hasPrefix("L|") && $0.contains("\"quotaLimits\"") })
        XCTAssertTrue(dump.events.contains { $0.hasPrefix("L|") && $0.contains("\"rate_limit_info\"") })
        let complete = try await lane.store.withDatabase { try $0.metaInt("complete_scan_ms") }
        XCTAssertNotNil(complete)
        await lane.close()
    }

    // MARK: (b) windowed, then complete

    func testAWindowedScanThenACompleteOneEachEqualTheirColdOracle() async throws {
        let tree = try e2eTree()
        let (main, agent) = try writeRichSession(tree)
        let other = tree.main("1c4d6e2f-2222-4000-8000-00000000000b")
        try tree.write([F.rec(20, F.t0 + 9_000, out: 21, cwd: "/Users/dev/other"),
                        F.rec(21, F.t0 + 9_500, out: 22, model: F.sonnet, cwd: "/Users/dev/other")], to: other)
        let lane = E2ELane(tree: tree, name: "b")

        let windowed = await lane.scan([other, agent], complete: false)
        try await check(lane, windowed, files: [other, agent], "windowed")
        let noComplete = try await lane.store.withDatabase { try $0.metaInt("complete_scan_ms") }
        XCTAssertNil(noComplete, "a windowed scan never claims complete coverage")

        let complete = await lane.scan(complete: true)
        try await check(lane, complete, "complete after windowed")
        let dump = try await lane.dump()
        XCTAssertEqual(Set(dump.files.map(\.path)), [main.path, agent.path, other.path])
        XCTAssertEqual(dump.sessions.count, 2)
        await lane.close()
    }

    // MARK: (c) many incremental scans

    func testIncrementalScansWhileTranscriptsGrowEqualTheColdOracleAfterEveryStep() async throws {
        let tree = try e2eTree()
        let t = F.t0
        let midnight = F.localMidnight(dayOffset: 1)
        let main = tree.main()
        let agent = tree.subagent("a1b2c3")
        let lane = E2ELane(tree: tree, name: "c")

        // 1. A partial and a final; the agent streams a partial.
        try tree.write([TranscriptFixture.title(), F.user(t), F.rec(1, t + 1_000, out: 3, final: false),
                        F.rec(2, t + 1_500, out: 7)], to: main)
        try tree.write([F.rec(10, t + 1_200, out: 2, final: false, model: F.sonnet, sidechain: true)], to: agent)
        var report = await lane.scan()
        try await check(lane, report, "1 first scan")

        // 2. The partial gets its final; a new partial; the agent streams further. Windowed.
        try tree.append([F.rec(1, t + 2_000, out: 40, thinking: 5), F.rec(3, t + 3_000, out: 5, final: false)], to: main)
        try tree.append([F.rec(10, t + 2_500, out: 9, final: false, model: F.sonnet, sidechain: true)], to: agent)
        report = await lane.scan(complete: false)
        try await check(lane, report, "2 partial -> final, windowed")

        // 3. Same-file replay of a final, zeroed replay, a 2-iteration request.
        try tree.append([
            F.rec(2, t + 1_500, out: 7),
            F.rec(1, t + 2_000, zeroed: true, version: "2.1.310"),
            F.rec(4, t + 4_000, iterations: [(F.fable, F.counts(5)), (F.opus, F.counts(9, input: 4))]),
            F.rec(3, t + 3_500, out: 8, final: false, aborted: true),
        ], to: main)
        report = await lane.scan()
        try await check(lane, report, "3 replays + iterations")

        // 4. A request whose final lands after local midnight; the session's
        //    /usage, a 429 in the agent, a cost state and a compaction.
        try tree.append([
            F.rec(5, midnight - 30_000, out: 2, final: false),
            F.user(midnight - 10_000),
            F.rec(5, midnight + 30_000, out: 50),
            TranscriptFixture.usageCommand(uuid: "usage-1", ts: TranscriptFixture.iso24(midnight + 40_000), shape: .threeLimits),
            TranscriptFixture.costState(start: t, total: 1_000_000),
            TranscriptFixture.compactBoundary(uuid: "compact-1", ts: TranscriptFixture.iso24(midnight + 50_000)),
        ], to: main)
        try tree.append([
            TranscriptFixture.synthetic429(uuid: "lim-1", ts: TranscriptFixture.iso24(midnight + 45_000), rid: "req_lim_1", form: .both),
        ], to: agent)
        report = await lane.scan()
        try await check(lane, report, "4 midnight final + events")
        let k5 = DedupKey(messageID: "msg_e2e_5", requestID: "req_e2e_5").historyHex
        let dump4 = try await lane.dump()
        let row5 = try XCTUnwrap(dump4.requests.first { $0.keyHex == k5 })
        XCTAssertEqual(row5.acctDay, e2eDayNumber(HistoryTime.date(ms: midnight - 30_000)), "the first record's day")

        // 5. Nothing changed: no transcript opened. A windowed scan writes
        //    nothing at all; a complete one only its coverage row.
        let before = try await lane.totalChanges()
        let chunksBefore = await lane.store.statistics().committedChunks
        let dumpBefore = try await lane.dump()
        let opened = await lane.scanStats().filesOpened
        report = await lane.scan(complete: false)
        let after = try await lane.totalChanges()
        let openedAfter = await lane.scanStats().filesOpened
        let chunksAfter = await lane.store.statistics().committedChunks
        XCTAssertEqual(openedAfter, opened, "no transcript opened")
        XCTAssertEqual(after - before, 0, "an unchanged windowed scan writes nothing")
        XCTAssertEqual(chunksAfter, chunksBefore, "no file chunk written")
        e2eAssertDump(try await lane.dump(), dumpBefore, "5 unchanged")
        let rowsBefore = try await lane.store.withDatabase { try $0.conn.queryInt("SELECT count(*) FROM ingest_scan") }
        report = await lane.scan(complete: true)
        // The scan only queued its batch: without the barrier this read can
        // reach the store before the drain does (seen under load).
        await lane.store.flush()
        let rowsAfter = try await lane.store.withDatabase { try $0.conn.queryInt("SELECT count(*) FROM ingest_scan") }
        XCTAssertEqual(rowsAfter, rowsBefore.map { $0 + 1 }, "an unchanged complete scan records its coverage row")
        try await check(lane, report, "5 unchanged")

        // 6. A new workflow agent file and more growth, windowed.
        let wf = tree.workflowAgent("w9", run: "run-1")
        try tree.write([F.rec(30, midnight + 60_000, out: 4, final: false, model: F.sonnet, sidechain: true),
                        F.rec(30, midnight + 61_000, out: 11, model: F.sonnet, sidechain: true)], to: wf)
        try tree.append([F.rec(6, midnight + 70_000, out: 6)], to: main)
        report = await lane.scan(complete: false)
        try await check(lane, report, "6 new workflow file")
        let classes = Set(try await lane.dump().files.map(\.fileClass))
        XCTAssertEqual(classes, [0, 1, 2])

        // 7. Incremental after a partial line was visible (half a record at the end).
        let half = F.rec(7, midnight + 80_000, out: 12)
        try TranscriptFixture.append(String(half.prefix(half.count / 2)), to: main)
        report = await lane.scan()
        try await check(lane, report, "7 trailing half line is not ingested")
        let k7 = DedupKey(messageID: "msg_e2e_7", requestID: "req_e2e_7").historyHex
        let dump7 = try await lane.dump()
        XCTAssertFalse(dump7.requests.contains { $0.keyHex == k7 }, "never the trailing half line")
        try TranscriptFixture.append(String(half.dropFirst(half.count / 2)) + "\n", to: main)
        report = await lane.scan()
        try await check(lane, report, "8 the half line completed")
        let dump8 = try await lane.dump()
        XCTAssertTrue(dump8.requests.contains { $0.keyHex == k7 })
        await lane.close()
    }

    // MARK: (d) restart

    func testRestartingCacheAndStoreBetweenScansKeepsEveryStepEqualToTheOracle() async throws {
        let tree = try e2eTree()
        let (main, agent) = try writeRichSession(tree)
        let lane = E2ELane(tree: tree, name: "d")
        var report = await lane.scan()
        try await check(lane, report, "first")

        await lane.restart()
        let before = try await lane.totalChanges()
        report = await lane.scan()
        let restartStats = await lane.scanStats()
        XCTAssertEqual(restartStats.filesOpened, 0, "a warm restart opens no transcript")
        XCTAssertEqual(restartStats.storeHits, 2)
        let afterRestart = try await lane.totalChanges()
        XCTAssertLessThanOrEqual(afterRestart - before, 3, "unchanged after a restart: coverage only")
        try await check(lane, report, "restart, unchanged")

        try tree.append([F.rec(8, F.t0 + 20_000, out: 3, final: false), F.rec(8, F.t0 + 21_000, out: 33)], to: main)
        try tree.append([F.rec(10, F.t0 + 22_000, out: 15, final: false, model: F.sonnet, sidechain: true)], to: agent)
        await lane.restart()
        report = await lane.scan(complete: false)
        let resumed = await lane.scanStats()
        XCTAssertEqual(resumed.resumedParses, 2, "both grown files resumed from the stored entries")
        try await check(lane, report, "restart + append (delta on a restored base)")

        // Only the store restarts; the cache keeps its memory.
        try tree.append([F.rec(9, F.t0 + 30_000, out: 1)], to: main)
        await lane.restart(cache: false, store: true)
        report = await lane.scan()
        try await check(lane, report, "store restart only")
        // Only the cache restarts; the store keeps its tickets.
        try tree.append([F.rec(11, F.t0 + 31_000, out: 2)], to: main)
        await lane.restart(cache: true, store: false)
        report = await lane.scan()
        try await check(lane, report, "cache restart only")
        await lane.close()
    }

    /// Regression: tickets were per `LogFileParseCache`, so a cache recreated
    /// over the same directory (or a second cache) started again at 1 and the
    /// store, which still held the old cache's newer tickets for every path,
    /// dropped its batches as "older scans" until the new count caught up.
    func testANewUsageCacheFeedingALiveStoreIsNeverMistakenForAnOlderScan() async throws {
        let first = LogFileParseCache<Int>()
        let second = LogFileParseCache<Int>()
        let a = await first.beginScan()
        let b = await second.beginScan()
        let c = await first.beginScan()
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)

        let tree = try e2eTree()
        let main = tree.main()
        try tree.write([F.rec(1, F.t0, out: 1)], to: main)
        let lane = E2ELane(tree: tree, name: "tickets")
        for _ in 0..<5 { _ = await lane.scan() }
        try tree.append([F.rec(2, F.t0 + 1_000, out: 2)], to: main)
        await lane.restart(cache: true, store: false)
        let report = await lane.scan()
        await lane.store.flush()
        let skipped = await lane.store.statistics().skippedFileBatches
        XCTAssertEqual(skipped, 4, "only the four unchanged scans were skipped (equal watermark)")
        try await check(lane, report, "new cache, live store")
        await lane.close()
    }

    // MARK: (e) duplicate import

    func testTheSameBatchTwiceAndSwappedOverlappingScansChangeNothing() async throws {
        let tree = try e2eTree()
        let (main, _) = try writeRichSession(tree)
        let lane = E2ELane(tree: tree, name: "e")
        let tee = E2ETeeSink(lane.store)
        _ = await lane.scan(history: tee)
        try tree.append([F.rec(8, F.t0 + 20_000, out: 3, final: false), F.rec(8, F.t0 + 21_000, out: 33)], to: main)
        let report = await lane.scan(history: tee)
        try await check(lane, report, "two scans")
        let oracle = try await e2eOracle(tree)
        let (b1, b2) = (tee.scans[0], tee.scans[1])

        // The same batch again: equal watermark, nothing written but coverage.
        let before = try await lane.totalChanges()
        lane.store.submit(scan: b2)
        lane.store.submit(scan: b2)
        e2eAssertDump(try await lane.dump(), oracle.dump, "b2 twice")
        let afterDup = try await lane.totalChanges()
        XCTAssertLessThanOrEqual(afterDup - before, 6, "two coverage rows only")
        // The older batch in the same process: skipped by its ticket.
        let skipped = await lane.store.statistics().skippedFileBatches
        lane.store.submit(scan: b1)
        e2eAssertDump(try await lane.dump(), oracle.dump, "stale b1")
        let skippedAfter = await lane.store.statistics().skippedFileBatches
        XCTAssertEqual(skippedAfter, skipped + b1.files.count)
        // After a restart tickets are gone: b1 is applied whole (its watermark
        // moves back) and union semantics keep b2's rows; the next scan re-ingests whole.
        await lane.restart(cache: false, store: true)
        lane.store.submit(scan: b1)
        e2eAssertDump(try await lane.dump(), oracle.dump, "b1 after restart")
        _ = await lane.scan()
        e2eAssertDump(try await lane.dump(), oracle.dump, "scan after the watermark moved back")

        // Two overlapping scans landing in swapped order, into fresh stores.
        for (name, order) in [("swapped", [b2, b1]), ("in-order", [b1, b2]), ("dup", [b1, b2, b1, b2])] {
            let fresh = E2ELane(tree: tree, name: "e-\(name)")
            for batch in order { fresh.store.submit(scan: batch) }
            e2eAssertDump(try await fresh.dump(), oracle.dump, name)
            await fresh.close()
        }

        // Two scans really running at the same time on one cache.
        try tree.append([F.rec(12, F.t0 + 40_000, out: 4)], to: main)
        async let r1 = lane.scan()
        async let r2 = lane.scan(complete: false)
        _ = await (r1, r2)
        e2eAssertDump(try await lane.dump(), try await e2eOracle(tree).dump, "concurrent scans")
        await lane.close()
    }

    // MARK: (f) fork

    func testAForkCopyIsOwnedByTheEarlierBornFileWhateverThePathAndArrivalOrder() async throws {
        let tree = try e2eTree()
        let t = F.t0
        let main = tree.main()
        let mainLines = [
            F.user(t),
            F.rec(1, t + 1_000, out: 3, final: false),
            F.rec(1, t + 2_000, out: 40),
            F.rec(2, t + 3_000, out: 7, final: false),
            TranscriptFixture.synthetic429(uuid: "lim-m", ts: TranscriptFixture.iso24(t + 3_500), rid: "req_lim_1", form: .quotaLimits),
            F.rec(2, t + 4_000, out: 17),
        ]
        try tree.write(mainLines, to: main, birth: 1_780_000_000_000)
        // Forks re-stamp uuids, keep message ids, request ids and timestamps.
        // One sorts before the main file by path, one after; both born later.
        func fork(_ session: String, birth: Int64, own: Int) throws -> URL {
            let url = tree.main(session)
            try tree.write([
                F.user(t, tag: session),
                F.rec(1, t + 1_000, out: 3, final: false, tag: session),
                F.rec(1, t + 2_000, out: 40, version: "2.1.305", tag: session),
                F.rec(2, t + 3_000, out: 7, final: false, tag: session),
                TranscriptFixture.synthetic429(uuid: "lim-\(session)", ts: TranscriptFixture.iso24(t + 3_500), rid: "req_lim_1", form: .quotaLimits),
                F.rec(own, t + 50_000, out: 5, tag: session),
            ], to: url, birth: birth)
            return url
        }
        let before = try fork("00000000-0000-4000-8000-0000000000f1", birth: 1_780_000_060_000, own: 50)
        let after = try fork("ffffffff-0000-4000-8000-0000000000f2", birth: 1_780_000_120_000, own: 51)
        XCTAssertLessThan(before.path, main.path)
        XCTAssertGreaterThan(after.path, main.path)

        let oracle = try await e2eOracle(tree)
        let shared = Set(["msg_e2e_1|req_e2e_1", "msg_e2e_2|req_e2e_2"].map {
            let p = $0.split(separator: "|")
            return DedupKey(messageID: String(p[0]), requestID: String(p[1])).historyHex
        })
        for row in oracle.dump.requests where shared.contains(row.keyHex) {
            XCTAssertEqual(row.ownerPath, main.path, "owner = the earliest-born file, not the first path")
            XCTAssertEqual(row.ccVersion, "2.1.301", "attributes are the owner's")
        }
        XCTAssertEqual(oracle.dump.events.filter { $0.hasPrefix("L|") }.count, 1)
        XCTAssertTrue(oracle.dump.events.first { $0.hasPrefix("L|") }!.hasSuffix("\"\(main.path)\""),
                      "the 429's row belongs to the earliest-born copy")

        for (name, orders) in [("main-first", [[main], [main, before, after]]),
                               ("fork-first", [[before], [after], [main, before, after]]),
                               ("forks-then-main", [[after, before], [main]])] {
            let lane = E2ELane(tree: tree, name: "f-\(name)")
            var report = UsageReport.empty(.claude)
            for files in orders { report = await lane.scan(files, complete: files.count == 3) }
            e2eAssertDump(try await lane.dump(), oracle.dump, name)
            if orders.last!.count == 3 { e2eAssertDayModels(try await lane.dayModels(), report, name) }
            await lane.close()
        }
    }

    // MARK: (g) rewritten in place

    func testATranscriptRewrittenInPlaceKeepsTheUnionOfOldAndNew() async throws {
        let tree = try e2eTree()
        let t = F.t0
        let main = tree.main()
        let old = [
            F.user(t + 500),
            F.rec(1, t + 1_000, out: 3, final: false, cwd: "/Users/dev/old"),
            F.rec(2, t + 2_000, out: 7, cwd: "/Users/dev/old"),
            F.rec(3, t + 3_000, out: 30, cwd: "/Users/dev/old"),
            TranscriptFixture.usageCommand(uuid: "usage-old", ts: TranscriptFixture.iso24(t + 3_500), shape: .threeLimits),
            TranscriptFixture.costState(start: t, total: 9_000),
        ]
        let new = [
            F.rec(1, t + 900, out: 25, cwd: "/Users/dev/new"),     // the final, written earlier than the old partial
            F.rec(4, t + 4_000, out: 4, cwd: "/Users/dev/new"),
        ]
        try tree.write(old, to: main)
        let lane = E2ELane(tree: tree, name: "g")
        _ = await lane.scan()
        let inode = LogFileFingerprint.current(for: main)?.fileID
        try tree.rewriteInPlace(new, at: main)
        XCTAssertEqual(LogFileFingerprint.current(for: main)?.fileID, inode, "same inode")
        _ = await lane.scan()
        let got = try await lane.dump()

        var unions: [HistoryLogicalDump] = []
        for (name, order) in [("old-new", [old, new]), ("new-old", [new, old])] {
            let fresh = E2ELane(tree: tree, name: "g-\(name)")
            for (i, lines) in order.enumerated() {
                fresh.store.submit(scan: hmScan(UInt64(i + 1), [e2eManualBatch(path: main.path, lines: lines, ticket: UInt64(i + 1))]))
            }
            unions.append(try await fresh.dump())
            await fresh.close()
        }
        e2eAssertDump(unions[1], unions[0], "union is order-free")
        e2eAssertDump(got, unions[0], "rewritten in place == ingest(old) union ingest(new)")
        XCTAssertEqual(Set(got.requests.map(\.keyHex)).count, 4, "keys 2 and 3 of the old content are kept")
        XCTAssertEqual(got.sessions.first?.firstCwd, "/Users/dev/new", "the earliest first record over both contents")
        XCTAssertTrue(got.events.contains { $0.hasPrefix("U|") }, "the old /usage report is kept")
        await lane.close()
    }

    // MARK: (h) transcript deleted

    func testADeletedTranscriptKeepsItsRows() async throws {
        let tree = try e2eTree()
        let (_, agent) = try writeRichSession(tree)
        let lane = E2ELane(tree: tree, name: "h")
        _ = await lane.scan()
        let before = try await lane.dump()
        try FileManager.default.removeItem(at: agent)
        let report = await lane.scan()
        XCTAssertEqual(report.dayModels.contains { $0.model == F.sonnet }, false, "the report forgets the file")
        e2eAssertDump(try await lane.dump(), before, "deleted transcript, same process")
        await lane.restart()
        _ = await lane.scan()
        e2eAssertDump(try await lane.dump(), before, "deleted transcript, after a restart")
        await lane.close()
    }

    // MARK: (i) history database lost

    func testALostOrCorruptDatabaseIsRefilledFromTheUsageCacheWithoutOpeningATranscript() async throws {
        for variant in ["deleted, same cache", "garbage, new cache"] {
            let tree = try e2eTree("lost-\(variant.prefix(7))")
            _ = try writeRichSession(tree)
            let other = tree.main("1c4d6e2f-2222-4000-8000-00000000000b")
            try tree.write([F.rec(20, F.t0 + 9_000, out: 21)], to: other)
            let oracle = try await e2eOracle(tree)
            let lane = E2ELane(tree: tree, name: "i")
            _ = await lane.scan()
            e2eAssertDump(try await lane.dump(), oracle.dump, "\(variant): before")

            await lane.close()
            let fm = FileManager.default
            for name in try fm.contentsOfDirectory(atPath: lane.dbDir.path) where name.hasPrefix("history.sqlite") {
                try fm.removeItem(at: lane.dbDir.appendingPathComponent(name))
            }
            if variant.hasPrefix("garbage") {
                try Data(repeating: 0xA5, count: 64 * 1024).write(to: lane.dbDir.appendingPathComponent(HistoryDatabase.fileName))
            }
            await lane.restart(cache: variant.hasSuffix("new cache"), store: true)
            for url in tree.files { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path) }
            await lane.cache.stats.reset()
            let report = await lane.scan()
            for url in tree.files { try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            let stats = await lane.scanStats()
            XCTAssertEqual(stats.filesOpened, 0, "\(variant): no transcript opened")
            XCTAssertEqual(stats.memoryHits + stats.storeHits, 3, "\(variant): every file from the usage cache")
            e2eAssertDump(try await lane.dump(), oracle.dump, "\(variant): refilled")
            e2eAssertDayModels(try await lane.dayModels(), report, variant)
            let status = await lane.store.status()
            if variant.hasPrefix("garbage") {
                guard case .rebuilt = status else { return XCTFail("\(variant): status \(status)") }
                XCTAssertEqual(historyQuarantined(in: lane.dbDir).filter { $0.hasSuffix(".sqlite") }.count, 1)
            } else {
                XCTAssertEqual(status, .ready)
            }
            await lane.close()
        }
    }

    // MARK: (j) crash between the usage cache's save and the ingest

    func testABatchLostBetweenTheCacheSaveAndTheIngestIsRecoveredWhole() async throws {
        for variant in ["same process", "restart", "append after the loss"] {
            let tree = try e2eTree("crash-\(variant.count)")
            let (main, agent) = try writeRichSession(tree)
            let lane = E2ELane(tree: tree, name: "j")
            let tee = E2ETeeSink(lane.store)
            _ = await lane.scan(history: tee)
            try tree.append([F.rec(8, F.t0 + 20_000, out: 3, final: false), F.rec(8, F.t0 + 21_000, out: 33)], to: main)
            try tree.append([F.rec(10, F.t0 + 22_000, out: 15, final: false, model: F.sonnet, sidechain: true)], to: agent)
            tee.dropNext()
            _ = await lane.scan(history: tee)       // saved to the usage cache, never ingested
            XCTAssertEqual(tee.dropped, 1)
            await lane.cache.stats.reset()
            var store: (any HistoryIngesting)? = tee
            switch variant {
            case "restart":
                await lane.restart()
                store = lane.store
            case "append after the loss":
                try tree.append([F.rec(13, F.t0 + 30_000, out: 2)], to: main)
            default:
                break
            }
            let report = await lane.scan(history: store)
            let opened = await lane.scanStats().filesOpened
            if variant != "append after the loss" {
                XCTAssertEqual(opened, 0, "\(variant): from the cache, no transcript read")
            } else {
                XCTAssertNotNil(tee.scans.last?.file(main)?.delta, "a delta on the lost base: the store must not apply it")
            }
            try await check(lane, report, "\(variant): recovered")
            await lane.close()
        }
    }

    // MARK: (k) scan statistics with and without a history

    func testScanStatisticsAreIdenticalWithAndWithoutAHistory() async throws {
        let tree = try e2eTree()
        let (main, agent) = try writeRichSession(tree)
        let with = E2ELane(tree: tree, name: "k-with")
        let without = E2ELane(tree: tree, name: "k-without")
        func step(_ label: String, complete: Bool = true, files: [URL]? = nil) async {
            let a = await with.scan(files, complete: complete)
            let b = await without.scan(files, complete: complete, history: .some(nil))
            XCTAssertEqual(a.dayModels, b.dayModels, label)
            XCTAssertEqual(a.requestFinality, b.requestFinality, label)
            let (x, y) = (await with.scanStats(), await without.scanStats())
            XCTAssertEqual(x, y, label)
        }
        await step("cold")
        await step("unchanged")
        try tree.append([F.rec(8, F.t0 + 20_000, out: 3, final: false)], to: main)
        await step("append", complete: false, files: [main, agent])
        await with.restart()
        await without.restart()
        await step("restart")
        try tree.append([F.rec(8, F.t0 + 21_000, out: 33)], to: main)
        try tree.append([F.rec(10, F.t0 + 22_000, out: 15, final: false, model: F.sonnet, sidechain: true)], to: agent)
        await with.restart(cache: true, store: false)
        await without.restart(cache: true, store: false)
        await step("restart + append")
        try await check(with, await with.scan(), "with history")
        _ = await without.scan(history: .some(nil))     // the same scan on both lanes
        try tree.rewriteInPlace([F.rec(40, F.t0 + 1, out: 1)], at: agent)
        await step("rewrite")
        await with.close()
        await without.close()
    }

    // MARK: (l) the report never waits for the history

    func testTheReportReturnsWhileTheHistoryIsBlocked() async throws {
        let tree = try e2eTree()
        _ = try writeRichSession(tree)
        let lane = E2ELane(tree: tree, name: "l")
        let gate = HistoryAsyncGate()
        let entered = HistoryAsyncGate()
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        lane.store.enqueue { _ in
            await entered.open()
            await gate.wait()
        }
        await entered.wait()
        let safety = Task.detached {
            try? await Task.sleep(for: .seconds(30))
            timedOut.withLock { $0 = true }
            await gate.open()
        }
        let report = await lane.scan()
        XCTAssertFalse(timedOut.withLock { $0 }, "the scan returned while the history's drain was blocked")
        XCTAssertFalse(report.dayModels.isEmpty)
        // The store is free between the blocked command's suspension points:
        // its rows are not there yet.
        let pending = try await lane.store.logicalDump()
        XCTAssertTrue(pending.requests.isEmpty, "the scan's batch waits behind the blocked command")
        await gate.open()
        safety.cancel()
        try await check(lane, report, "after release")
        await lane.close()
    }

    // MARK: (m) acct_day across local midnight

    func testAFinalAfterLocalMidnightKeepsTheFirstRecordsDayInBothLedgerAndHistory() async throws {
        let tree = try e2eTree()
        let midnight = F.localMidnight(dayOffset: 1)
        let main = tree.main()
        let agent = tree.subagent("a1b2c3")
        try tree.write([
            F.rec(1, midnight - 20_000, out: 2, final: false),
            F.rec(2, midnight - 10_000, out: 5),
            F.rec(1, midnight + 20_000, out: 60),              // the final, after midnight
            F.rec(3, midnight + 30_000, out: 6, model: F.sonnet),
        ], to: main)
        // A sidechain whose partial-only request streams across midnight.
        try tree.write([
            F.rec(9, midnight - 5_000, out: 1, final: false, model: F.sonnet, sidechain: true),
            F.rec(9, midnight + 5_000, out: 8, final: false, model: F.sonnet, sidechain: true),
        ], to: agent)
        let lane = E2ELane(tree: tree, name: "m")
        let tokyo = E2ELane(tree: tree, name: "m-tokyo", timeZone: hmTokyo)
        let tee = E2ETeeSink(tokyo.store)
        let report = await lane.scan(history: E2EFanOut([lane.store, tee]))
        try await check(lane, report, "midnight")
        let day = e2eDayNumber(HistoryTime.date(ms: midnight - 20_000))
        let dump = try await lane.dump()
        for n in [1, 9] {
            let hex = DedupKey(messageID: "msg_e2e_\(n)", requestID: "req_e2e_\(n)").historyHex
            XCTAssertEqual(dump.requests.first { $0.keyHex == hex }?.acctDay, day, "key \(n): the first record's day")
        }
        // The same rows under another accounting zone: acct_day follows the
        // zone, everything else is identical.
        let tokyoDump = try await tokyo.dump()
        for (a, b) in zip(dump.requests, tokyoDump.requests) {
            XCTAssertEqual(b.acctDay, e2eDayNumber(HistoryTime.date(ms: a.firstSeenMs!), timeZone: hmTokyo))
            var x = a, y = b
            x.acctDay = nil
            y.acctDay = nil
            XCTAssertEqual(x, y)
        }
        await lane.close()
        await tokyo.close()
    }

    // MARK: (n) one request's records far apart

    static let fiftyDays: Int64 = 50 * 86_400_000

    /// A key whose records in ONE file lie more than 2^32 ms (49.7 days)
    /// apart: a cold scan states the exact last time (and the final time,
    /// when the later record is the final one), and an incremental scan that
    /// saw the first record alone, then resumed past the appended second,
    /// stores exactly the same rows.
    func testRecordsOfOneKeyFiftyDaysApartInOneFileGiveTheSameRowsColdAndIncremental() async throws {
        let k = DedupKey(messageID: "msg_e2e_1", requestID: "req_e2e_1").historyHex
        for final in [false, true] {
            let tree = try e2eTree("span-\(final)")
            let main = tree.main()
            let t = F.t0
            let first = F.rec(1, t, out: 3, final: false)
            let later = F.rec(1, t + Self.fiftyDays, out: 9, final: final)
            try tree.write([first, later], to: main)
            let cold = try await e2eOracle(tree)
            let row = try XCTUnwrap(cold.dump.requests.first { $0.keyHex == k })
            XCTAssertEqual(row.firstSeenMs, t, "final \(final)")
            XCTAssertEqual(row.lastSeenMs, t + Self.fiftyDays, "final \(final): a stated time is never dropped")
            XCTAssertEqual(row.finalMs, final ? t + Self.fiftyDays : nil, "final \(final)")
            XCTAssertEqual(row.output, 9)
            let occurrence = try XCTUnwrap(cold.dump.occurrences.first { $0.keyHex == k })
            XCTAssertEqual(occurrence.firstMs, t)
            XCTAssertEqual(occurrence.lastMs, t + Self.fiftyDays)

            try tree.rewriteInPlace([first], at: main)
            let lane = E2ELane(tree: tree, name: "span-\(final)")
            _ = await lane.scan()
            try tree.append([later], to: main)
            _ = await lane.scan()
            let resumed = await lane.scanStats().resumedParses
            XCTAssertEqual(resumed, 1, "final \(final): the second scan resumed past the first record")
            e2eAssertDump(try await lane.dump(), cold.dump, "final \(final): incremental")
            await lane.close()
        }
    }

    /// The same span across two files (a fork re-stamped 50 days later),
    /// each contributed whole: every arrival order stores the cold rows, and
    /// the fork's occurrence keeps its exact last time.
    func testRecordsOfOneKeyFiftyDaysApartAcrossTwoFilesAreOrderIndependent() async throws {
        let tree = try e2eTree()
        let t = F.t0
        let origin = tree.main()
        let fork = tree.main("ffffffff-0000-4000-8000-0000000000f2")
        try tree.write([F.rec(1, t, out: 3, final: false), F.rec(1, t + 1_000, out: 40)], to: origin,
                       birth: 1_780_000_000_000)
        try tree.write([F.rec(1, t, out: 3, final: false, tag: "f"), F.rec(1, t + Self.fiftyDays, out: 40, tag: "f")],
                       to: fork, birth: 1_780_000_000_000 + Self.fiftyDays)
        let oracle = try await e2eOracle(tree)
        let k = DedupKey(messageID: "msg_e2e_1", requestID: "req_e2e_1").historyHex
        let forkOccurrence = try XCTUnwrap(oracle.dump.occurrences.first { $0.keyHex == k && $0.path == fork.path })
        XCTAssertEqual(forkOccurrence.firstMs, t)
        XCTAssertEqual(forkOccurrence.lastMs, t + Self.fiftyDays)
        XCTAssertEqual(oracle.dump.requests.first { $0.keyHex == k }?.ownerPath, origin.path)
        for (name, orders) in [("origin-first", [[origin], [fork]]), ("fork-first", [[fork], [origin]])] {
            let lane = E2ELane(tree: tree, name: "span-\(name)")
            for files in orders { _ = await lane.scan(files, complete: false) }
            e2eAssertDump(try await lane.dump(), oracle.dump, name)
            await lane.close()
        }
    }

    // MARK: (o) a count outside the store's range

    /// A later record of a key with a count past 2^48 or below 0, after a
    /// record the store took: the scanner reads that count as absent, so the
    /// store never refuses the request's later state, and an incremental
    /// scan (prefix first, then the appended record) stores the cold rows.
    /// Exactly 2^48 is a count both take.
    func testACountOutsideTheStoresRangeIsReadAsAbsentSoColdAndIncrementalAgree() async throws {
        let t = F.t0
        let huge = HistoryObservationCheck.maxCount + 1
        // The zeroed check reads cache_creation_input_tokens the same way: a
        // final record whose only count is -7 there is a zeroed replay, so it
        // must not outrank the partial and erase its output.
        let onlyNegativeCacheCreation = F.rec(1, t + 1_000, out: 0, input: 0, tag: "b")
            .replacingOccurrences(of: #""cache_creation_input_tokens":50"#, with: #""cache_creation_input_tokens":-7"#)
            .replacingOccurrences(of: #""cache_read_input_tokens":1000"#, with: #""cache_read_input_tokens":0"#)
            .replacingOccurrences(of: #","cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":0}"#,
                                  with: "")
        XCTAssertTrue(onlyNegativeCacheCreation.contains(#""cache_creation_input_tokens":-7"#), onlyNegativeCacheCreation)
        XCTAssertFalse(onlyNegativeCacheCreation.contains(#""cache_creation":"#), onlyNegativeCacheCreation)
        XCTAssertTrue(onlyNegativeCacheCreation.contains(#""cache_read_input_tokens":0"#), onlyNegativeCacheCreation)
        for (name, lines, output) in [
            ("partial out 3, then partial out 2^48+1",
             [F.rec(1, t, out: 3, final: false), F.rec(1, t + 1_000, out: huge, final: false, tag: "b")], 3),
            ("partial out 3, then final out -5",
             [F.rec(1, t, out: 3, final: false), F.rec(1, t + 1_000, out: -5, tag: "b")], 0),
            ("partial out 3, then final input 2^48+1",
             [F.rec(1, t, out: 3, final: false), F.rec(1, t + 1_000, out: 4, input: huge, tag: "b")], 4),
            ("final out 2^48 (at the bound) after partial",
             [F.rec(1, t, out: 3, final: false), F.rec(1, t + 1_000, out: HistoryObservationCheck.maxCount, tag: "b")],
             HistoryObservationCheck.maxCount),
            ("partial out 3, then final with only cache_creation_input_tokens -7",
             [F.rec(1, t, out: 3, final: false), onlyNegativeCacheCreation], 3),
        ] {
            let tree = try e2eTree("count-range")
            let main = tree.main()
            try tree.write(lines, to: main)
            let cold = try await e2eOracle(tree)
            XCTAssertEqual(cold.dump.requests.map(\.output), [Int64(output)], "\(name): the row's output")

            try tree.rewriteInPlace([lines[0]], at: main)
            let lane = E2ELane(tree: tree, name: "inc")
            _ = await lane.scan()
            try tree.append([lines[1]], to: main)
            let report = await lane.scan()
            e2eAssertDump(try await lane.dump(), cold.dump, "\(name): incremental")
            let skipped = await lane.store.statistics().skippedInvalidObservations
            XCTAssertEqual(skipped, 0, "\(name): the store refused nothing")
            e2eAssertDayModels(try await lane.dayModels(), report, name)
            await lane.close()
        }
    }
}

/// Hands every call to each target, in order.
struct E2EFanOut: HistoryIngesting {
    let targets: [any HistoryIngesting]
    init(_ targets: [any HistoryIngesting]) { self.targets = targets }
    func submit(scan: HistoryScanBatch) { for t in targets { t.submit(scan: scan) } }
    func submit(quota: [QuotaSampleRow]) { for t in targets { t.submit(quota: quota) } }
    func submit(legacyQuota: [QuotaSampleRow]) { for t in targets { t.submit(legacyQuota: legacyQuota) } }
    func submit(resetGrants: [ResetGrantObservation], recordedMs: Int64) {
        for t in targets { t.submit(resetGrants: resetGrants, recordedMs: recordedMs) }
    }
}
