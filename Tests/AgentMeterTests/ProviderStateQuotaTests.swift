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

        XCTAssertEqual(result.quota.windows, previousQuota.windows)
        XCTAssertEqual(result.quota.source, rolloutQuota.source)
        XCTAssertEqual(result.quota.fetchedAt, rolloutQuota.fetchedAt)
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

    func testCodexSameEpochRecoverySpikeKeepsPreviousQuota() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "primary",
                    label: "5-hour",
                    usedPercent: 88,
                    resetsAt: reset
                )
            ],
            source: .oauth,
            planType: "plus",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let spikingQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "primary",
                    label: "5-hour",
                    usedPercent: 5,
                    resetsAt: reset.addingTimeInterval(15)
                )
            ],
            source: .oauth,
            planType: "plus",
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(
            provider: .codex,
            quota: spikingQuota,
            usage: .empty(.codex)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota.windows, previousQuota.windows)
        XCTAssertEqual(result.quota.source, spikingQuota.source)
        XCTAssertEqual(result.quota.fetchedAt, spikingQuota.fetchedAt)
    }

    func testCodexSameEpochDecreaseReplacesPreviousQuota() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "primary",
                    label: "5-hour",
                    usedPercent: 88,
                    resetsAt: reset
                )
            ],
            source: .oauth,
            planType: "plus",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let lowerQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "primary",
                    label: "5-hour",
                    usedPercent: 94,
                    resetsAt: reset
                )
            ],
            source: .oauth,
            planType: "plus",
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(
            provider: .codex,
            quota: lowerQuota,
            usage: .empty(.codex)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, lowerQuota)
    }

    func testCodexNewResetEpochRecoveryReplacesPreviousQuota() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "primary",
                    label: "5-hour",
                    usedPercent: 97,
                    resetsAt: reset
                )
            ],
            source: .oauth,
            planType: "plus",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let recoveredQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(
                    id: "primary",
                    label: "5-hour",
                    usedPercent: 5,
                    resetsAt: reset.addingTimeInterval(5 * 3600)
                )
            ],
            source: .oauth,
            planType: "plus",
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(
            provider: .codex,
            quota: recoveredQuota,
            usage: .empty(.codex)
        )

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, recoveredQuota)
    }

    func testCodexRecoverySpikePreservesOnlyAffectedWindow() {
        let now = Date()
        let primaryReset = now.addingTimeInterval(3600)
        let weeklyReset = now.addingTimeInterval(5 * 24 * 3600)
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(id: "primary", label: "5-hour", usedPercent: 88, resetsAt: primaryReset),
                QuotaWindow(id: "secondary", label: "Weekly", usedPercent: 30, resetsAt: weeklyReset),
            ],
            source: .oauth,
            planType: "plus",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let freshQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(id: "primary", label: "5-hour", usedPercent: 5, resetsAt: primaryReset),
                QuotaWindow(id: "secondary", label: "Weekly", usedPercent: 40, resetsAt: weeklyReset),
                QuotaWindow(id: "new", label: "New", usedPercent: 10, resetsAt: weeklyReset),
            ],
            source: .oauth,
            planType: "team",
            fetchedAt: now,
            note: "fresh metadata"
        )
        let state = ProviderState(provider: .codex, quota: freshQuota, usage: .empty(.codex))

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota.windows[0], previousQuota.windows[0])
        XCTAssertEqual(result.quota.windows[1], freshQuota.windows[1])
        XCTAssertEqual(result.quota.windows[2], freshQuota.windows[2])
        XCTAssertEqual(result.quota.planType, "team")
        XCTAssertEqual(result.quota.note, "fresh metadata")
        XCTAssertEqual(result.quota.fetchedAt, now)
    }

    func testCodexOAuthQuotaReplacesLowerAuthoritySameEpochQuota() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        for source in [QuotaSnapshot.SourceKind.appServer, .rolloutFile] {
            let previousQuota = QuotaSnapshot(
                provider: .codex,
                windows: [QuotaWindow(id: "primary", label: "5-hour", usedPercent: 88, resetsAt: reset)],
                source: source,
                planType: "plus",
                fetchedAt: now.addingTimeInterval(-30),
                note: nil
            )
            let oauthQuota = QuotaSnapshot(
                provider: .codex,
                windows: [QuotaWindow(id: "primary", label: "5-hour", usedPercent: 5, resetsAt: reset)],
                source: .oauth,
                planType: "plus",
                fetchedAt: now,
                note: nil
            )
            let state = ProviderState(provider: .codex, quota: oauthQuota, usage: .empty(.codex))

            let result = state.preservingLiveQuota(from: previousQuota, at: now)

            XCTAssertEqual(result.quota, oauthQuota, "OAuth must replace lower-authority \(source)")
        }
    }

    func testCodexLowerAuthorityFallbackKeepsPreviousOAuthQuota() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [QuotaWindow(id: "primary", label: "5-hour", usedPercent: 88, resetsAt: reset)],
            source: .oauth,
            planType: "plus",
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let fallbackQuota = QuotaSnapshot(
            provider: .codex,
            windows: [QuotaWindow(id: "primary", label: "5-hour", usedPercent: 90, resetsAt: reset)],
            source: .appServer,
            planType: "plus",
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(provider: .codex, quota: fallbackQuota, usage: .empty(.codex))

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota.windows, previousQuota.windows)
        XCTAssertEqual(result.quota.source, fallbackQuota.source)
        XCTAssertEqual(result.quota.fetchedAt, fallbackQuota.fetchedAt)
    }

    func testCodexLowerAuthorityFallbackPreservesOnlyLiveSameEpochWindows() {
        let now = Date()
        let weeklyReset = now.addingTimeInterval(5 * 24 * 3600)
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(id: "primary", label: "5-hour", usedPercent: 97, resetsAt: now.addingTimeInterval(-30)),
                QuotaWindow(id: "secondary", label: "Weekly", usedPercent: 40, resetsAt: weeklyReset),
            ],
            source: .oauth,
            planType: "plus",
            fetchedAt: now.addingTimeInterval(-60),
            note: nil
        )
        let fallbackQuota = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(id: "primary", label: "5-hour", usedPercent: 5, resetsAt: now.addingTimeInterval(5 * 3600)),
                QuotaWindow(id: "secondary", label: "Weekly", usedPercent: 42, resetsAt: weeklyReset),
            ],
            source: .appServer,
            planType: "plus",
            fetchedAt: now,
            note: "fallback"
        )
        let state = ProviderState(provider: .codex, quota: fallbackQuota, usage: .empty(.codex))

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota.windows[0], fallbackQuota.windows[0])
        XCTAssertEqual(result.quota.windows[1], previousQuota.windows[1])
        XCTAssertEqual(result.quota.source, .appServer)
        XCTAssertEqual(result.quota.fetchedAt, now)
        XCTAssertEqual(result.quota.note, "fallback")
    }

    func testCodexResetCreditRedemptionAllowsSameEpochRecovery() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let previousQuota = QuotaSnapshot(
            provider: .codex,
            windows: [QuotaWindow(id: "primary", label: "5-hour", usedPercent: 97, resetsAt: reset)],
            source: .appServer,
            planType: "plus",
            resetCreditsAvailable: 1,
            fetchedAt: now.addingTimeInterval(-30),
            note: nil
        )
        let redeemedQuota = QuotaSnapshot(
            provider: .codex,
            windows: [QuotaWindow(id: "primary", label: "5-hour", usedPercent: 5, resetsAt: reset)],
            source: .appServer,
            planType: "plus",
            resetCreditsAvailable: 0,
            fetchedAt: now,
            note: nil
        )
        let state = ProviderState(provider: .codex, quota: redeemedQuota, usage: .empty(.codex))

        let result = state.preservingLiveQuota(from: previousQuota, at: now)

        XCTAssertEqual(result.quota, redeemedQuota)
    }
}
