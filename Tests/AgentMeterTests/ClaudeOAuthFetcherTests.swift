import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeOAuthFetcherTests: XCTestCase {
    func testOnlyUnauthorizedStatusIsClassifiedAsAuthenticationFailure() {
        XCTAssertNil(ClaudeOAuthFetcher.responseError(forStatusCode: 200))
        XCTAssertEqual(
            ClaudeOAuthFetcher.responseError(forStatusCode: 401),
            .userAuthenticationRequired
        )
        XCTAssertEqual(ClaudeOAuthFetcher.responseError(forStatusCode: 429), .badServerResponse)
        XCTAssertEqual(ClaudeOAuthFetcher.responseError(forStatusCode: 500), .badServerResponse)
    }

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

    /// A response field is bounded like the credential: a value unfit to
    /// display is treated as unstated rather than shown.
    func testPlanTypeTreatsAnUndisplayableResponseFieldAsUnstated() {
        let plan = ClaudeOAuthFetcher.planType(
            in: ["plan_type": "Pro\nMax"],
            windows: [QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 0, resetsAt: nil)],
            credentialPlan: "team"
        )

        XCTAssertEqual(plan, "team")
    }

    func testPlanTypeNormalizesAnExplicitResponseField() {
        let plan = ClaudeOAuthFetcher.planType(in: ["plan_type": " Max "], windows: [])

        XCTAssertEqual(plan, "max")
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

    /// A Team premium seat: `five_hour`, `seven_day`, and the model-scoped
    /// `seven_day_fable` from the `limits` array, with no opus/sonnet key. The
    /// window-shape guess reads that as pro; the credential must win.
    func testPlanTypePrefersCredentialOverWindowShapeGuess() {
        let plan = ClaudeOAuthFetcher.planType(
            in: [:],
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil),
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 0, resetsAt: nil),
                QuotaWindow(id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 0, resetsAt: nil)
            ],
            credentialPlan: "team"
        )

        XCTAssertEqual(plan, "team")
    }

    func testPlanTypeExplicitResponseFieldBeatsCredential() {
        let plan = ClaudeOAuthFetcher.planType(
            in: ["plan_type": "max"],
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil),
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 0, resetsAt: nil)
            ],
            credentialPlan: "team"
        )

        XCTAssertEqual(plan, "max")
    }

    func testPlanTypeIgnoresBlankCredentialPlan() {
        let plan = ClaudeOAuthFetcher.planType(
            in: [:],
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil),
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 0, resetsAt: nil)
            ],
            credentialPlan: "  "
        )

        XCTAssertEqual(plan, "pro")
    }

    func testParseSnapshotWithNoWindowsAndKnownPlanDoesNotThrow() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: ["plan_type": "enterprise"]
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
                "resets_at": "2025-01-15T12:00:00.123456+00:00",
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

    func testParseSnapshotHidesFullyUsedIncludedCredit() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "plan_type": "enterprise",
                "cinder_cove": ["utilization": 100, "resets_at": "2025-01-15T12:00:00Z"],
            ]
        )

        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testParseSnapshotKeepsFullyUsedRecurringWindow() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: [
            "plan_type": "pro",
            "five_hour": ["utilization": 100],
        ])

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour"])
    }

    func testParseSnapshotSurfacesUSDExtraUsageSpend() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "plan_type": "enterprise",
                "extra_usage": [
                    "is_enabled": true,
                    "used_credits": 35_736,
                    "currency": "USD",
                    "decimal_places": 2,
                ],
            ]
        )

        XCTAssertEqual(snapshot.extraUsageSpentUSD ?? 0, 357.36, accuracy: 0.001)
    }

    func testExtraUsageRejectsDisabledUnknownCurrencyAndInvalidScale() {
        XCTAssertNil(ClaudeOAuthFetcher.extraUsageSpentUSD(in: [
            "extra_usage": ["is_enabled": false, "used_credits": 100],
        ]))
        XCTAssertNil(ClaudeOAuthFetcher.extraUsageSpentUSD(in: [
            "extra_usage": ["used_credits": 100, "currency": "EUR", "decimal_places": 2],
        ]))
        XCTAssertNil(ClaudeOAuthFetcher.extraUsageSpentUSD(in: [
            "extra_usage": ["used_credits": 100, "currency": "USD", "decimal_places": 2.5],
        ]))
        XCTAssertNil(ClaudeOAuthFetcher.extraUsageSpentUSD(in: [
            "extra_usage": ["used_credits": 0, "currency": "USD"],
        ]))
    }

    func testParseSnapshotIgnoresInactiveNamedCreditBuckets() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "plan_type": "enterprise",
                "amber_ladder": ["utilization": 0, "limit_dollars": 25000] as [String: Any],
                "tangelo": NSNull()
            ]
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

    func testParseSnapshotCarriesCredentialPlan() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "five_hour": ["utilization": 45.0, "resets_at": "2025-01-03T10:00:00.123456+00:00"],
                "seven_day": ["utilization": 87.0, "resets_at": "2025-01-07T12:00:00.123457+00:00"]
            ],
            credentialPlan: "team"
        )

        XCTAssertEqual(snapshot.planType, "team")
        XCTAssertEqual(snapshot.source, .oauth)
        XCTAssertEqual(snapshot.windows.count, 2)
    }

    /// Pins the fallback: with no plan in the response and none from the
    /// credential, the window-shape guess still decides.
    func testParseSnapshotWithoutCredentialPlanStillGuesses() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "five_hour": ["utilization": 45.0, "resets_at": "2025-01-03T10:00:00.123456+00:00"],
                "seven_day": ["utilization": 87.0, "resets_at": "2025-01-07T12:00:00.123457+00:00"]
            ]
        )

        XCTAssertEqual(snapshot.planType, "pro")
    }

    /// The credential's tier rides through untouched; what the badge makes of
    /// it is `PlanBadgeTests`' business.
    func testParseSnapshotCarriesCredentialRateLimitTier() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "five_hour": ["utilization": 45.0, "resets_at": "2025-01-03T10:00:00.123456+00:00"],
                "seven_day": ["utilization": 87.0, "resets_at": "2025-01-07T12:00:00.123457+00:00"]
            ],
            credentialPlan: "team",
            credentialRateLimitTier: "default_claude_max_5x"
        )

        XCTAssertEqual(snapshot.rateLimitTier, "default_claude_max_5x")
    }

    func testParseSnapshotWithoutCredentialRateLimitTierLeavesItNil() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "five_hour": ["utilization": 45.0, "resets_at": "2025-01-03T10:00:00.123456+00:00"],
                "seven_day": ["utilization": 87.0, "resets_at": "2025-01-07T12:00:00.123457+00:00"]
            ],
            credentialPlan: "team"
        )

        XCTAssertNil(snapshot.rateLimitTier)
    }

    /// Exercises a synthetic response: the model-scoped weekly limit (Fable) only
    /// exists in the `limits` array — the named model keys stay null — while the
    /// `session`/`weekly_all` entries duplicate `five_hour`/`seven_day` and must
    /// not produce a second bar.
    func testParseSnapshotSurfacesModelScopedWeeklyLimitFromLimitsArray() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: [
            "five_hour": ["utilization": 74.0, "resets_at": "2025-01-03T10:00:00.123456+00:00"],
            "seven_day": ["utilization": 42.0, "resets_at": "2025-01-07T12:00:00.123457+00:00"],
            "seven_day_opus": NSNull(),
            "limits": [
                ["kind": "session", "group": "session", "percent": 74,
                 "resets_at": "2025-01-03T10:00:00.123456+00:00", "is_active": true],
                ["kind": "weekly_all", "group": "weekly", "percent": 42,
                 "resets_at": "2025-01-07T12:00:00.123457+00:00", "is_active": false],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 64,
                 "resets_at": "2025-01-07T12:00:00.123458+00:00",
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()],
                 "is_active": false] as [String: Any]
            ]
        ])

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        let fable = try XCTUnwrap(snapshot.windows.last)
        XCTAssertEqual(fable.label, "Weekly (Fable)")
        XCTAssertEqual(fable.usedPercent, 64)
        XCTAssertNotNil(fable.resetsAt)
        XCTAssertFalse(fable.isOneTimeCredit ?? false)
        // Taken from `kind == "weekly_scoped"`, a documented field, not from
        // the model name — `scope.model.id` is null in live responses, so a
        // name match would be a guess. The trend tracker reads this to decide
        // how long a silence has to run before it stops reporting a rate.
        XCTAssertTrue(fable.isModelScoped ?? false)
        for shared in snapshot.windows where shared.id != "seven_day_fable" {
            XCTAssertFalse(shared.isModelScoped ?? false, shared.id)
        }
    }

    /// The usage API states no window duration, so the cycle the trend tracker
    /// paces against comes from the key — for the model-scoped weeklies too,
    /// which only exist in `limits`. The one-time credit has none.
    func testParseSnapshotStatesTheRefillCycleFromTheWindowKey() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(from: [
            "five_hour": ["utilization": 74.0],
            "seven_day": ["utilization": 42.0],
            "cinder_cove": ["utilization": 1.5],
            "limits": [
                ["kind": "weekly_scoped", "group": "weekly", "percent": 64,
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()],
                 "is_active": false] as [String: Any]
            ]
        ])
        func cycle(_ id: String) -> TimeInterval? {
            snapshot.windows.first(where: { $0.id == id })?.cycle
        }

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "cinder_cove", "seven_day_fable"])
        XCTAssertEqual(cycle("five_hour"), 5 * 3600)
        XCTAssertEqual(cycle("seven_day"), 7 * 24 * 3600)
        XCTAssertEqual(cycle("seven_day_fable"), 7 * 24 * 3600)
        XCTAssertNil(cycle("cinder_cove"))
    }

    func testParseSnapshotBuildsNamedWindowsFromLimitsWhenNamedKeysAbsent() throws {
        let snapshot = try ClaudeOAuthFetcher.parseSnapshot(
            from: [
                "limits": [
                    ["kind": "session", "percent": 41.5,
                     "resets_at": "2025-01-03T10:00:00.123456+00:00"],
                    ["kind": "weekly_all", "percent": 12,
                     "resets_at": "2025-01-07T12:00:00.123457+00:00"]
                ]
            ]
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
                    ["kind": "weekly_scoped", "percent": 64,
                     "scope": ["model": ["id": NSNull(), "display_name": NSNull()]]] as [String: Any],
                    ["kind": "weekly_scoped", "percent": 64] as [String: Any]
                ]
            ]
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
