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
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: ["plan_type": "enterprise"],
            captureDebugResponse: false
        )

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
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "plan_type": "enterprise",
                "amber_ladder": ["utilization": 0, "limit_dollars": 25000] as [String: Any],
                "tangelo": NSNull()
            ],
            captureDebugResponse: false
        )

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

    /// Mirrors a live 2026-07 response: the model-scoped weekly limit (Fable) only
    /// exists in the `limits` array — the named model keys stay null — while the
    /// `session`/`weekly_all` entries duplicate `five_hour`/`seven_day` and must
    /// not produce a second bar.
    func testParseSnapshotSurfacesModelScopedWeeklyLimitFromLimitsArray() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: [
            "five_hour": ["utilization": 72.0, "resets_at": "2026-07-10T20:29:59.570695+00:00"],
            "seven_day": ["utilization": 38.0, "resets_at": "2026-07-14T23:59:59.570720+00:00"],
            "seven_day_opus": NSNull(),
            "limits": [
                ["kind": "session", "group": "session", "percent": 72,
                 "resets_at": "2026-07-10T20:29:59.570695+00:00", "is_active": true],
                ["kind": "weekly_all", "group": "weekly", "percent": 38,
                 "resets_at": "2026-07-14T23:59:59.570720+00:00", "is_active": false],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 62,
                 "resets_at": "2026-07-14T23:59:59.571083+00:00",
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()],
                 "is_active": false] as [String: Any]
            ]
        ])

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        let fable = try XCTUnwrap(snapshot.windows.last)
        XCTAssertEqual(fable.label, "Weekly (Fable)")
        XCTAssertEqual(fable.usedPercent, 62)
        XCTAssertNotNil(fable.resetsAt)
        XCTAssertFalse(fable.isOneTimeCredit ?? false)
    }

    func testParseSnapshotBuildsNamedWindowsFromLimitsWhenNamedKeysAbsent() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "limits": [
                    ["kind": "session", "percent": 41.5,
                     "resets_at": "2026-07-10T20:29:59.570695+00:00"],
                    ["kind": "weekly_all", "percent": 12,
                     "resets_at": "2026-07-14T23:59:59.570720+00:00"]
                ]
            ],
            captureDebugResponse: false
        )

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 41.5)
        XCTAssertEqual(snapshot.windows.first?.label, "5-hour")
    }

    func testParseSnapshotSkipsUnknownOrUnidentifiableLimits() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "plan_type": "pro",
                "limits": [
                    ["kind": "monthly_mystery", "percent": 50],
                    // Scoped but the response carries no model display name:
                    // there is nothing truthful to label the bar with.
                    ["kind": "weekly_scoped", "percent": 62,
                     "scope": ["model": ["id": NSNull(), "display_name": NSNull()]]] as [String: Any],
                    ["kind": "weekly_scoped", "percent": 62] as [String: Any]
                ]
            ],
            captureDebugResponse: false
        )

        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testSessionUtilizationIsUsedPercentNotRemainingPercent() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: [
            "plan_type": "pro",
            "five_hour": ["utilization": 94.0]
        ])

        let window = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(window.usedPercent, 94)
        XCTAssertEqual(window.remainingPercent, 6)
    }
}
