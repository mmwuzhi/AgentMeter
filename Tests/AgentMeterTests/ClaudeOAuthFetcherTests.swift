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

    func testParseSnapshotWithNoWindowsAndKnownPlanDoesNotThrow() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: ["plan_type": "enterprise"])

        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.source, .oauth)
        XCTAssertEqual(snapshot.planType, "enterprise")
        XCTAssertTrue(snapshot.note?.contains("Enterprise") ?? false)
    }

    func testParseSnapshotWithEmptyObjectThrows() {
        XCTAssertThrowsError(try ClaudeOAuthFetcher.parseSnapshot(from: [:])) { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotParseResponse)
        }
    }

    func testParseSnapshotSurfacesIncludedCreditWindow() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: [
            "cinder_cove": [
                "utilization": 1.5498245000000002,
                "resets_at": "2026-09-30T04:13:36.134431+00:00",
                "limit_dollars": 1000,
                "used_dollars": 15.498245,
                "remaining_dollars": 984.501755
            ]
        ])

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.label, "Included credit")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 1.5498245000000002)
        XCTAssertEqual(snapshot.windows.first?.isOneTimeCredit, true)
        XCTAssertNil(snapshot.note)
    }

    func testParseSnapshotIgnoresInactiveNamedCreditBuckets() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: [
            "plan_type": "enterprise",
            "amber_ladder": ["utilization": 0, "limit_dollars": 25000] as [String: Any],
            "tangelo": NSNull()
        ])

        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNotNil(snapshot.note)
    }

    func testParseSnapshotStillParsesExistingWindows() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: [
            "plan_type": "pro",
            "five_hour": ["utilization": 45.0],
            "seven_day": ["utilization": 87.0]
        ])

        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertNil(snapshot.note)
    }
}
