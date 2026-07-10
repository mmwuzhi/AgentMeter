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
