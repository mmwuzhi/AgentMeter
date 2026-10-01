import Foundation
@testable import AgentMeter
import XCTest

/// Hand-made price tables. Under A, "m" costs 100,000 USD per 1M input tokens
/// (0.10 USD a token, so 100 tokens read as $10 and assertions stay in whole
/// dollars), "n" half that, and any other model is free. B doubles both, so
/// re-pricing a mapped day under B moves it by exactly its table-A cost.
private let tableA = priceTable(mPerMillion: 100_000)
private let tableB = priceTable(mPerMillion: 200_000)

private func priceTable(mPerMillion: Double) -> PriceTable {
    PriceTable(models: [
        "m": inputOnly(mPerMillion),
        "n": inputOnly(mPerMillion / 2),
        "default": inputOnly(0)
    ])
}

private func inputOnly(_ perMillion: Double) -> ModelPrice {
    ModelPrice(input: perMillion, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
}

final class LifetimeSpendTrackerTests: XCTestCase {
    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
    }

    private func counts(_ input: Int) -> TokenCounts {
        TokenCounts(input: input)
    }

    private func usage(_ day: Date, _ input: Int, model: String = "m") -> DayModelUsage {
        DayModelUsage(day: day, model: model, counts: counts(input))
    }

    /// A bucket as an older build's cache carries it: scan-time dollars and no
    /// counts by model.
    private func bucket(_ day: Date, cost: Double, tokens: Int) -> UsageBucket {
        UsageBucket(day: day, inputTokens: tokens, outputTokens: 0,
                    cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: cost)
    }

    /// A report in this build's shape: `dayModels` carry the counts, and the
    /// compat fields (`buckets`, `totalCostUSD`, `totalTokens`) are derived from
    /// them under `table`, the way `UsageRollup` does, so they never disagree.
    private func report(_ provider: Provider, _ entries: [DayModelUsage],
                        complete: Bool = false, table: PriceTable = tableA) -> UsageReport {
        var byDay: [Date: UsageBucket] = [:]
        for entry in entries {
            var bucket = byDay[entry.day] ?? UsageBucket(
                day: entry.day, inputTokens: 0, outputTokens: 0,
                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: 0)
            bucket.inputTokens += entry.counts.input
            bucket.outputTokens += entry.counts.output
            bucket.cacheWrite5m += entry.counts.cacheWrite5m
            bucket.cacheWrite1h += entry.counts.cacheWrite1h
            bucket.cacheRead += entry.counts.cacheRead
            bucket.costUSD += table.cost(model: entry.model, counts: entry.counts)
            byDay[entry.day] = bucket
        }
        let buckets = byDay.values.sorted { $0.day < $1.day }
        return UsageReport(provider: provider,
                           buckets: buckets,
                           totalCostUSD: buckets.reduce(0) { $0 + $1.costUSD },
                           totalTokens: buckets.reduce(0) { $0 + $1.totalTokens },
                           dayModels: entries,
                           isCompleteHistory: complete)
    }

    private func assertDollars(_ actual: [Double], _ expected: [Double],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual) vs \(expected)", file: file, line: line)
        for (value, wanted) in zip(actual, expected) {
            XCTAssertEqual(value, wanted, accuracy: 1e-9, "\(actual) vs \(expected)", file: file, line: line)
        }
    }

    func testSeedsFromFirstScan() {
        let merged = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [usage(day(-1), 100), usage(day(0), 50)])],
            table: tableA
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.tokens), [100, 50])
        XCTAssertEqual(merged.map(\.models), [["m": counts(100)], ["m": counts(50)]] as [[String: TokenCounts]?])
        assertDollars(merged.map(\.costUSD), [10, 5])
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .claude, table: tableA), 15, accuracy: 1e-9)
    }

    func testDayGrowsWithFreshScan() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [usage(day(0), 50)])],
            table: tableA
        )
        let merged = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [report(.claude, [usage(day(0), 80)])],
            table: tableA
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.tokens, 80)
        XCTAssertEqual(merged.first?.models, ["m": counts(80)])
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .claude, table: tableA), 8, accuracy: 1e-9)
    }

    func testDayNeverShrinksWhenLogsAgeOut() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [usage(day(-2), 200)])],
            table: tableA
        )
        let shrunk = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [report(.claude, [usage(day(-2), 30)])],
            table: tableA
        )
        let vanished = LifetimeSpendTracker.merge(
            existing: shrunk,
            reports: [report(.claude, [])],
            table: tableA
        )

        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(vanished, provider: .claude, table: tableA), 20, accuracy: 1e-9)
        XCTAssertEqual(vanished.first?.tokens, 200)
        XCTAssertEqual(vanished.first?.models, ["m": counts(200)])
    }

    func testProvidersDoNotMix() {
        let merged = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [usage(day(0), 50)]),
                      report(.codex, [usage(day(0), 70)])],
            table: tableA
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .claude, table: tableA), 5, accuracy: 1e-9)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .codex, table: tableA), 7, accuracy: 1e-9)
    }

    func testSnapshotDecodesCacheWithoutLifetimeSpend() throws {
        struct OldSnapshot: Encodable {
            var codex: ProviderState
            var claude: ProviderState
            var copilot: ProviderState
        }

        let snapshot = OldSnapshot(
            codex: ProviderState(provider: .codex, quota: .unavailable(.codex, note: "old"), usage: .empty(.codex)),
            claude: ProviderState(provider: .claude, quota: .unavailable(.claude, note: "old"), usage: .empty(.claude)),
            copilot: ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "old"), usage: .empty(.copilot))
        )
        let data = try JSONEncoder().encode(snapshot)

        let decoded = try JSONDecoder().decode(StateCache.Snapshot.self, from: data)

        XCTAssertTrue(decoded.lifetimeSpend.isEmpty)
    }

    func testSnapshotRoundTripsLifetimeSpend() throws {
        let records = [
            LifetimeDayRecord(provider: .claude, day: day(-2), costUSD: 12.5, tokens: 1_000),
            LifetimeDayRecord(provider: .claude, day: day(-1), costUSD: 12.5, tokens: 150,
                              models: ["m": counts(100), "n": counts(50)])
        ]
        let snapshot = StateCache.Snapshot(
            codex: ProviderState(provider: .codex, quota: .unavailable(.codex, note: "old"), usage: .empty(.codex)),
            claude: ProviderState(provider: .claude, quota: .unavailable(.claude, note: "old"), usage: .empty(.claude)),
            copilot: ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "old"), usage: .empty(.copilot)),
            lifetimeSpend: records
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(StateCache.Snapshot.self, from: data)

        XCTAssertEqual(decoded.lifetimeSpend, records)
    }

    func testBootstrapPreservesLegacyTotalAboveBucketsAsFloor() {
        let restored = UsageReport(
            provider: .claude,
            buckets: [bucket(day(0), cost: 10, tokens: 100)],
            totalCostUSD: 25,
            totalTokens: 250
        )

        let records = LifetimeSpendTracker.bootstrapFromLegacyReports([restored], table: tableA)

        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(records, provider: .claude, table: tableA), 25, accuracy: 1e-9)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(records, provider: .claude, table: tableB), 25, accuracy: 1e-9,
                       "a floor is frozen dollars, whatever table arrives later")
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens }, 250)
    }

    // MARK: - complete-history authority

    /// A day can be stored too high: resuming a session replays another file's
    /// messages, and every windowed scan that saw both files counted them twice.
    /// Only a scan that read every log file can walk that back.
    func testCompleteScanCorrectsAnInflatedDayDownward() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [usage(day(-60), 200)])],
            table: tableA
        )
        let corrected = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [report(.claude, [usage(day(-60), 100)], complete: true)],
            table: tableA
        )

        XCTAssertEqual(corrected.first?.tokens, 100)
        XCTAssertEqual(corrected.first?.models, ["m": counts(100)])
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(corrected, provider: .claude, table: tableA), 10, accuracy: 1e-9)
    }

    func testCompleteScanLeavesDaysItDidNotObserveAlone() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [usage(day(-90), 300), usage(day(-1), 50)])],
            table: tableA
        )
        // The old day's logs have since been pruned, so a full scan cannot see it.
        let merged = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [report(.claude, [usage(day(-1), 50)], complete: true)],
            table: tableA
        )

        XCTAssertEqual(merged.first { $0.day == day(-90) }?.tokens, 300,
                       "a pruned day survives in the ledger; the ledger is all that remembers it")
    }

    func testCompleteScanOfOneProviderDoesNotTouchAnother() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.codex, [usage(day(-5), 90)])],
            table: tableA
        )
        let merged = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [report(.claude, [usage(day(-5), 10)], complete: true)],
            table: tableA
        )

        XCTAssertEqual(merged.first { $0.provider == .codex }?.tokens, 90)
    }

    // MARK: - dollars are computed under one table, never read back

    /// A mapped record's stored `costUSD` is a compat figure for older builds;
    /// this build prices the counts under whatever table it is handed. A legacy
    /// record has nothing but its dollars, so those are what it contributes,
    /// under any table.
    func testTotalFollowsTheTableNotTheStoredDollars() {
        let mappedCounts: [String: TokenCounts] = ["m": counts(100)]
        let mapped = LifetimeDayRecord(provider: .claude, day: day(-1), costUSD: 999, tokens: 100,
                                       models: mappedCounts)
        let legacy = LifetimeDayRecord(provider: .claude, day: day(-2), costUSD: 7, tokens: 70)

        let underA = LifetimeSpendTracker.totalCostUSD([legacy, mapped], provider: .claude, table: tableA)
        let underB = LifetimeSpendTracker.totalCostUSD([legacy, mapped], provider: .claude, table: tableB)

        XCTAssertEqual(underA, 17, accuracy: 1e-9)
        XCTAssertEqual(underB, 27, accuracy: 1e-9)
        XCTAssertEqual(underB - underA, tableB.cost(mappedCounts) - tableA.cost(mappedCounts), accuracy: 1e-9,
                       "a table change moves the total by exactly the re-pricing of the mapped day")
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD([legacy], provider: .claude, table: tableA), 7, accuracy: 1e-9)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD([legacy], provider: .claude, table: tableB), 7, accuracy: 1e-9)
    }

    /// `lifetime-spend.json` as a build before `models` wrote it: `day` is
    /// seconds since the 2001 reference date (the store's plain `JSONDecoder`),
    /// there is no `models` key, and the dollars are all the record knows. The
    /// compat shape is pinned both ways so that build keeps reading ours.
    func testLedgerJSONFromAnOlderBuildDecodesAsFrozenDollars() throws {
        let json = Data(#"[{"provider":"claude","day":800000000,"costUSD":12.5,"tokens":1000}]"#.utf8)

        let decoded = try JSONDecoder().decode([LifetimeDayRecord].self, from: json)

        XCTAssertEqual(decoded, [
            LifetimeDayRecord(provider: .claude, day: Date(timeIntervalSinceReferenceDate: 800_000_000),
                              costUSD: 12.5, tokens: 1_000)
        ])
        XCTAssertNil(decoded.first?.models)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(decoded, provider: .claude, table: tableA), 12.5, accuracy: 1e-9)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(decoded, provider: .claude, table: tableB), 12.5, accuracy: 1e-9)

        let encoded = try JSONEncoder().encode(decoded)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let record = try XCTUnwrap(objects.first)
        XCTAssertNil(record["models"])
        XCTAssertEqual(Set(record.keys), ["provider", "day", "costUSD", "tokens"])
    }

    /// A day stored by an older build is dollars frozen under whatever table
    /// that build held. The first windowed scan that sees at least as many
    /// tokens replaces it with counts, which price like every other day from
    /// then on; a scan that sees fewer (its window is aging past the day)
    /// changes nothing, because tokens decide, not dollars.
    func testWindowedMergeAdoptsCountsForALegacyDay() {
        let legacy = [LifetimeDayRecord(provider: .claude, day: day(-3), costUSD: 99, tokens: 100)]

        let adopted = LifetimeSpendTracker.merge(
            existing: legacy,
            reports: [report(.claude, [usage(day(-3), 100)])],
            table: tableA
        )

        XCTAssertEqual(adopted.count, 1)
        XCTAssertEqual(adopted.first?.models, ["m": counts(100)])
        XCTAssertEqual(adopted.first?.tokens, 100)
        XCTAssertEqual(adopted.first?.costUSD ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(adopted, provider: .claude, table: tableA), 10, accuracy: 1e-9)

        let kept = LifetimeSpendTracker.merge(
            existing: legacy,
            reports: [report(.claude, [usage(day(-3), 90)])],
            table: tableA
        )

        XCTAssertEqual(kept, legacy, "fewer tokens than stored: the legacy record stays exactly as it was")
    }

    /// The stored `costUSD` only exists for older builds reading the ledger,
    /// but it must be the current table's price on every day that holds counts,
    /// whether or not the latest scan observed that day; otherwise such a build
    /// adds up days priced under different tables, the drift this change
    /// removes. A legacy day has no counts to re-price and keeps its dollars.
    func testCompleteScanRepricesEveryObservedDay() {
        let legacy = LifetimeDayRecord(provider: .claude, day: day(-90), costUSD: 7, tokens: 70)
        let first = LifetimeSpendTracker.merge(
            existing: [legacy],
            reports: [report(.claude, [usage(day(-2), 100), usage(day(-1), 50)], complete: true)],
            table: tableA
        )

        XCTAssertEqual(first.map(\.tokens), [70, 100, 50])
        assertDollars(first.map(\.costUSD), [7, 10, 5])
        for record in first {
            guard let models = record.models else { continue }
            XCTAssertEqual(record.costUSD, tableA.cost(models), accuracy: 1e-9)
        }
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(first, provider: .claude, table: tableA), 22, accuracy: 1e-9)

        // No new usage: the next windowed scan repeats day(-1)'s counts and no
        // longer reaches day(-2), but the process now holds table B.
        let repriced = LifetimeSpendTracker.merge(
            existing: first,
            reports: [report(.claude, [usage(day(-1), 50)], table: tableB)],
            table: tableB
        )

        XCTAssertEqual(repriced.map(\.tokens), [70, 100, 50])
        assertDollars(repriced.map(\.costUSD), [7, 20, 10])
        XCTAssertNil(repriced.first?.models, "a legacy day has no counts to re-price")
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(repriced, provider: .claude, table: tableB), 37, accuracy: 1e-9)
    }

    /// The bug this change fixes: the footer's all-time figure and the daily
    /// points it is supposed to add up came from different tables (dollars
    /// frozen in the ledger by an earlier scan versus the table on screen) and
    /// drifted $1,400 apart with no usage behind it. Both now price the same
    /// counts under the table they are handed, so they agree under any table.
    func testAllTimeTotalEqualsTheSumOfDailyPointsUnderOneTable() {
        let legacy = LifetimeDayRecord(provider: .claude, day: day(-200), costUSD: 7, tokens: 70)
        let complete = report(.claude, [usage(day(-40), 300),
                                        usage(day(-3), 100), usage(day(-3), 40, model: "n")],
                              complete: true)
        let windowed = report(.claude, [usage(day(-3), 100), usage(day(-3), 40, model: "n"),
                                        usage(day(-1), 60), usage(day(0), 25)])
        let afterComplete = LifetimeSpendTracker.merge(existing: [legacy], reports: [complete], table: tableA)
        let ledger = LifetimeSpendTracker.merge(existing: afterComplete, reports: [windowed], table: tableA)
        XCTAssertEqual(ledger.count, 5)

        let totalA = LifetimeSpendTracker.totalCostUSD(ledger, provider: .claude, table: tableA)
        let totalB = LifetimeSpendTracker.totalCostUSD(ledger, provider: .claude, table: tableB)
        let pointsA = LifetimeSpendTracker.dayPoints(ledger: ledger, report: windowed, table: tableA)
        let pointsB = LifetimeSpendTracker.dayPoints(ledger: ledger, report: windowed, table: tableB)

        XCTAssertEqual(totalA, pointsA.map(\.costUSD).reduce(0, +), accuracy: 1e-9)
        XCTAssertEqual(totalB, pointsB.map(\.costUSD).reduce(0, +), accuracy: 1e-9)
        // The two tables really do disagree, so the equalities above are not vacuous.
        XCTAssertEqual(totalA, 57.5, accuracy: 1e-9)
        XCTAssertEqual(totalB, 108, accuracy: 1e-9)
    }

    /// A report restored from an older build's `last-state.json` has buckets
    /// but no `dayModels`: its scan-time dollars are all there is to keep.
    func testReportWithoutDayModelsMergesFromBuckets() {
        let restored = UsageReport(
            provider: .claude,
            buckets: [bucket(day(-1), cost: 3, tokens: 30)],
            totalCostUSD: 3,
            totalTokens: 30
        )
        XCTAssertTrue(restored.dayModels.isEmpty)

        let merged = LifetimeSpendTracker.merge(existing: [], reports: [restored], table: tableA)

        XCTAssertEqual(merged, [LifetimeDayRecord(provider: .claude, day: day(-1), costUSD: 3, tokens: 30, models: nil)])
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .claude, table: tableB), 3, accuracy: 1e-9)
    }

    // MARK: - dayPoints (heatmap/sparkline source)

    func testDayPointsKeepLedgerDaysMissingFromTheReport() {
        let ledger = [
            LifetimeDayRecord(provider: .claude, day: day(-90), costUSD: 3, tokens: 300),
            LifetimeDayRecord(provider: .claude, day: day(-1), costUSD: 10, tokens: 100, models: ["m": counts(100)])
        ]
        let points = LifetimeSpendTracker.dayPoints(
            ledger: ledger,
            report: report(.claude, [usage(day(-1), 100)]),
            table: tableA
        )

        XCTAssertEqual(points.map(\.day), [day(-90), day(-1)])
        XCTAssertEqual(points.map(\.tokens), [300, 100])
        assertDollars(points.map(\.costUSD), [3, 10])
    }

    /// The ledger is merged from the report before the UI reads either, so it is
    /// already at least as complete. Letting the report win would resurrect an
    /// over-count a complete scan just corrected, whenever the report on screen
    /// is the stale one restored from `last-state.json`.
    func testDayPointsLetTheLedgerOverrideAStaleReport() {
        let ledger = [LifetimeDayRecord(provider: .claude, day: day(0), costUSD: 999, tokens: 200,
                                        models: ["m": counts(200)])]
        let points = LifetimeSpendTracker.dayPoints(
            ledger: ledger,
            report: report(.claude, [usage(day(0), 900)]),
            table: tableA
        )

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.tokens, 200)
        XCTAssertEqual(points.first?.costUSD ?? 0, 20, accuracy: 1e-9,
                       "the ledger's counts under the table, not its stored dollars")
    }

    /// ...but a lost or unreadable `lifetime-spend.json` must not blank the
    /// heatmap: days the ledger has never heard of still come from the report,
    /// with the models of one day folded together.
    func testDayPointsFallBackToTheReportForDaysTheLedgerLacks() {
        let points = LifetimeSpendTracker.dayPoints(
            ledger: [],
            report: report(.claude, [usage(day(-2), 400),
                                     usage(day(0), 500), usage(day(0), 400, model: "n")]),
            table: tableA
        )

        XCTAssertEqual(points.map(\.day), [day(-2), day(0)])
        XCTAssertEqual(points.map(\.tokens), [400, 900])
        assertDollars(points.map(\.costUSD), [40, 70])
    }

    func testDayPointsPriceAReportWithoutDayModelsFromItsBuckets() {
        let restored = UsageReport(
            provider: .claude,
            buckets: [bucket(day(-2), cost: 4, tokens: 400), bucket(day(0), cost: 9, tokens: 900)],
            totalCostUSD: 13,
            totalTokens: 1_300
        )

        let points = LifetimeSpendTracker.dayPoints(ledger: [], report: restored, table: tableB)

        XCTAssertEqual(points.map(\.day), [day(-2), day(0)])
        XCTAssertEqual(points.map(\.tokens), [400, 900])
        assertDollars(points.map(\.costUSD), [4, 9])
    }

    func testDayPointsIgnoreOtherProviders() {
        let ledger = [
            LifetimeDayRecord(provider: .codex, day: day(-3), costUSD: 5, tokens: 500),
            LifetimeDayRecord(provider: .claude, day: day(-2), costUSD: 4, tokens: 400)
        ]
        let points = LifetimeSpendTracker.dayPoints(ledger: ledger, report: report(.claude, []), table: tableA)

        XCTAssertEqual(points.map(\.day), [day(-2)])
    }

    /// `bootstrapFromLegacyReports` parks the un-attributable remainder on a
    /// synthetic 2001-01-01 day. Plotting it would invent activity and, worse,
    /// dominate the color scale.
    func testDayPointsDropTheSyntheticLegacyFloorRecord() {
        let records = LifetimeSpendTracker.bootstrapFromLegacyReports([
            UsageReport(provider: .claude,
                        buckets: [bucket(day(0), cost: 10, tokens: 100)],
                        totalCostUSD: 25, totalTokens: 250)
        ], table: tableA)
        XCTAssertEqual(records.count, 2, "expected a floor record alongside the real day")

        let points = LifetimeSpendTracker.dayPoints(ledger: records, report: report(.claude, []), table: tableA)

        XCTAssertEqual(points.map(\.day), [day(0)])
    }

    func testLifetimeSpendStoreRoundTripsRecords() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory
            .appendingPathComponent("agentmeter-lifetime-\(UUID().uuidString)")
            .appendingPathComponent("lifetime-spend.json")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let records = [
            LifetimeDayRecord(provider: .codex, day: day(-2), costUSD: 7.5, tokens: 123),
            LifetimeDayRecord(provider: .codex, day: day(-1), costUSD: 15, tokens: 150,
                              models: ["m": counts(100), "n": counts(50)])
        ]

        LifetimeSpendStore.save(records, to: url)

        XCTAssertEqual(LifetimeSpendStore.load(from: url), records)
    }
}
