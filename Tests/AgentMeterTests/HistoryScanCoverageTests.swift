import Foundation
import XCTest
@testable import AgentMeter

/// Scan coverage (`ingest_scan`, `meta.latest_scan_ms` / `complete_scan_ms`):
/// an unchanged windowed scan — the app's scan every minute while nothing
/// happens — writes nothing but, every `latestScanGranularityMs`, one meta
/// value; a scan that wrote a file and every complete scan record a row;
/// maintenance prunes old rows and nothing else.
final class HistoryScanCoverageTests: XCTestCase {
    let path = "/p/proj/s1.jsonl"
    let t0: Int64 = 1_790_000_000_000

    func obs(_ n: Int) -> RequestObservation {
        hmObs(hmKey(n), [hmPart(output: 5)], .final, first: t0 + Int64(n), last: t0 + Int64(n), final: t0 + Int64(n))
    }

    func coverage(_ store: HistoryStore) async throws -> (changes: Int64, rows: Int64, latest: Int64?, complete: Int64?) {
        try await store.withDatabase { db in
            (db.conn.totalChanges, try db.conn.queryInt("SELECT count(*) FROM ingest_scan") ?? -1,
             try db.metaInt("latest_scan_ms"), try db.metaInt("complete_scan_ms"))
        }
    }

    func testFiftyUnchangedWindowedScansWriteNothingAndLatestMovesAtMostOncePerGranularity() async throws {
        let clock = HMClock()
        clock.set(HistoryTime.date(ms: t0))
        let store = hmStore(historyTempDirectory(), clock: clock)
        let wm = hmWatermark(id: 5, parsed: 100)
        let file = { (ticket: UInt64) in hmFile(self.path, scan: ticket, watermark: wm, [self.obs(1), self.obs(2)]) }
        try await store.applyScanCommand(hmScan(1, [file(1)], startedMs: t0))
        let first = try await coverage(store)
        XCTAssertEqual(first.rows, 1, "the scan that wrote the file records its row")
        XCTAssertEqual(first.latest, t0)

        // 50 unchanged scans inside one minute: not a single change.
        for i in 1...50 {
            let at = t0 + Int64(i) * 1_000
            clock.set(HistoryTime.date(ms: at))
            try await store.applyScanCommand(hmScan(UInt64(1 + i), [file(UInt64(1 + i))], startedMs: at))
        }
        let quiet = try await coverage(store)
        XCTAssertEqual(quiet.changes, first.changes, "50 unchanged scans within a minute: total_changes unchanged")
        XCTAssertEqual(quiet.rows, 1)
        XCTAssertEqual(quiet.latest, t0)

        // 50 more at the app's cadence, 60 s apart (50 min): latest_scan_ms
        // moves only when the stored value is a granularity old, no row.
        let granularity = HistoryDatabase.latestScanGranularityMs
        XCTAssertEqual(granularity, 15 * 60_000)
        var latest = quiet.latest!
        var advances: Int64 = 0
        for i in 0..<50 {
            let at = t0 + 60_000 + Int64(i) * 60_000
            clock.set(HistoryTime.date(ms: at))
            try await store.applyScanCommand(hmScan(UInt64(100 + i), [file(UInt64(100 + i))], startedMs: at))
            let now = try await coverage(store)
            if now.latest != latest {
                XCTAssertGreaterThanOrEqual(now.latest! - latest, granularity, "scan \(i): at most once per granularity")
                latest = now.latest!
                advances += 1
            }
        }
        let after = try await coverage(store)
        XCTAssertEqual(after.rows, 1, "no row for any unchanged windowed scan")
        XCTAssertEqual(advances, 3, "15, 30 and 45 min")
        XCTAssertEqual(after.changes - quiet.changes, advances, "one single-row UPDATE per advance, nothing else")
        XCTAssertEqual(latest, t0 + 3 * granularity)
        let skipped = await store.statistics().skippedFileBatches
        XCTAssertEqual(skipped, 100)
    }

    /// The app's refresh starts a windowed scan every 60 s, so consecutive
    /// scan starts land 60.000 s apart or a few ms more. Twenty unchanged
    /// scans at that cadence commit at most twice, not once per scan.
    func testTwentyUnchangedScansAtTheAppCadenceCommitAtMostTwice() async throws {
        for spacing: Int64 in [60_000, 60_005] {
            let store = hmStore(historyTempDirectory())
            let wm = hmWatermark(id: 5, parsed: 100)
            let file = { (ticket: UInt64) in hmFile(self.path, scan: ticket, watermark: wm, [self.obs(1)]) }
            try await store.applyScanCommand(hmScan(1, [file(1)], startedMs: t0))
            let before = try await coverage(store)
            for i in 1...20 {
                try await store.applyScanCommand(hmScan(UInt64(1 + i), [file(UInt64(1 + i))], startedMs: t0 + Int64(i) * spacing))
            }
            let after = try await coverage(store)
            XCTAssertLessThanOrEqual(after.changes - before.changes, 2, "\(spacing) ms apart")
            XCTAssertEqual(after.rows, 1, "\(spacing) ms apart: no row for an unchanged windowed scan")
            await store.close()
        }
    }

    func testACompleteScanAlwaysWritesItsRowAndAdvancesCompleteCoverage() async throws {
        let store = hmStore(historyTempDirectory())
        let wm = hmWatermark(id: 5, parsed: 100)
        try await store.applyScanCommand(hmScan(1, [hmFile(path, scan: 1, watermark: wm, [obs(1)])], complete: true, startedMs: t0))
        for i in 1...3 {   // unchanged, a second apart
            let at = t0 + Int64(i) * 1_000
            try await store.applyScanCommand(hmScan(UInt64(1 + i), [hmFile(path, scan: UInt64(1 + i), watermark: wm, [obs(1)])],
                                                    complete: true, startedMs: at))
        }
        let c = try await coverage(store)
        XCTAssertEqual(c.rows, 4, "every complete scan records its row, changed or not")
        XCTAssertEqual(c.complete, t0 + 3_000)
        XCTAssertEqual(c.latest, t0 + 3_000)
        let unchangedComplete = try await store.withDatabase {
            try $0.conn.queryInt("SELECT count(*) FROM ingest_scan WHERE complete = 1 AND files_written = 0")
        }
        XCTAssertEqual(unchangedComplete, 3)
    }

    /// `complete_scan_ms` advances only when every listed file was applied or
    /// skipped (equal watermark, or a newer scan of the path already applied).
    func testACompleteScanWithAFailedFileRecordsItsRowButNoCompleteCoverage() async throws {
        let store = hmStore(historyTempDirectory())
        let failAt = t0 + 7
        try await store.withDatabase { db in
            try db.conn.exec("""
                CREATE TEMP TRIGGER hm_fail BEFORE INSERT ON main.request_occurrence WHEN NEW.first_ms = \(failAt)
                BEGIN SELECT RAISE(ABORT, 'simulated failure'); END
                """)
        }
        let good = hmFile("/p/proj/s2.jsonl", scan: 1, watermark: hmWatermark(id: 6, parsed: 10), [obs(1)])
        let bad = hmFile(path, scan: 1, watermark: hmWatermark(id: 5, parsed: 10), [obs(7)])
        try await store.applyScanCommand(hmScan(1, [good, bad], complete: true, startedMs: t0))
        var c = try await coverage(store)
        let row = try await store.withDatabase { db in
            try db.conn.withStatement("SELECT complete, files, files_written FROM ingest_scan") { s -> [Int64] in
                _ = try s.step()
                return [s.int64(0), s.int64(1), s.int64(2)]
            }
        }
        XCTAssertNil(c.complete, "a failed file: the scan does not claim complete coverage")
        XCTAssertEqual(c.latest, t0)
        XCTAssertEqual(row, [0, 2, 0], "the good file shared the failed transaction: nothing written, row complete = 0")

        try await store.withDatabase { try $0.conn.exec("DROP TRIGGER hm_fail") }
        try await store.applyScanCommand(hmScan(2, [good, bad].map {
            HistoryFileBatch(path: $0.path, scan: 2, watermark: $0.watermark, delta: nil, allRequests: $0.allRequests, events: .empty)
        }, complete: true, startedMs: t0 + 1_000))
        c = try await coverage(store)
        XCTAssertEqual(c.complete, t0 + 1_000)
        XCTAssertEqual(c.rows, 2)
    }

    func testMaintenancePrunesOldScanRowsAndNothingElse() async throws {
        let clock = HMClock()
        let store = hmStore(historyTempDirectory(), clock: clock)
        let now = HistoryTime.ms(clock.get())
        let day: Int64 = 86_400_000
        try await store.applyScanCommand(hmScan(1, [hmFile(path, watermark: hmWatermark(id: 5, parsed: 10), [obs(1), obs(2)])],
                                                startedMs: now - 500 * day))
        let later = now + 2 * day   // maintenance is first due a day after the file was created
        try await store.withDatabase { db in
            for (age, complete) in [(20, 0), (10, 0), (401, 1), (399, 1), (13, 0)] {
                try db.conn.exec("""
                    INSERT INTO ingest_scan(started_ms, landed_ms, complete, files, files_written)
                    VALUES (\(later - Int64(age) * day), \(later - Int64(age) * day), \(complete), 1, 0)
                    """)
            }
        }
        let outcome = try await store.withDatabase { try $0.runMaintenance(now: HistoryTime.date(ms: later)) }
        XCTAssertTrue(outcome.ran)
        XCTAssertEqual(outcome.prunedWindowedScans, 2, "the 20-day row and the 500-day scan's own row")
        XCTAssertEqual(outcome.prunedCompleteScans, 1, "the 401-day complete row")
        let (left, requests, files) = try await store.withDatabase { db in
            (try db.conn.queryTexts("SELECT ((\(later) - started_ms) / \(day)) || ':' || complete FROM ingest_scan ORDER BY started_ms"),
             try db.conn.queryInt("SELECT count(*) FROM request"), try db.conn.queryInt("SELECT count(*) FROM source_file"))
        }
        XCTAssertEqual(left, ["399:1", "13:0", "10:0"])
        XCTAssertEqual(requests, 2, "request rows are never pruned, however old")
        XCTAssertEqual(files, 1)

        // nil retentions keep every scan row.
        let keep = hmStore(historyTempDirectory(), clock: clock,
                           retention: HistoryRetention(quotaSampleDays: nil, windowedScanDays: nil))
        try await keep.applyScanCommand(hmScan(1, [hmFile(path, watermark: hmWatermark(id: 5, parsed: 10), [obs(1)])],
                                               startedMs: now - 900 * day))
        let kept = try await keep.withDatabase { try $0.runMaintenance(now: HistoryTime.date(ms: later)) }
        XCTAssertEqual([kept.prunedWindowedScans, kept.prunedCompleteScans], [0, 0])
    }

    /// Through the real scanner: after the launch's complete scan, the app's
    /// per-minute windowed scans of unchanged transcripts write nothing.
    func testUnchangedWindowedScansThroughTheScannerLeaveTheDatabaseUntouched() async throws {
        let tree = try e2eTree()
        let main = tree.main()
        try tree.write([E2EFix.rec(1, E2EFix.t0, out: 3), E2EFix.rec(2, E2EFix.t0 + 1_000, out: 4)], to: main)
        try tree.write([E2EFix.rec(9, E2EFix.t0 + 500, out: 2, final: false, model: E2EFix.sonnet, sidechain: true)],
                       to: tree.subagent("a1"))
        let lane = E2ELane(tree: tree, name: "coverage")
        _ = await lane.scan(complete: true)
        await lane.store.flush()
        let before = try await coverage(lane.store)
        let started = Date()
        for _ in 0..<50 { _ = await lane.scan(complete: false) }
        await lane.store.flush()
        let after = try await coverage(lane.store)
        if Date().timeIntervalSince(started) < 55 {
            XCTAssertEqual(after.changes, before.changes, "50 unchanged windowed scans: total_changes unchanged")
        }
        XCTAssertEqual(after.rows, before.rows, "no ingest_scan row for an unchanged windowed scan")
        let opened = await lane.scanStats().filesOpened
        XCTAssertEqual(opened, 2, "only the first scan read the transcripts")
        await lane.close()
    }
}
