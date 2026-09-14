import Foundation
@testable import AgentMeter
import XCTest

final class LifetimeSpendTrackerTests: XCTestCase {
    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
    }

    private func bucket(_ day: Date, cost: Double, tokens: Int) -> UsageBucket {
        UsageBucket(day: day, inputTokens: tokens, outputTokens: 0,
                    cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: cost)
    }

    private func report(_ provider: Provider, _ buckets: [UsageBucket]) -> UsageReport {
        UsageReport(provider: provider, buckets: buckets, totalCostUSD: 0, totalTokens: 0)
    }

    private func completeReport(_ provider: Provider, _ buckets: [UsageBucket]) -> UsageReport {
        UsageReport(provider: provider, buckets: buckets, totalCostUSD: 0, totalTokens: 0,
                    byModel: [], isCompleteHistory: true)
    }

    func testSeedsFromFirstScan() {
        let merged = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [bucket(day(-1), cost: 10, tokens: 100),
                                       bucket(day(0), cost: 5, tokens: 50)])]
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .claude), 15, accuracy: 0.001)
    }

    func testDayGrowsWithFreshScan() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [bucket(day(0), cost: 5, tokens: 50)])]
        )
        let merged = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [report(.claude, [bucket(day(0), cost: 8, tokens: 80)])]
        )

        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .claude), 8, accuracy: 0.001)
    }

    func testDayNeverShrinksWhenLogsAgeOut() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [bucket(day(-2), cost: 20, tokens: 200)])]
        )
        let shrunk = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [report(.claude, [bucket(day(-2), cost: 3, tokens: 30)])]
        )
        let vanished = LifetimeSpendTracker.merge(
            existing: shrunk,
            reports: [report(.claude, [])]
        )

        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(vanished, provider: .claude), 20, accuracy: 0.001)
        XCTAssertEqual(vanished.first?.tokens, 200)
    }

    func testProvidersDoNotMix() {
        let merged = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [bucket(day(0), cost: 5, tokens: 50)]),
                      report(.codex, [bucket(day(0), cost: 7, tokens: 70)])]
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .claude), 5, accuracy: 0.001)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(merged, provider: .codex), 7, accuracy: 0.001)
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
        let records = [LifetimeDayRecord(provider: .claude, day: day(-1), costUSD: 12.5, tokens: 1_000)]
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
        let report = UsageReport(
            provider: .claude,
            buckets: [bucket(day(0), cost: 10, tokens: 100)],
            totalCostUSD: 25,
            totalTokens: 250
        )

        let records = LifetimeSpendTracker.bootstrapFromLegacyReports([report])

        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(records, provider: .claude), 25, accuracy: 0.001)
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens }, 250)
    }

    // MARK: - complete-history authority

    /// A day can be stored too high: resuming a session replays another file's
    /// messages, and every windowed scan that saw both files counted them twice.
    /// Only a scan that read every log file can walk that back.
    func testCompleteScanCorrectsAnInflatedDayDownward() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [bucket(day(-60), cost: 20, tokens: 200)])]
        )
        let corrected = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [completeReport(.claude, [bucket(day(-60), cost: 10, tokens: 100)])]
        )

        XCTAssertEqual(corrected.first?.tokens, 100)
        XCTAssertEqual(LifetimeSpendTracker.totalCostUSD(corrected, provider: .claude), 10, accuracy: 0.001)
    }

    func testCompleteScanLeavesDaysItDidNotObserveAlone() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.claude, [bucket(day(-90), cost: 30, tokens: 300),
                                       bucket(day(-1), cost: 5, tokens: 50)])]
        )
        // The old day's logs have since been pruned, so a full scan cannot see it.
        let merged = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [completeReport(.claude, [bucket(day(-1), cost: 5, tokens: 50)])]
        )

        XCTAssertEqual(merged.first { $0.day == day(-90) }?.tokens, 300,
                       "a pruned day survives in the ledger; the ledger is all that remembers it")
    }

    func testCompleteScanOfOneProviderDoesNotTouchAnother() {
        let seeded = LifetimeSpendTracker.merge(
            existing: [],
            reports: [report(.codex, [bucket(day(-5), cost: 9, tokens: 90)])]
        )
        let merged = LifetimeSpendTracker.merge(
            existing: seeded,
            reports: [completeReport(.claude, [bucket(day(-5), cost: 1, tokens: 10)])]
        )

        XCTAssertEqual(merged.first { $0.provider == .codex }?.tokens, 90)
    }

    // MARK: - dayPoints (heatmap/sparkline source)

    func testDayPointsKeepLedgerDaysMissingFromTheReport() {
        let ledger = [
            LifetimeDayRecord(provider: .claude, day: day(-90), costUSD: 3, tokens: 300),
            LifetimeDayRecord(provider: .claude, day: day(-1), costUSD: 1, tokens: 100)
        ]
        let points = LifetimeSpendTracker.dayPoints(
            ledger: ledger,
            report: report(.claude, [bucket(day(-1), cost: 1, tokens: 100)])
        )

        XCTAssertEqual(points.map(\.day), [day(-90), day(-1)])
        XCTAssertEqual(points.first?.tokens, 300)
    }

    /// The ledger is merged from the report before the UI reads either, so it is
    /// already at least as complete. Letting the report win would resurrect an
    /// over-count a complete scan just corrected, whenever the report on screen
    /// is the stale one restored from `last-state.json`.
    func testDayPointsLetTheLedgerOverrideAStaleReport() {
        let ledger = [LifetimeDayRecord(provider: .claude, day: day(0), costUSD: 2, tokens: 200)]
        let points = LifetimeSpendTracker.dayPoints(
            ledger: ledger,
            report: report(.claude, [bucket(day(0), cost: 9, tokens: 900)])
        )

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.tokens, 200)
        XCTAssertEqual(points.first?.costUSD ?? 0, 2, accuracy: 0.001)
    }

    /// ...but a lost or unreadable `lifetime-spend.json` must not blank the
    /// heatmap: days the ledger has never heard of still come from the report.
    func testDayPointsFallBackToTheReportForDaysTheLedgerLacks() {
        let points = LifetimeSpendTracker.dayPoints(
            ledger: [],
            report: report(.claude, [bucket(day(-2), cost: 4, tokens: 400),
                                     bucket(day(0), cost: 9, tokens: 900)])
        )

        XCTAssertEqual(points.map(\.tokens), [400, 900])
    }

    func testDayPointsIgnoreOtherProviders() {
        let ledger = [
            LifetimeDayRecord(provider: .codex, day: day(-3), costUSD: 5, tokens: 500),
            LifetimeDayRecord(provider: .claude, day: day(-2), costUSD: 4, tokens: 400)
        ]
        let points = LifetimeSpendTracker.dayPoints(ledger: ledger, report: report(.claude, []))

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
        ])
        XCTAssertEqual(records.count, 2, "expected a floor record alongside the real day")

        let points = LifetimeSpendTracker.dayPoints(ledger: records, report: report(.claude, []))

        XCTAssertEqual(points.map(\.day), [day(0)])
    }

    func testLifetimeSpendStoreRoundTripsRecords() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory
            .appendingPathComponent("agentmeter-lifetime-\(UUID().uuidString)")
            .appendingPathComponent("lifetime-spend.json")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let records = [LifetimeDayRecord(provider: .codex, day: day(-1), costUSD: 7.5, tokens: 123)]

        LifetimeSpendStore.save(records, to: url)

        XCTAssertEqual(LifetimeSpendStore.load(from: url), records)
    }
}
