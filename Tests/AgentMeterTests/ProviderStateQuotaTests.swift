import Foundation
@testable import AgentMeter
import XCTest

final class ProviderStateQuotaTests: XCTestCase {
    func testUnavailableQuotaKeepsPreviousUsableLiveWindow() {
        let now = Date()
        let previousQuota = QuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 42,
                    resetsAt: now.addingTimeInterval(60)
                )
            ],
            source: .oauth,
            planType: "pro",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let state = ProviderState(
            provider: .claude,
            quota: .unavailable(.claude, note: "Live quota unavailable"),
            usage: .empty(.claude)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, previousQuota)
    }

    func testUnavailableQuotaDoesNotKeepExpiredLiveWindow() {
        let now = Date()
        let previousQuota = QuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 42,
                    resetsAt: now.addingTimeInterval(-60)
                )
            ],
            source: .oauth,
            planType: "pro",
            fetchedAt: now.addingTimeInterval(-120),
            note: nil
        )
        let unavailableQuota = QuotaSnapshot.unavailable(.claude, note: "Live quota unavailable")
        let state = ProviderState(
            provider: .claude,
            quota: unavailableQuota,
            usage: .empty(.claude)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, unavailableQuota)
    }

    func testLiveQuotaReplacesPreviousQuota() {
        let now = Date()
        let previousQuota = QuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 42,
                    resetsAt: now.addingTimeInterval(60)
                )
            ],
            source: .oauth,
            planType: "pro",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let freshQuota = QuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(
                    id: "seven_day",
                    label: "Weekly",
                    usedPercent: 25,
                    resetsAt: now.addingTimeInterval(600)
                )
            ],
            source: .cli,
            planType: nil,
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(
            provider: .claude,
            quota: freshQuota,
            usage: .empty(.claude)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, freshQuota)
    }

    func testCodexRolloutFallbackKeepsPreviousUsableAppServerQuota() {
        let now = Date()
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 12,
                    resetsAt: now.addingTimeInterval(600)
                )
            ],
            source: .appServer,
            planType: "pro",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let rolloutQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 45,
                    resetsAt: now.addingTimeInterval(600)
                )
            ],
            source: .rolloutFile,
            planType: "pro",
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(
            provider: .codex,
            quota: rolloutQuota,
            usage: .empty(.codex)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, previousQuota)
    }

    func testCodexRolloutFallbackReplacesExpiredAppServerQuota() {
        let now = Date()
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 12,
                    resetsAt: now.addingTimeInterval(-60)
                )
            ],
            source: .appServer,
            planType: "pro",
            fetchedAt: now.addingTimeInterval(-3600),
            note: nil
        )
        let rolloutQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 45,
                    resetsAt: now.addingTimeInterval(600)
                )
            ],
            source: .rolloutFile,
            planType: "pro",
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(
            provider: .codex,
            quota: rolloutQuota,
            usage: .empty(.codex)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, rolloutQuota)
    }

    func testCodexAppServerQuotaReplacesPreviousRolloutQuota() {
        let now = Date()
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 45,
                    resetsAt: now.addingTimeInterval(600)
                )
            ],
            source: .rolloutFile,
            planType: "pro",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let appServerQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "five_hour",
                    label: "5-hour",
                    usedPercent: 12,
                    resetsAt: now.addingTimeInterval(600)
                )
            ],
            source: .appServer,
            planType: "pro",
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(
            provider: .codex,
            quota: appServerQuota,
            usage: .empty(.codex)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, appServerQuota)
    }
}
