import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeCLIScraperTests: XCTestCase {
    private let windows = [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 40, resetsAt: nil)]
    private let fetchedAt = Date(timeIntervalSince1970: 1_782_000_000)

    /// The scraped panel names no plan, so the snapshot carries what the
    /// login credential said; before, every scrape tick dropped the badge.
    func testSnapshotCarriesTheCredentialPlanAndTier() {
        let snapshot = ClaudeCLIScraper.snapshot(
            windows: windows, planType: "team", rateLimitTier: "default_claude_max_5x", fetchedAt: fetchedAt
        )

        XCTAssertEqual(snapshot.source, .cli)
        XCTAssertEqual(snapshot.planType, "team")
        XCTAssertEqual(snapshot.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(snapshot.planBadge?.text, "TEAM PREMIUM")
    }

    func testSnapshotWithoutACredentialCarriesNoPlan() {
        let snapshot = ClaudeCLIScraper.snapshot(
            windows: windows, planType: nil, rateLimitTier: nil, fetchedAt: fetchedAt
        )

        XCTAssertEqual(snapshot.source, .cli)
        XCTAssertNil(snapshot.planType)
        XCTAssertNil(snapshot.planBadge)
    }
}
