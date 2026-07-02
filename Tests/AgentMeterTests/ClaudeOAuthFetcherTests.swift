import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeOAuthFetcherTests: XCTestCase {
    func testPlanTypeUsesExplicitOAuthField() {
        let plan = ClaudeOAuthFetcher.planType(
            in: ["plan_type": "max"],
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil),
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 0, resetsAt: nil)
            ]
        )

        XCTAssertEqual(plan, "max")
    }

    func testPlanTypeUsesNestedSubscriptionField() {
        let plan = ClaudeOAuthFetcher.planType(
            in: ["subscription": ["tier": "team"]],
            windows: [
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 0, resetsAt: nil)
            ]
        )

        XCTAssertEqual(plan, "team")
    }

    func testPlanTypeDoesNotUseAccountNameAsPlan() {
        let plan = ClaudeOAuthFetcher.planType(
            in: ["account": ["name": "Personal Workspace"]],
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil)
            ]
        )

        XCTAssertNil(plan)
    }

    func testPlanTypeInfersMaxFromModelSpecificWeeklyWindows() {
        let plan = ClaudeOAuthFetcher.planType(
            in: [:],
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil),
                QuotaWindow(id: "seven_day_opus", label: "Weekly (Opus)", usedPercent: 0, resetsAt: nil)
            ]
        )

        XCTAssertEqual(plan, "max")
    }

    func testPlanTypeInfersProFromAggregateWeeklyWindow() {
        let plan = ClaudeOAuthFetcher.planType(
            in: [:],
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil),
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 0, resetsAt: nil)
            ]
        )

        XCTAssertEqual(plan, "pro")
    }

    func testPlanTypeDoesNotInferFromSessionOnlyWindow() {
        let plan = ClaudeOAuthFetcher.planType(
            in: [:],
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil)
            ]
        )

        XCTAssertNil(plan)
    }
}
