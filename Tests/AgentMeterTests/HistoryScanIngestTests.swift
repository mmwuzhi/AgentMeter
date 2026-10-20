import Foundation
import os
import XCTest
@testable import AgentMeter

/// The scan driver: watermark rules, chunk atomicity, validation, coverage,
/// and the read queries over what it stored.
final class HistoryScanIngestTests: XCTestCase {
    final class Calls: Sendable {
        private let n = OSAllocatedUnfairLock(initialState: 0)
        func hit() { n.withLock { $0 += 1 } }
        var count: Int { n.withLock { $0 } }
    }

    let path = "/p/proj/s1.jsonl"

    func obs(_ n: Int, output: Int = 5, first: Int64 = 1_000, model: String = "opus") -> RequestObservation {
        hmObs(hmKey(n), [hmPart(model, output: output)], .final, first: first, last: first + 10, final: first)
    }

    func batch(_ scan: UInt64, _ wm: HistoryFileWatermark, _ all: [RequestObservation], calls: Calls? = nil,
               delta: (base: HistoryFileWatermark, requests: [RequestObservation])? = nil) -> HistoryFileBatch {
        let d = delta.map { HistoryFileBatch.Delta(basedOnParsedBytes: $0.base.parsedBytes, basedOnFileID: $0.base.fileID,
                                                   basedOnBoundaryDigest: $0.base.boundaryDigest,
                                                   basedOnParserVersion: $0.base.parserVersion, requests: $0.requests) }
        return HistoryFileBatch(path: path, scan: scan, watermark: wm, delta: d,
                                allRequests: { calls?.hit(); return all }, events: .empty)
    }

    func keys(_ store: HistoryStore) async throws -> Set<String> {
        Set(try await store.logicalDump().requests.map(\.keyHex))
    }

    func storedWatermark(_ store: HistoryStore) async throws -> HistoryFileWatermark? {
        let p = path
        return try await store.withDatabase { try $0.storedFile(path: p)?.watermark }
    }

    // MARK: Watermarks

    func testAnUnchangedFileIsSkippedWithoutBuildingItsRequestsOrWritingARow() async throws {
        let store = hmStore(historyTempDirectory())
        let calls = Calls()
        let wm = hmWatermark(id: 5, parsed: 100)
        try await store.applyScanCommand(hmScan(1, [batch(1, wm, [obs(1), obs(2)], calls: calls)]))
        let before = try await store.withDatabase { $0.conn.totalChanges }
        try await store.applyScanCommand(hmScan(2, [batch(2, wm, [obs(1), obs(2)], calls: calls)], startedMs: 2_000))
        let after = try await store.withDatabase { $0.conn.totalChanges }
        XCTAssertEqual(after - before, 0, "an unchanged windowed scan a second later writes nothing, not even coverage")
        XCTAssertEqual(calls.count, 1, "the skipped batch's observations are never even built")
        let stats = await store.statistics()
        XCTAssertEqual(stats.skippedFileBatches, 1)
    }

    /// The per-path scan ticket is the only stale-batch defence. Tickets are
    /// per process: after a restart (`resetIngestMemory`, as an open does) the
    /// older batch is accepted, applied whole, and moves the watermark back;
    /// union semantics keep what the newer batch contributed.
    func testAnOlderScanIsSkippedOnlyUntilTheTicketsResetOnARestart() async throws {
        let store = hmStore(historyTempDirectory())
        let older = hmScan(3, [batch(3, hmWatermark(id: 5, parsed: 10), [obs(3)])])
        try await store.applyScanCommand(hmScan(5, [batch(5, hmWatermark(id: 5, parsed: 20), [obs(1), obs(2)])]))
        try await store.applyScanCommand(older)
        var stored = try await keys(store)
        XCTAssertEqual(stored, [hmKey(1).historyHex, hmKey(2).historyHex], "ticket 3 after ticket 5: skipped")
        var wm = try await storedWatermark(store)
        XCTAssertEqual(wm?.parsedBytes, 20)
        let skipped = await store.statistics().skippedFileBatches
        XCTAssertEqual(skipped, 1)

        await store.resetIngestMemory()
        try await store.applyScanCommand(older)
        stored = try await keys(store)
        XCTAssertEqual(stored.count, 3, "after a restart nothing remembers ticket 5: the older batch is accepted")
        wm = try await storedWatermark(store)
        XCTAssertEqual(wm?.parsedBytes, 10)
    }

    /// A transcript truncated and rewritten under the SAME inode is parsed from
    /// the top: its smaller batch is ingested whole and the watermark moves to
    /// the new parsed bytes; the dump equals ingesting the old content and then
    /// the new one (union semantics), and the file is not stalled until it grows.
    func testAFileRewrittenInPlaceUnderTheSameInodeIsIngestedAndItsWatermarkMovesBack() async throws {
        let store = hmStore(historyTempDirectory())
        let old = [obs(1, output: 9), obs(2)]
        let new = [hmObs(hmKey(1), [hmPart(output: 3)], .partial, first: 2_000, last: 2_000), obs(3)]
        try await store.applyScanCommand(hmScan(1, [batch(1, hmWatermark(id: 5, parsed: 20), old)]))
        try await store.applyScanCommand(hmScan(2, [batch(2, hmWatermark(id: 5, parsed: 10), new)]))
        let wm = try await storedWatermark(store)
        XCTAssertEqual(wm, hmWatermark(id: 5, parsed: 10))
        let dump = try await store.logicalDump()
        let want = HMOracle.dump([HMContribution(path: path, version: hmParserVersion, observations: old),
                                  HMContribution(path: path, version: hmParserVersion, observations: new)], births: [:], timeZone: hmTokyo)
        XCTAssertEqual(dump, want, hmDiff(dump, want))
        XCTAssertEqual(dump.requests.first { $0.keyHex == hmKey(1).historyHex }?.output, 9, "the old final stays")
        // A growing file now resumes from the new watermark.
        try await store.applyScanCommand(hmScan(3, [batch(3, hmWatermark(id: 5, parsed: 30), new + [obs(4)],
                                                         delta: (hmWatermark(id: 5, parsed: 10), [obs(4)]))]))
        let stored = try await keys(store)
        XCTAssertTrue(stored.contains(hmKey(4).historyHex))
    }

    func testADeltaAppliesOnlyWhenItsBaseIsExactlyTheStoredWatermark() async throws {
        let store = hmStore(historyTempDirectory())
        let calls = Calls()
        let wm10 = hmWatermark(id: 5, parsed: 10), wm20 = hmWatermark(id: 5, parsed: 20)
        try await store.applyScanCommand(hmScan(1, [batch(1, wm10, [obs(1)])]))
        // Base matches: only the delta is applied (K9 is in allRequests only).
        try await store.applyScanCommand(hmScan(2, [batch(2, wm20, [obs(1), obs(2), obs(9)], calls: calls,
                                                         delta: (wm10, [obs(2)]))]))
        var stored = try await keys(store)
        XCTAssertEqual(stored, [hmKey(1).historyHex, hmKey(2).historyHex])
        XCTAssertEqual(calls.count, 0)
        // Each mismatching base field sends the batch down the whole path.
        var other = wm20
        other.boundaryDigest = Data([9, 9])
        var version = wm20
        version.parserVersion = 2
        for (n, base) in [hmWatermark(id: 5, parsed: 15), hmWatermark(id: 7, parsed: 20), other, version].enumerated() {
            let wm = hmWatermark(id: 5, parsed: Int64(30 + n))
            try await store.applyScanCommand(hmScan(UInt64(3 + n), [batch(UInt64(3 + n), wm, [obs(1), obs(2), obs(10 + n)],
                                                                         calls: calls, delta: (base, [obs(2)]))]))
            stored = try await keys(store)
            XCTAssertTrue(stored.contains(hmKey(10 + n).historyHex), "base \(n) mismatches: whole")
        }
        XCTAssertEqual(calls.count, 4)
    }

    // MARK: Atomicity of a file

    /// The watermark is written in the transaction of the file's LAST chunk:
    /// a failure there rolls back that chunk's rows AND the watermark, so the
    /// next scan finds the file not ingested and re-applies it whole.
    func testAFailureInTheLastChunkLeavesNoWatermarkAndTheNextScanReapplies() async throws {
        let store = hmStore(historyTempDirectory())
        await store.setScanChunkSize(2)
        let all = (1...5).map { obs($0) }
        try await store.withDatabase { db in
            try db.conn.exec("""
                CREATE TEMP TRIGGER hm_fail BEFORE UPDATE OF parsed_bytes ON main.source_file
                BEGIN SELECT RAISE(ABORT, 'simulated crash before the watermark'); END
                """)
        }
        let wm = hmWatermark(id: 5, parsed: 50)
        try await store.applyScanCommand(hmScan(1, [batch(1, wm, all)]))
        var wmStored = try await storedWatermark(store)
        XCTAssertNil(wmStored)
        var stored = try await keys(store)
        XCTAssertEqual(stored.count, 4, "chunks [1,2] and [3,4] committed; [5] rolled back with the watermark")
        let stats = await store.statistics()
        XCTAssertEqual(stats.failedChunks, 1)
        try await store.withDatabase { try $0.conn.exec("DROP TRIGGER hm_fail") }
        try await store.applyScanCommand(hmScan(2, [batch(2, wm, all)]))
        wmStored = try await storedWatermark(store)
        XCTAssertEqual(wmStored, wm)
        stored = try await keys(store)
        XCTAssertEqual(stored.count, 5)
    }

    func testAFailedMiddleChunkSuppressesTheWatermarkOfTheLastChunk() async throws {
        let store = hmStore(historyTempDirectory())
        await store.setScanChunkSize(2)
        let all = [obs(1), obs(2), obs(3, first: 777), obs(4), obs(5)]
        try await store.withDatabase { db in
            try db.conn.exec("""
                CREATE TEMP TRIGGER hm_fail BEFORE INSERT ON main.request_occurrence WHEN NEW.first_ms = 777
                BEGIN SELECT RAISE(ABORT, 'simulated failure'); END
                """)
        }
        let wm = hmWatermark(id: 5, parsed: 50)
        try await store.applyScanCommand(hmScan(1, [batch(1, wm, all)]))
        let wmStored = try await storedWatermark(store)
        XCTAssertNil(wmStored, "a later chunk committed, but the file is not complete")
        try await store.withDatabase { try $0.conn.exec("DROP TRIGGER hm_fail") }
        try await store.applyScanCommand(hmScan(2, [batch(2, wm, all)]))
        let dump = try await store.logicalDump()
        let want = HMOracle.dump([HMContribution(path: path, version: hmParserVersion, observations: all)], births: [:], timeZone: hmTokyo)
        XCTAssertEqual(dump.requests, want.requests)
    }

    func testInvalidObservationsAreSkippedAndCountedBeforeTheTransaction() async throws {
        let store = hmStore(historyTempDirectory())
        let bad = [
            hmObs(hmKey(2), [], .final, first: 1, last: 1, final: 1),
            hmObs(hmKey(3), [hmPart(output: -1)], .final, first: 1, last: 1, final: 1),
            hmObs(hmKey(4), [hmPart(output: 1)], .final, first: Int64.min, last: 1, final: 1),
            hmObs(hmKey(5), [hmPart(output: 1)], .partial, first: 1, last: 1, thinking: -3),
        ]
        try await store.applyScanCommand(hmScan(1, [batch(1, hmWatermark(id: 5, parsed: 10), [obs(1)] + bad)]))
        let stored = try await keys(store)
        XCTAssertEqual(stored, [hmKey(1).historyHex])
        let stats = await store.statistics()
        XCTAssertEqual(stats.skippedInvalidObservations, 4)
        XCTAssertEqual(stats.failedChunks, 0, "nothing reached the transaction")
        let wm = try await storedWatermark(store)
        XCTAssertNotNil(wm, "the valid rest landed with its watermark")
    }

    func testAStrayFinalTimeOnANonFinalObservationIsIgnored() async throws {
        let store = hmStore(historyTempDirectory())
        let stray = hmObs(hmKey(1), [hmPart(output: 2)], .partial, first: 5, last: 5, final: 5)
        try await store.applyScanCommand(hmScan(1, [batch(1, hmWatermark(id: 5, parsed: 10), [stray])]))
        let rows = try await store.requestRows(keyHex: hmKey(1).historyHex)
        XCTAssertNil(rows.first?.finalMs)
    }

    /// The real `stat`: birth is read once, when the path is first registered,
    /// and never rewritten (a recreated file keeps the first birth).
    func testBirthIsStatOnceForANewPathAndNeverRewritten() async throws {
        let dir = historyTempDirectory()
        let transcript = dir.appendingPathComponent("s9.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let store = HistoryStore(directory: dir.appendingPathComponent("db"))
        let birth = HistoryFileBirth.read(transcript.path)
        XCTAssertNotNil(birth)
        try await store.applyScanCommand(hmScan(1, [hmFile(transcript.path, scan: 1, watermark: hmWatermark(id: 1, parsed: 1), [obs(1)])]))
        try FileManager.default.removeItem(at: transcript)
        try await Task.sleep(nanoseconds: 20_000_000)
        try Data("{}\n{}\n".utf8).write(to: transcript)
        try await store.applyScanCommand(hmScan(2, [hmFile(transcript.path, scan: 2, watermark: hmWatermark(id: 2, parsed: 2), [obs(2)])]))
        let files = try await store.logicalDump().files
        XCTAssertEqual(files.map(\.birthMs), [birth])
        XCTAssertNotEqual(HistoryFileBirth.read(transcript.path), birth, "the recreated file has a new birth the store ignores")
        await store.close()
    }

    // MARK: Coverage and the inbox

    /// A complete scan always records a row; a windowed scan that wrote no
    /// file records none and moves `latest_scan_ms` only once it is
    /// `latestScanGranularityMs` old; neither meta value ever moves back
    /// (overlapping scans land out of order).
    func testScanCoverageIsRecordedAndNeverMovesBack() async throws {
        let store = hmStore(historyTempDirectory())
        let g = HistoryDatabase.latestScanGranularityMs
        try await store.applyScanCommand(hmScan(1, [batch(1, hmWatermark(id: 5, parsed: 10), [obs(1)])],
                                                complete: true, startedMs: 5_000))
        try await store.applyScanCommand(hmScan(2, [], complete: false, startedMs: 5_000 + g - 1))   // < g: nothing
        var latest = try await store.withDatabase { try $0.metaInt("latest_scan_ms") }
        XCTAssertEqual(latest, 5_000)
        try await store.applyScanCommand(hmScan(3, [], complete: false, startedMs: 70_000 + g))   // >= g: meta only
        try await store.applyScanCommand(hmScan(4, [], complete: true, startedMs: 65_000 + g))    // started earlier, landed later
        let (complete, rows, completeRows) = try await store.withDatabase { db in
            (try db.metaInt("complete_scan_ms"), try db.conn.queryInt("SELECT count(*) FROM ingest_scan"),
             try db.conn.queryInt("SELECT count(*) FROM ingest_scan WHERE complete = 1 AND files_written = 1"))
        }
        latest = try await store.withDatabase { try $0.metaInt("latest_scan_ms") }
        XCTAssertEqual(complete, 65_000 + g)
        XCTAssertEqual(latest, 70_000 + g)
        XCTAssertEqual(rows, 2, "the two complete scans; the windowed ones wrote no file and no row")
        XCTAssertEqual(completeRows, 1)
    }

    func testSubmittedScansAreAppliedInOrderThroughTheInbox() async throws {
        let store = hmStore(historyTempDirectory())
        store.submit(scan: hmScan(1, [batch(1, hmWatermark(id: 5, parsed: 10), [obs(1, output: 1)])]))
        store.submit(scan: hmScan(2, [batch(2, hmWatermark(id: 5, parsed: 20), [obs(1, output: 1), obs(2)],
                                            delta: (hmWatermark(id: 5, parsed: 10), [obs(2)]))]))
        await store.flush()
        let stored = try await keys(store)
        XCTAssertEqual(stored.count, 2)
        let stats = await store.statistics()
        XCTAssertEqual(stats.appliedCommands, 2)
        XCTAssertEqual(stats.failedCommands, 0)
    }

    // MARK: Queries

    func testDayModelSumsSessionUsageAndStatistics() async throws {
        let store = hmStore(historyTempDirectory())
        let day1 = hmMidnight(hmTokyo, 2026, 9, 1) + 3_600_000, day2 = hmMidnight(hmTokyo, 2026, 9, 2) + 60_000
        let agent = "/p/proj/s1/subagents/agent-x.jsonl"
        let main = [obs(1, output: 10, first: day1), obs(2, output: 20, first: day1, model: "fable"),
                    obs(3, output: 30, first: day2)]
        let sub = [obs(4, output: 40, first: day2),
                   hmObs(hmKey(5), [hmPart("fable", output: 1), hmPart("opus", output: 2)], .partial, first: day2, last: day2)]
        try await store.applyScanCommand(hmScan(1, [batch(1, hmWatermark(id: 5, parsed: 10), main),
                                                    hmFile(agent, scan: 1, watermark: hmWatermark(id: 6, parsed: 10), sub)]))
        let days = try await store.dayModelUsage()
        XCTAssertEqual(days.map { "\($0.acctDay ?? 0) \($0.model) \($0.counts.output) \($0.finalRows)/\($0.partialRows)" },
                       ["20260901 fable 20 1/0", "20260901 opus 10 1/0", "20260902 fable 1 0/1", "20260902 opus 72 2/1"])
        let usage = try await store.sessionUsage(sessionID: "s1")
        XCTAssertEqual(usage.byModel.map { "\($0.model) \($0.counts.output) \($0.rows)" }, ["fable 21 2", "opus 82 4"])
        XCTAssertEqual(usage.byAgent.map { "\($0.agentID ?? "main") \($0.model) \($0.counts.output)" },
                       ["main fable 20", "main opus 40", "x fable 1", "x opus 42"])
        let rows = try await store.requestRows(keyHex: hmKey(5).historyHex)
        XCTAssertEqual(rows.map(\.model), ["fable", "opus"])
        XCTAssertEqual(rows.map(\.ownerPath), [agent, agent])
        let stats = try await store.historyStatistics()
        XCTAssertEqual(stats.rowCounts["request"], 6)
        XCTAssertEqual(stats.rowCounts["request_occurrence"], 5)
        XCTAssertEqual(stats.rowCounts["source_file"], 2)
        XCTAssertEqual(stats.rowCounts["session"], 1)
        XCTAssertEqual(stats.counters.committedChunks, 1, "two small files share one transaction")
    }
}
