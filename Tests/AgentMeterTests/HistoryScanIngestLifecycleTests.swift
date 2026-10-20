import Foundation
import XCTest
@testable import AgentMeter

/// What happens to ingested data across corruption, a newer schema,
/// maintenance, integrity checks and the explicit request rebuild.
final class HistoryScanIngestLifecycleTests: XCTestCase {
    let mainPath = "/p/proj/s1.jsonl"
    let agentPath = "/p/proj/s1/subagents/agent-x.jsonl"

    func observations(_ range: Range<Int>, first: Int64 = 1_789_000_000_000) -> [RequestObservation] {
        range.map { n in
            hmObs(hmKey(n), [hmPart(n % 3 == 0 ? "fable" : "opus", output: n % 50, cacheRead: n)], .final,
                  first: first + Int64(n) * 1_000, last: first + Int64(n) * 1_000 + 200, final: first + Int64(n) * 1_000,
                  cc: "2.1.\(n % 4)")
        }
    }

    func scan(_ ticket: UInt64, _ files: [(String, UInt64, [RequestObservation])], events: HistoryFileEvents = .empty)
        -> HistoryScanBatch {
        hmScan(ticket, files.map { hmFile($0.0, scan: ticket, watermark: hmWatermark(id: $0.1, parsed: Int64($0.2.count)),
                                          $0.2, events: events) }, complete: true, startedMs: Int64(ticket) * 1_000)
    }

    func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil) ?? 0
    }

    func smash(_ url: URL, pages: StrideTo<Int>, bytes: [UInt8] = [0xFF]) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        for page in pages {
            try handle.seek(toOffset: UInt64(page * 4_096))
            try handle.write(contentsOf: Data(bytes))
        }
    }

    // MARK: Corruption

    func testCorruptionMidIngestRebuildsAndASecondFullIngestRestoresTheRows() async throws {
        let dir = historyTempDirectory()
        let births = HMBirths()
        births.set([mainPath: 100, agentPath: 200])
        let first = scan(1, [(mainPath, 11, observations(0..<6_000))])
        let second = scan(2, [(agentPath, 12, observations(6_000..<6_500) + observations(0..<10))])
        let reference = hmStore(historyTempDirectory("reference"), births: births)
        try await reference.applyScanCommand(first)
        try await reference.applyScanCommand(second)
        let want = try await reference.logicalDump()

        var store = hmStore(dir, births: births)
        try await store.applyScanCommand(first)
        await store.close()
        let url = dir.appendingPathComponent(HistoryDatabase.fileName)
        try smash(url, pages: stride(from: 40, to: fileSize(url) / 4_096, by: 2))

        store = hmStore(dir, births: births)
        let before = await store.status()
        XCTAssertEqual(before, .ready, "open cannot notice a smashed row page")
        do {
            try await store.applyScanCommand(second)
            XCTFail("the ingest must run into the damage")
        } catch HistoryStoreError.rebuilt {}
        let status = await store.status()
        guard case .rebuilt = status else { return XCTFail("\(status)") }
        // Watermarks went with the old file: the next full scan re-ingests every file whole.
        try await store.applyScanCommand(scan(3, [(mainPath, 11, observations(0..<6_000))]))
        try await store.applyScanCommand(scan(4, [(agentPath, 12, observations(6_000..<6_500) + observations(0..<10))]))
        let got = try await store.logicalDump()
        XCTAssertEqual(got, want, hmDiff(got, want))
    }

    func testANewerSchemaIsNeverWritten() async throws {
        let dir = historyTempDirectory()
        let db = try HistoryDatabase.open(historyConfig(dir))
        try db.conn.setPragma("user_version", "99")
        db.close()
        let url = dir.appendingPathComponent(HistoryDatabase.fileName)
        let bytes = try Data(contentsOf: url)
        let store = hmStore(dir)
        store.submit(scan: scan(1, [(mainPath, 11, observations(0..<5))]))
        store.submit(quota: [QuotaSampleRow(provider: .claude, windowID: "five_hour", source: .oauth, readingMs: 1,
                                            fetchedMs: nil, cachedMs: nil, recordedMs: 1, usedPercent: 1, resetsAtMs: nil,
                                            cycleSeconds: nil, isModelScoped: nil, isOneTimeCredit: nil, isActive: nil,
                                            severity: nil, lockedReason: nil, scopeName: nil, shareUsedOfWeekly: nil,
                                            shareAllowanceOfWeekly: nil, plan: nil, tier: nil, flags: [])])
        await store.flush()
        let stats = await store.statistics()
        XCTAssertEqual(stats.droppedSubmissions, 2)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "not one byte changed")
    }

    // MARK: Maintenance

    func quotaRow(_ window: String, at ms: Int64) -> QuotaSampleRow {
        QuotaSampleRow(provider: .claude, windowID: window, source: .oauth, readingMs: ms, fetchedMs: ms, cachedMs: nil,
                       recordedMs: ms, usedPercent: 5, resetsAtMs: nil, cycleSeconds: nil, isModelScoped: nil,
                       isOneTimeCredit: nil, isActive: nil, severity: nil, lockedReason: nil, scopeName: nil,
                       shareUsedOfWeekly: nil, shareAllowanceOfWeekly: nil, plan: nil, tier: nil, flags: [])
    }

    func counts(_ store: HistoryStore) async throws -> [String: Int] {
        try await store.historyStatistics().rowCounts.filter { ["quota_sample", "reset_event", "request"].contains($0.key) }
    }

    func testMaintenancePrunesOldQuotaRowsOnceADayAndNeverRequests() async throws {
        let clock = HMClock()
        let store = hmStore(historyTempDirectory(), clock: clock, retention: HistoryRetention(quotaSampleDays: 400))
        let now = HistoryTime.ms(clock.get())
        let day: Int64 = 86_400_000
        try await store.applyScanCommand(scan(1, [(mainPath, 11, observations(0..<3, first: now - 500 * day))]))
        try await store.applyQuotaCommand([quotaRow("w_old", at: now - 401 * day), quotaRow("w_recent", at: now - day)])
        try await store.withDatabase { db in
            try db.conn.exec("""
                INSERT INTO reset_event VALUES ('claude', 'w_old', 'early_drop', \(now - 401 * day), \(now - 402 * day),
                    50, 10, NULL, NULL, 1)
                """)
        }
        clock.advance(25 * 3_600)
        try await store.applyScanCommand(scan(2, []))
        var c = try await counts(store)
        XCTAssertEqual(c, ["quota_sample": 1, "reset_event": 0, "request": 3], "old samples pruned, old requests kept")
        try await store.applyQuotaCommand([quotaRow("w_old2", at: now - 450 * day)])
        clock.advance(3_600)
        try await store.applyScanCommand(scan(3, []))
        c = try await counts(store)
        XCTAssertEqual(c["quota_sample"], 2, "maintenance runs at most once a day")
        let kept = hmStore(historyTempDirectory(), clock: clock, retention: HistoryRetention(quotaSampleDays: nil))
        try await kept.applyQuotaCommand([quotaRow("w_old", at: now - 4_000 * day)])
        clock.advance(2 * 86_400)
        try await kept.applyScanCommand(scan(1, []))
        c = try await counts(kept)
        XCTAssertEqual(c["quota_sample"], 1, "nil retention keeps everything")
    }

    func testAWeeklyIntegrityCheckRunsAndAFailedOneRebuilds() async throws {
        let clock = HMClock()
        let dir = historyTempDirectory()
        var store = hmStore(dir, clock: clock)
        try await store.applyScanCommand(scan(1, [(mainPath, 11, observations(0..<5))]))
        clock.advance(8 * 86_400)
        try await store.applyScanCommand(scan(2, []))
        var stats = await store.statistics()
        XCTAssertEqual(stats.integrityChecks, 1)
        XCTAssertEqual(stats.failedIntegrityChecks, 0)
        clock.advance(86_400)
        try await store.applyScanCommand(scan(3, []))
        stats = await store.statistics()
        XCTAssertEqual(stats.integrityChecks, 1, "daily maintenance, weekly check")

        // A damaged page the ingest never reads: only the check finds it.
        try await store.withDatabase { try historyPopulate($0, rows: 12_000) }
        await store.close()
        let url = dir.appendingPathComponent(HistoryDatabase.fileName)
        try smash(url, pages: stride(from: fileSize(url) / 4_096 / 2, to: fileSize(url) / 4_096 / 2 + 1, by: 1),
                  bytes: [0xFF, 0xFF, 0xFF, 0xFF])
        store = hmStore(dir, clock: clock)
        clock.advance(8 * 86_400)
        try await store.applyScanCommand(scan(4, []))
        stats = await store.statistics()
        XCTAssertEqual(stats.failedIntegrityChecks, 1)
        let status = await store.status()
        guard case .rebuilt = status else { return XCTFail("\(status)") }
    }

    func testAnUncleanShutdownTriggersOneIntegrityCheck() async throws {
        let dir = historyTempDirectory()
        var config = historyConfig(dir)
        config.options.walAutocheckpointPages = 0
        let writer = try HistoryDatabase.open(config)
        try historyPopulate(writer, rows: 2_000)
        let image = historyTempDirectory("image")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.copyItem(atPath: config.url.path + suffix,
                                              toPath: image.appendingPathComponent(HistoryDatabase.fileName + suffix).path)
        }
        writer.close()
        let store = hmStore(image)
        try await store.applyScanCommand(scan(1, [(mainPath, 11, observations(0..<3))]))
        try await store.applyScanCommand(scan(2, []))
        let stats = await store.statistics()
        XCTAssertEqual(stats.integrityChecks, 1)
        XCTAssertEqual(stats.failedIntegrityChecks, 0)
    }

    // MARK: Explicit request rebuild

    func testRebuildRequestsClearsTheRequestTablesAndAReingestRestoresTheIdenticalDump() async throws {
        let births = HMBirths()
        births.set([mainPath: 5])
        let store = hmStore(historyTempDirectory(), births: births)
        let events = HistoryFileEvents(compactEvents: [CompactEventObservation(uuid: "c", tsMs: 1, trigger: "auto",
                                                                               preTokens: 1, postTokens: 1)],
                                       firstCwd: "/work", firstCwdMs: 3)
        let first = scan(1, [(mainPath, 11, observations(0..<50)), (agentPath, 12, observations(40..<60))], events: events)
        try await store.applyScanCommand(first)
        let want = try await store.logicalDump()
        store.submitRebuildRequests()
        await store.flush()
        let stats = try await store.historyStatistics()
        XCTAssertEqual(stats.rowCounts["request"], 0)
        XCTAssertEqual(stats.rowCounts["request_occurrence"], 0)
        XCTAssertEqual(stats.rowCounts["source_file"], 2, "files, births, sessions and events stay")
        let watermarks = try await store.withDatabase { try $0.conn.queryInt("SELECT count(*) FROM source_file WHERE parsed_bytes IS NOT NULL") }
        XCTAssertEqual(watermarks, 0)
        try await store.applyScanCommand(scan(2, [(mainPath, 11, observations(0..<50)), (agentPath, 12, observations(40..<60))],
                                              events: events))
        let got = try await store.logicalDump()
        XCTAssertEqual(got, want, hmDiff(got, want))
    }
}
