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
}
