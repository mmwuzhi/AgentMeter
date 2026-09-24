import Foundation
@testable import AgentMeter
import XCTest

/// `QuotaSnapshot.planBadge` is the one place the header badge is decided.
/// These pin the rule Claude Code itself uses for a Team premium seat:
/// `subscriptionType == "team"` and `rateLimitTier == "default_claude_max_5x"`,
/// since no field anywhere spells "premium".
final class PlanBadgeTests: XCTestCase {
    private func snapshot(plan: String?, tier: String?) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 12, resetsAt: nil),
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 40, resetsAt: nil)
            ],
            source: .oauth,
            planType: plan,
            rateLimitTier: tier,
            fetchedAt: Date(timeIntervalSince1970: 1_782_000_000),
            note: nil
        )
    }

    private let premiumHelp = "Team premium seat · rate limit tier default_claude_max_5x"

    func testTeamWithMax5xTierIsTeamPremium() {
        XCTAssertEqual(
            snapshot(plan: "team", tier: "default_claude_max_5x").planBadge,
            PlanBadge(text: "TEAM PREMIUM", help: premiumHelp)
        )
    }

    func testTeamWithAnotherTierStaysTeamAndNamesTheTier() {
        XCTAssertEqual(
            snapshot(plan: "team", tier: "default_claude_max_20x").planBadge,
            PlanBadge(text: "TEAM", help: "Rate limit tier default_claude_max_20x")
        )
    }

    func testTeamWithoutTierStaysTeamWithNoTooltip() {
        XCTAssertEqual(
            snapshot(plan: "team", tier: nil).planBadge,
            PlanBadge(text: "TEAM", help: nil)
        )
    }

    /// The fetcher lowercases credential plans, but a response-body
    /// `plan_type` need not be; the premium check must not depend on case.
    func testMixedCaseTeamStillMatchesPremium() {
        XCTAssertEqual(
            snapshot(plan: "Team", tier: "default_claude_max_5x").planBadge,
            PlanBadge(text: "TEAM PREMIUM", help: premiumHelp)
        )
    }

    /// The premium rule is team-only: the same tier on another plan is just
    /// that plan, with the tier in the tooltip.
    func testProWithMax5xTierIsNotPremium() {
        XCTAssertEqual(
            snapshot(plan: "pro", tier: "default_claude_max_5x").planBadge,
            PlanBadge(text: "PRO", help: "Rate limit tier default_claude_max_5x")
        )
    }

    func testMaxShowsItsTierInTheTooltip() {
        XCTAssertEqual(
            snapshot(plan: "max", tier: "default_claude_max_20x").planBadge,
            PlanBadge(text: "MAX", help: "Rate limit tier default_claude_max_20x")
        )
    }

    func testUnknownPlanHasNoBadgeEvenWithATier() {
        XCTAssertNil(snapshot(plan: nil, tier: "default_claude_max_5x").planBadge)
    }

    /// A blank plan is as unknown as a missing one; an empty capsule would be
    /// worse than none.
    func testBlankPlanHasNoBadge() {
        XCTAssertNil(snapshot(plan: "  ", tier: "default_claude_max_5x").planBadge)
    }

    func testUnavailableSnapshotHasNoBadge() {
        XCTAssertNil(QuotaSnapshot.unavailable(.claude, note: "x").planBadge)
    }

    /// The premium rule is Claude's, so it is guarded on the provider: Codex's
    /// raw `plan_type` could read "team", and a tier Codex never reports must
    /// not promote it.
    func testTeamPremiumIsClaudeOnly() {
        let codex = QuotaSnapshot(
            provider: .codex,
            windows: [QuotaWindow(id: "primary", label: "5-hour", usedPercent: 12, resetsAt: nil)],
            source: .oauth,
            planType: "team",
            rateLimitTier: "default_claude_max_5x",
            fetchedAt: Date(timeIntervalSince1970: 1_782_000_000),
            note: nil
        )

        XCTAssertEqual(
            codex.planBadge,
            PlanBadge(text: "TEAM", help: "Rate limit tier default_claude_max_5x")
        )
    }
}
