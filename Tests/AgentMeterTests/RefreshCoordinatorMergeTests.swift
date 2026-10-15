import Foundation
@testable import AgentMeter
import XCTest

final class RefreshCoordinatorMergeTests: XCTestCase {
    func testVisiblePopoverRefreshForcesUsageForScopedProvider() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recentRefreshes: [Provider: Date] = [
            .codex: now,
            .claude: now,
            .copilot: now,
        ]
        let plan = ProviderRefreshPlan.make(
            forceAll: false,
            forceVisibleQuota: true,
            forcedUsageProviders: [.codex],
            forceActiveAgents: true,
            now: now,
            visibleSlots: [.codex, .copilot],
            foregroundKinds: [:],
            lastQuotaRefresh: recentRefreshes,
            lastUsageRefresh: [.codex: now, .claude: now],
            lastActiveAgentsRefresh: now,
            activeAgentsVisible: false,
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 15 * 60,
            backgroundMinimumActiveAgentsRefreshInterval: 5 * 60,
            lastResetCreditsRefresh: now,
            resetCreditsMinimumRefreshInterval: 20 * 60,
            lastProviderStatusRefresh: now,
            providerStatusMinimumRefreshInterval: 30 * 60
        )

        XCTAssertEqual(plan.refreshQuota, [.codex, .copilot])
        XCTAssertEqual(plan.refreshUsage, [.codex])
        XCTAssertTrue(plan.refreshActiveAgents)
        XCTAssertFalse(plan.refreshResetCredits)
        XCTAssertFalse(plan.refreshProviderStatus)
    }

    func testQuotaOnlyForegroundRefreshDoesNotForceUsageScans() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recentRefreshes: [Provider: Date] = [
            .codex: now,
            .claude: now,
            .copilot: now,
        ]
        let plan = ProviderRefreshPlan.make(
            forceAll: false,
            forceVisibleQuota: true,
            forcedUsageProviders: [],
            forceActiveAgents: false,
            now: now,
            visibleSlots: [.codex],
            foregroundKinds: [.codex: [.quota]],
            lastQuotaRefresh: recentRefreshes,
            lastUsageRefresh: [.codex: now, .claude: now],
            lastActiveAgentsRefresh: now,
            activeAgentsVisible: false,
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 15 * 60,
            backgroundMinimumActiveAgentsRefreshInterval: 5 * 60,
            lastResetCreditsRefresh: now,
            resetCreditsMinimumRefreshInterval: 20 * 60,
            lastProviderStatusRefresh: now,
            providerStatusMinimumRefreshInterval: 30 * 60
        )

        XCTAssertEqual(plan.refreshQuota, [.codex])
        XCTAssertTrue(plan.refreshUsage.isEmpty)
    }

    func testScopedPopoverRefreshDoesNotScanOtherVisibleProviders() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recentRefreshes: [Provider: Date] = [
            .codex: now,
            .claude: now,
            .copilot: now,
        ]
        let plan = ProviderRefreshPlan.make(
            forceAll: false,
            forceVisibleQuota: true,
            forcedUsageProviders: [.claude],
            forceActiveAgents: true,
            now: now,
            visibleSlots: [.codex, .claude, .copilot],
            foregroundKinds: [:],
            lastQuotaRefresh: recentRefreshes,
            lastUsageRefresh: [.codex: now, .claude: now],
            lastActiveAgentsRefresh: now,
            activeAgentsVisible: false,
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 15 * 60,
            backgroundMinimumActiveAgentsRefreshInterval: 5 * 60,
            lastResetCreditsRefresh: now,
            resetCreditsMinimumRefreshInterval: 20 * 60,
            lastProviderStatusRefresh: now,
            providerStatusMinimumRefreshInterval: 30 * 60
        )

        XCTAssertEqual(plan.refreshUsage, [.claude])
    }

    func testForcedPopoverRefreshSkipsQuotaReadLiveSecondsAgo() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recentRefreshes: [Provider: Date] = [
            .codex: now,
            .claude: now,
            .copilot: now,
        ]
        let plan = ProviderRefreshPlan.make(
            forceAll: false,
            forceVisibleQuota: true,
            forcedUsageProviders: [.claude],
            forceActiveAgents: true,
            now: now,
            visibleSlots: [.codex, .claude, .copilot],
            foregroundKinds: [.claude: [.quota]],
            lastQuotaRefresh: recentRefreshes,
            lastLiveQuotaFetch: [
                .claude: now.addingTimeInterval(-10),
                .codex: now.addingTimeInterval(-ProviderRefreshPlan.minimumForcedQuotaSpacing),
            ],
            lastUsageRefresh: [.codex: now, .claude: now],
            lastActiveAgentsRefresh: now,
            activeAgentsVisible: false,
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 15 * 60,
            backgroundMinimumActiveAgentsRefreshInterval: 5 * 60,
            lastResetCreditsRefresh: now,
            resetCreditsMinimumRefreshInterval: 20 * 60,
            lastProviderStatusRefresh: now,
            providerStatusMinimumRefreshInterval: 30 * 60
        )

        // Claude was read live 10 s ago: skipped, even though its menu-bar item
        // would otherwise refresh it. Codex sits on the spacing boundary and
        // Copilot has no live reading at all (unavailable): both fetched.
        XCTAssertEqual(plan.refreshQuota, [.codex, .copilot])
        XCTAssertEqual(plan.refreshUsage, [.claude], "usage scans are not held back")
        XCTAssertTrue(plan.refreshActiveAgents, "active-agent polling is not held back")
    }

    func testTimerTickIsNotHeldBackByARecentLiveRead() {
        let now = Date(timeIntervalSince1970: 1_000)
        let plan = ProviderRefreshPlan.make(
            forceAll: false,
            forceVisibleQuota: false,
            forcedUsageProviders: [],
            forceActiveAgents: false,
            now: now,
            visibleSlots: [.claude],
            foregroundKinds: [.claude: [.quota]],
            lastQuotaRefresh: [.codex: now, .claude: now, .copilot: now],
            lastLiveQuotaFetch: [.claude: now.addingTimeInterval(-5)],
            lastUsageRefresh: [.codex: now, .claude: now],
            lastActiveAgentsRefresh: now,
            activeAgentsVisible: false,
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 15 * 60,
            backgroundMinimumActiveAgentsRefreshInterval: 5 * 60,
            lastResetCreditsRefresh: now,
            resetCreditsMinimumRefreshInterval: 20 * 60,
            lastProviderStatusRefresh: now,
            providerStatusMinimumRefreshInterval: 30 * 60
        )

        XCTAssertEqual(plan.refreshQuota, [.claude], "the spacing applies to forced refreshes only")
    }

    func testPendingRefreshRequestMergesForcedWork() {
        var request = ProviderRefreshRequest()

        request.merge(ProviderRefreshRequest(
            forceVisibleQuota: true,
            forcedUsageProviders: [.codex]
        ))
        request.merge(ProviderRefreshRequest(
            forcedUsageProviders: [.claude],
            forceActiveAgents: true
        ))

        XCTAssertTrue(request.requiresRefresh)
        XCTAssertTrue(request.forceVisibleQuota)
        XCTAssertEqual(request.forcedUsageProviders, [.codex, .claude])
        XCTAssertTrue(request.forceActiveAgents)
    }

    func testUpdateOverwritesMatchingProvider() {
        let existing: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .operational, description: "All Systems Operational")
        ]
        let update: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .outage, description: "Major outage")
        ]

        let merged = RefreshCoordinator.mergeProviderStatus(existing, with: update)

        XCTAssertEqual(merged[.codex]?.level, .outage)
    }

    /// The bug this pins: a partial `update` (e.g. one provider's poll timed out this
    /// cycle) must not erase providers that were NOT included in the update — a wholesale
    /// `viewModel.providerStatus = update` would silently regress them to "unknown".
    func testPartialUpdatePreservesProvidersMissingFromTheUpdate() {
        let existing: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .operational, description: nil),
            .claude: ProviderStatusResult(level: .operational, description: nil),
            .copilot: ProviderStatusResult(level: .outage, description: "GitHub Copilot outage")
        ]
        // Simulates this cycle's Copilot poll timing out: only codex/claude came back.
        let update: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .operational, description: nil),
            .claude: ProviderStatusResult(level: .degraded, description: "Partial degradation")
        ]

        let merged = RefreshCoordinator.mergeProviderStatus(existing, with: update)

        XCTAssertEqual(merged[.claude]?.level, .degraded, "claude should reflect this cycle's fresh result")
        XCTAssertEqual(merged[.copilot]?.level, .outage,
                        "copilot's last known outage must survive a cycle where its own poll didn't come back")
    }

    func testEmptyExistingMapAcceptsFirstUpdate() {
        let update: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .operational, description: "All Systems Operational")
        ]

        let merged = RefreshCoordinator.mergeProviderStatus([:], with: update)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[.codex]?.level, .operational)
    }

    func testQuotaStaleWhenFetchFailedButOlderLiveDataIsShown() {
        XCTAssertTrue(RefreshCoordinator.isQuotaStale(rawSource: .unavailable, shownSource: .oauth))
        XCTAssertTrue(RefreshCoordinator.isQuotaStale(rawSource: .unavailable, shownSource: .appServer))
    }

    func testQuotaNotStaleOnSuccessfulFetch() {
        XCTAssertFalse(RefreshCoordinator.isQuotaStale(rawSource: .oauth, shownSource: .oauth))
        XCTAssertFalse(RefreshCoordinator.isQuotaStale(rawSource: .cli, shownSource: .cli))
    }

    func testQuotaNotStaleWhenGenuinelyUnavailable() {
        // Nothing preserved: the UI already shows "unavailable" explicitly.
        XCTAssertFalse(RefreshCoordinator.isQuotaStale(rawSource: .unavailable, shownSource: .unavailable))
    }

    func testFailureStreakCountsConsecutiveStaleCycles() {
        var streak = RefreshCoordinator.nextQuotaFailureStreak(
            previous: 0, rawSource: .unavailable, shownSource: .oauth)
        XCTAssertEqual(streak, 1)
        XCTAssertLessThan(streak, RefreshCoordinator.staleQuotaFailureThreshold,
                          "a single transient failure must not trigger the stale warning")
        streak = RefreshCoordinator.nextQuotaFailureStreak(
            previous: streak, rawSource: .unavailable, shownSource: .oauth)
        XCTAssertGreaterThanOrEqual(streak, RefreshCoordinator.staleQuotaFailureThreshold)
    }

    func testFailureStreakResetsOnAnySuccessfulFetch() {
        XCTAssertEqual(RefreshCoordinator.nextQuotaFailureStreak(
            previous: 5, rawSource: .oauth, shownSource: .oauth), 0)
        XCTAssertEqual(RefreshCoordinator.nextQuotaFailureStreak(
            previous: 5, rawSource: .cli, shownSource: .cli), 0)
    }

    func testFailureStreakDoesNotCountGenuineUnavailability() {
        // No preserved data on screen — the section shows "unavailable" itself.
        XCTAssertEqual(RefreshCoordinator.nextQuotaFailureStreak(
            previous: 1, rawSource: .unavailable, shownSource: .unavailable), 0)
    }

    private func claudeResetsPlan(
        forceAll: Bool = false,
        lastQuotaRefresh: [Provider: Date],
        lastClaudeResetsRefresh: Date?,
        now: Date
    ) -> ProviderRefreshPlan {
        ProviderRefreshPlan.make(
            forceAll: forceAll,
            forceVisibleQuota: false,
            forcedUsageProviders: [],
            forceActiveAgents: false,
            now: now,
            visibleSlots: [],
            foregroundKinds: [:],
            lastQuotaRefresh: lastQuotaRefresh,
            lastUsageRefresh: [.codex: now, .claude: now],
            lastActiveAgentsRefresh: now,
            activeAgentsVisible: false,
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 15 * 60,
            backgroundMinimumActiveAgentsRefreshInterval: 5 * 60,
            lastResetCreditsRefresh: now,
            resetCreditsMinimumRefreshInterval: 20 * 60,
            lastClaudeResetsRefresh: lastClaudeResetsRefresh,
            lastProviderStatusRefresh: now,
            providerStatusMinimumRefreshInterval: 30 * 60
        )
    }

    func testClaudeResetsFollowClaudeQuotaOnTheirOwnTwentyMinuteCadence() {
        let now = Date(timeIntervalSince1970: 100_000)
        let quotaDue: [Provider: Date] = [.codex: now, .claude: now.addingTimeInterval(-16 * 60), .copilot: now]

        let firstEver = claudeResetsPlan(lastQuotaRefresh: quotaDue, lastClaudeResetsRefresh: nil, now: now)
        XCTAssertTrue(firstEver.refreshQuota.contains(.claude))
        XCTAssertTrue(firstEver.refreshClaudeResets)

        let recent = claudeResetsPlan(
            lastQuotaRefresh: quotaDue, lastClaudeResetsRefresh: now.addingTimeInterval(-19 * 60), now: now)
        XCTAssertTrue(recent.refreshQuota.contains(.claude))
        XCTAssertFalse(recent.refreshClaudeResets)

        let due = claudeResetsPlan(
            lastQuotaRefresh: quotaDue, lastClaudeResetsRefresh: now.addingTimeInterval(-20 * 60), now: now)
        XCTAssertTrue(due.refreshClaudeResets)
        XCTAssertFalse(due.refreshResetCredits, "Codex reset credits keep their own clock")
    }

    func testClaudeResetsWaitWhileClaudeQuotaIsNotRead() {
        let now = Date(timeIntervalSince1970: 100_000)
        let allRecent: [Provider: Date] = [.codex: now, .claude: now, .copilot: now]

        let plan = claudeResetsPlan(lastQuotaRefresh: allRecent, lastClaudeResetsRefresh: nil, now: now)

        XCTAssertFalse(plan.refreshQuota.contains(.claude))
        XCTAssertFalse(plan.refreshClaudeResets)
    }

    func testRefreshNowReadsClaudeResetsButNotTwiceWithinAMinute() {
        let now = Date(timeIntervalSince1970: 100_000)
        let allRecent: [Provider: Date] = [.codex: now, .claude: now, .copilot: now]

        func plan(last: Date?) -> ProviderRefreshPlan {
            claudeResetsPlan(forceAll: true, lastQuotaRefresh: allRecent, lastClaudeResetsRefresh: last, now: now)
        }

        XCTAssertTrue(plan(last: nil).refreshClaudeResets)
        XCTAssertFalse(plan(last: now.addingTimeInterval(-2)).refreshClaudeResets)
        XCTAssertFalse(plan(last: now.addingTimeInterval(-59)).refreshClaudeResets)
        XCTAssertTrue(plan(last: now.addingTimeInterval(-60)).refreshClaudeResets)
    }

    func testClaudeResetsAreReadOnlyBehindASuccessfulOAuthQuotaRead() {
        let now = Date(timeIntervalSince1970: 100_000)
        let quotaDue: [Provider: Date] = [.codex: now, .claude: now.addingTimeInterval(-16 * 60), .copilot: now]
        let due = claudeResetsPlan(lastQuotaRefresh: quotaDue, lastClaudeResetsRefresh: nil, now: now)
        let notDue = claudeResetsPlan(lastQuotaRefresh: quotaDue, lastClaudeResetsRefresh: now, now: now)

        XCTAssertTrue(RefreshCoordinator.shouldReadClaudeResets(plan: due, quotaSource: .oauth))
        XCTAssertFalse(RefreshCoordinator.shouldReadClaudeResets(plan: due, quotaSource: .unavailable),
                       "a 429 kept the last live reading: no second call behind it")
        XCTAssertFalse(RefreshCoordinator.shouldReadClaudeResets(plan: due, quotaSource: .cli))
        XCTAssertFalse(RefreshCoordinator.shouldReadClaudeResets(plan: notDue, quotaSource: .oauth))
    }
}
