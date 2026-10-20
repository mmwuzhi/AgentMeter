import Foundation
@testable import AgentMeter
import XCTest

/// Which snapshots become `quota_sample` rows and how, with no database: the
/// gating (provider allowlist, source, stale echo), the key time, the clamp,
/// the flags, the legacy mapping and the thinning fingerprint.
final class QuotaSampleMappingTests: XCTestCase {
    /// 2027-01-15 08:00:00 UTC, with a fraction so millisecond rounding shows.
    private static let fetched = Date(timeIntervalSince1970: 1_800_000_000.7)
    private static let landed = fetched.addingTimeInterval(1.3)
    private static let fetchedMs: Int64 = 1_800_000_000_700
    private static let landedMs: Int64 = 1_800_000_002_000

    private func claude(
        source: QuotaSnapshot.SourceKind = .oauth,
        windows: [QuotaWindow]? = nil,
        fetchedAt: Date = QuotaSampleMappingTests.fetched,
        cachedAt: Date? = nil,
        plan: String? = "max",
        tier: String? = "default_claude_max_5x"
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .claude,
            windows: windows ?? [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 41.5,
                            resetsAt: Date(timeIntervalSince1970: 1_800_003_599.7), cycle: 18_000),
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 12,
                            resetsAt: Date(timeIntervalSince1970: 1_800_400_000), cycle: 604_800),
            ],
            source: source, planType: plan, rateLimitTier: tier, fetchedAt: fetchedAt,
            note: nil, cachedAt: cachedAt)
    }

    private func rows(_ snapshot: QuotaSnapshot, at landed: Date = QuotaSampleMappingTests.landed) -> [QuotaSampleRow] {
        QuotaSampleRow.rows(from: snapshot, recordedAt: landed)
    }

    // MARK: - One fetch, many windows

    func testTwoWindowsOfOneFetchShareTheReadingTimeAndDifferInTheRest() throws {
        let result = rows(claude())

        XCTAssertEqual(result.map(\.windowID), ["five_hour", "seven_day"])
        XCTAssertEqual(Set(result.map(\.readingMs)), [Self.fetchedMs], "one reading time for the whole fetch")
        XCTAssertEqual(result.map(\.usedPercent), [41.5, 12], "used, not remaining, fractions kept")
        XCTAssertEqual(result.map(\.source), [.oauth, .oauth])
        XCTAssertEqual(Set(result.map(\.recordedMs)), [Self.landedMs])
        XCTAssertEqual(Set(result.compactMap(\.fetchedMs)), [Self.fetchedMs])
        XCTAssertEqual(result.map(\.cycleSeconds), [18_000, 604_800])
        XCTAssertEqual(result.map(\.plan), ["max", "max"])
        XCTAssertEqual(result.map(\.tier), ["default_claude_max_5x", "default_claude_max_5x"])
        XCTAssertNil(result[0].cachedMs)
        XCTAssertEqual(result.map(\.flags), [[], []])
        XCTAssertEqual(Set(result.map { "\($0.provider)|\($0.windowID)|\($0.source)|\($0.readingMs)" }).count, 2, "natural keys are distinct")
    }

    func testOAuthAndCLIReadingsOfTheSameInstantBothMapWithDifferentSources() throws {
        let oauth = rows(claude(source: .oauth))
        let cli = rows(claude(source: .cli, windows: [
            QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 41, resetsAt: nil, cycle: 18_000),
            QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 12, resetsAt: nil, cycle: 604_800),
        ]))

        XCTAssertEqual(oauth.count, 2)
        XCTAssertEqual(cli.count, 2)
        XCTAssertEqual(Set(oauth.map(\.readingMs) + cli.map(\.readingMs)), [Self.fetchedMs])
        XCTAssertEqual(Set(cli.map(\.source)), [.cli])
        XCTAssertEqual(Set(oauth.map(\.source)), [.oauth])
        XCTAssertNil(cli[0].resetsAtMs)
        XCTAssertNil(cli[0].resetEpochSeconds)
        let keys = (oauth + cli).map { "\($0.provider)|\($0.windowID)|\($0.source)|\($0.readingMs)" }
        XCTAssertEqual(Set(keys).count, 4, "source is part of the key, so no row collides")
    }

    // MARK: - Reading time, clamp

    func testAFreshCLIEchoIsKeyedByItsCacheTimeNotItsFetchTime() throws {
        let cachedAt = Self.fetched.addingTimeInterval(-120)

        let result = rows(claude(source: .cli, cachedAt: cachedAt))

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.readingMs)), [HistoryTime.ms(cachedAt)])
        XCTAssertEqual(Set(result.compactMap(\.cachedMs)), [HistoryTime.ms(cachedAt)])
        XCTAssertEqual(Set(result.compactMap(\.fetchedMs)), [Self.fetchedMs])
    }

    func testAStaleCLIEchoMapsToNoRows() {
        let echo = claude(source: .cli, cachedAt: Self.fetched.addingTimeInterval(-2 * 86_400))

        XCTAssertTrue(echo.echoesStaleCache)
        XCTAssertEqual(rows(echo), [])
        // Just past the tolerance is stale, at the tolerance it is not.
        XCTAssertEqual(rows(claude(source: .cli, cachedAt: Self.fetched.addingTimeInterval(-300 - 1))), [])
        XCTAssertEqual(rows(claude(source: .cli, cachedAt: Self.fetched.addingTimeInterval(-300))).count, 2)
    }

    func testUnavailableAndRolloutFileMapToNoRows() {
        XCTAssertEqual(rows(.unavailable(.claude, note: "offline")), [])
        XCTAssertEqual(rows(claude(source: .unavailable)), [])
        XCTAssertEqual(rows(claude(source: .rolloutFile)), [], "a rollout reading is stamped with Date() on old data")
        XCTAssertEqual(rows(claude(source: .appServer)).map(\.source), [.appServer, .appServer],
                       "mapped for any allowlisted provider, though Claude has none")
    }

    func testCodexAndCopilotSnapshotsMapToNoRowsByDefault() {
        let codex = [QuotaSnapshot.SourceKind.oauth, .appServer, .rolloutFile].map {
            QuotaSnapshot(provider: .codex,
                          windows: [QuotaWindow(id: "primary", label: "5-hour", usedPercent: 3, resetsAt: Self.fetched)],
                          source: $0, planType: "plus", fetchedAt: Self.fetched, note: nil)
        }
        let copilot = QuotaSnapshot(
            provider: .copilot,
            windows: [QuotaWindow(id: "premium_interactions", label: "Premium", usedPercent: 12.5, resetsAt: Self.fetched)],
            source: .cli, planType: "pro", fetchedAt: Self.fetched, note: nil)

        for snapshot in codex + [copilot] {
            XCTAssertEqual(rows(snapshot), [], "\(snapshot.provider) \(snapshot.source)")
        }
        XCTAssertEqual(QuotaHistoryPolicy.ingestedProviders, [.claude])
    }

    /// The row type itself holds any provider, so enabling one later is the
    /// allowlist and nothing else.
    func testAQuotaSampleRowCanHoldACodexRow() {
        let row = QuotaSampleRow(
            provider: .codex, windowID: "primary", source: .oauth, readingMs: 1_800_000_000_000,
            fetchedMs: 1_800_000_000_100, cachedMs: nil, recordedMs: 1_800_000_000_200, usedPercent: 7,
            resetsAtMs: 1_800_018_000_000, cycleSeconds: 18_000, isModelScoped: nil, isOneTimeCredit: nil,
            isActive: nil, severity: nil, lockedReason: nil, scopeName: nil, shareUsedOfWeekly: nil,
            shareAllowanceOfWeekly: nil, plan: "plus", tier: nil, flags: [])

        XCTAssertEqual(row.provider, .codex)
        XCTAssertEqual(row.resetEpochSeconds, 1_800_018_000)
        XCTAssertEqual(QuotaSampleFingerprint(row), QuotaSampleFingerprint(row))
    }

    /// The raw reading time is the natural key: rewriting it to the landing
    /// time would store one joined flight twice, so it is only flagged.
    func testAReadingLaterThanTheLandingKeepsItsTimeAndIsFlaggedFutureReading() {
        // The clock was set back after the fetch: landing is 10 minutes "before" it.
        let landing = Self.fetched.addingTimeInterval(-600)

        let result = rows(claude(), at: landing)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.readingMs)), [Self.fetchedMs], "never rewritten")
        XCTAssertEqual(Set(result.map(\.recordedMs)), [HistoryTime.ms(landing)])
        XCTAssertEqual(Set(result.compactMap(\.fetchedMs)), [Self.fetchedMs], "the fetch time is kept as it was")
        for row in result {
            XCTAssertTrue(row.flags.contains(.futureReading))
            XCTAssertGreaterThan(row.readingMs, row.recordedMs)
        }
        // Two landings of the same flight under different clocks key the same.
        let other = rows(claude(), at: Self.fetched.addingTimeInterval(-900))
        XCTAssertEqual(result.map(\.readingMs), other.map(\.readingMs))
    }

    func testAReadingAtOrBeforeTheLandingIsNotFlagged() {
        let exactly = rows(claude(), at: Self.fetched)
        XCTAssertEqual(Set(exactly.map(\.readingMs)), [Self.fetchedMs])
        XCTAssertFalse(exactly[0].flags.contains(.futureReading))
        // Sub-millisecond lateness rounds to the same millisecond.
        let sub = rows(claude(), at: Self.fetched.addingTimeInterval(-0.0002))
        XCTAssertFalse(sub[0].flags.contains(.futureReading))
        XCTAssertFalse(rows(claude())[0].flags.contains(.futureReading))
    }

    // MARK: - Flags and detail

    func testAWindowWhoseUtilizationWasNotStatedIsFlagged() {
        let windows = [
            QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil,
                        detail: QuotaWindowDetail(lockedReason: "plan_limit", utilizationStated: false)),
            QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 0, resetsAt: nil,
                        detail: QuotaWindowDetail(utilizationStated: true)),
            QuotaWindow(id: "seven_day_opus", label: "Opus", usedPercent: 0, resetsAt: nil),
        ]

        let result = rows(claude(windows: windows))

        XCTAssertEqual(result.map { $0.flags.contains(.valueNotStated) }, [true, false, false])
        XCTAssertEqual(result[0].lockedReason, "plan_limit")
        XCTAssertEqual(result.map(\.usedPercent), [nil, 0, 0],
                       "a window that stated nothing stores no value, never the placeholder 0; a stated 0 is a reading")
    }

    /// The placeholder is whatever the window holds (0 today); it never reaches the row.
    func testANotStatedWindowStoresNoValueWhateverThePlaceholderIs() {
        let windows = [
            QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil,
                        detail: QuotaWindowDetail(utilizationStated: false)),
            QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: .nan, resetsAt: nil,
                        detail: QuotaWindowDetail(utilizationStated: false)),
            QuotaWindow(id: "seven_day_opus", label: "Opus", usedPercent: 37, resetsAt: nil,
                        detail: QuotaWindowDetail(utilizationStated: false)),
        ]

        let result = rows(claude(windows: windows))

        XCTAssertEqual(result.map(\.windowID), ["five_hour", "seven_day", "seven_day_opus"])
        XCTAssertEqual(result.map(\.usedPercent), [nil, nil, nil])
        XCTAssertTrue(result.allSatisfy { $0.flags.contains(.valueNotStated) })
    }

    func testDetailAndWindowFlagsAreCarriedIntoTheRow() throws {
        let windows = [QuotaWindow(
            id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 46,
            resetsAt: Date(timeIntervalSince1970: 1_800_400_000), isOneTimeCredit: false, isModelScoped: true,
            cycle: 604_800,
            detail: QuotaWindowDetail(isActive: false, severity: "normal", scopeName: "Fable",
                                      shareUsedOfWeekly: 23, shareAllowanceOfWeekly: 50, utilizationStated: true))]

        let row = try XCTUnwrap(rows(claude(windows: windows)).first)

        XCTAssertEqual(row.isModelScoped, true)
        XCTAssertEqual(row.isOneTimeCredit, false)
        XCTAssertEqual(row.isActive, false)
        XCTAssertEqual(row.severity, "normal")
        XCTAssertEqual(row.scopeName, "Fable")
        XCTAssertEqual(row.shareUsedOfWeekly, 23)
        XCTAssertEqual(row.shareAllowanceOfWeekly, 50)
        XCTAssertEqual(row.resetsAtMs, 1_800_400_000_000)
        XCTAssertEqual(row.cycleSeconds, 604_800)
        XCTAssertNil(row.lockedReason)
    }

    func testAWindowWithNoDetailMapsWithNilDetailFields() throws {
        let row = try XCTUnwrap(rows(claude(windows: [
            QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 5, resetsAt: nil)])).first)

        XCTAssertNil(row.isActive)
        XCTAssertNil(row.severity)
        XCTAssertNil(row.lockedReason)
        XCTAssertNil(row.scopeName)
        XCTAssertNil(row.shareUsedOfWeekly)
        XCTAssertNil(row.cycleSeconds)
        XCTAssertNil(row.resetsAtMs)
        XCTAssertTrue(row.flags.isEmpty)
    }

    func testUnstorableWindowsAreSkippedAndRepeatedIdsKeepTheFirst() {
        let long = "seven_day_" + String(repeating: "x", count: QuotaHistoryPolicy.maxWindowIDLength)
        let windows = [
            QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 10, resetsAt: nil),
            QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 99, resetsAt: nil),
            QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: .nan, resetsAt: nil),
            QuotaWindow(id: long, label: "Long", usedPercent: 1, resetsAt: nil),
            QuotaWindow(id: "seven_day_a\u{0}b", label: "Control", usedPercent: 1, resetsAt: nil),
            QuotaWindow(id: "", label: "Empty", usedPercent: 1, resetsAt: nil),
            QuotaWindow(id: "seven_day_opus_4.8", label: "Opus 4.8", usedPercent: 2, resetsAt: nil),
        ]

        let result = rows(claude(windows: windows))

        XCTAssertEqual(result.map(\.windowID), ["five_hour", "seven_day_opus_4.8"])
        XCTAssertEqual(result.first?.usedPercent, 10)
    }

    func testAnOutOfRangeCycleIsNotStored() {
        let windows = [
            QuotaWindow(id: "a", label: "a", usedPercent: 1, resetsAt: nil, cycle: -5),
            QuotaWindow(id: "b", label: "b", usedPercent: 1, resetsAt: nil, cycle: .infinity),
            QuotaWindow(id: "c", label: "c", usedPercent: 1, resetsAt: nil, cycle: 18_000.4),
        ]

        XCTAssertEqual(rows(claude(windows: windows)).map(\.cycleSeconds), [nil, nil, 18_000])
    }

    // MARK: - Reset epoch

    func testResetEpochIsTheNearestMinuteSoTheJitterAroundTheMinuteIsOneEpoch() throws {
        // One five-hour epoch, ending 12:00:00 UTC on 2027-01-15 = 1_800_007_200.
        // The server's instant has been seen at 59.979 s and at 0.005 s.
        let epoch: Int64 = 1_800_007_200
        let instants: [Double] = [1_800_007_199.7, 1_800_007_199.979, 1_800_007_200.0, 1_800_007_200.005, 1_800_007_200.4]
        let epochs = try instants.map { instant -> Int64 in
            let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 1,
                                     resetsAt: Date(timeIntervalSince1970: instant))
            return try XCTUnwrap(rows(claude(windows: [window])).first?.resetEpochSeconds)
        }

        XCTAssertEqual(Set(epochs), [epoch], "hh:59:59.7 and hh:00:00.0 are one epoch")
        // And the next epoch is a different one.
        let next = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 1,
                               resetsAt: Date(timeIntervalSince1970: 1_800_025_199.9))
        XCTAssertEqual(rows(claude(windows: [next])).first?.resetEpochSeconds, epoch + 18_000)
    }

    // MARK: - Fingerprint

    func testFingerprintCoversWhatThinningMustNotMerge() throws {
        func row(used: Double = 46, isActive: Bool? = false, severity: String? = "normal", locked: String? = nil,
                 share: Double? = 23, allowance: Double? = 50, resets: Double = 1_800_400_000,
                 stated: Bool = true, landed: Date = QuotaSampleMappingTests.landed) throws -> QuotaSampleRow {
            try XCTUnwrap(rows(claude(windows: [QuotaWindow(
                id: "seven_day_fable", label: "x", usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets),
                detail: QuotaWindowDetail(isActive: isActive, severity: severity, lockedReason: locked,
                                          shareUsedOfWeekly: share, shareAllowanceOfWeekly: allowance,
                                          utilizationStated: stated))]), at: landed).first)
        }
        let base = try row()
        let original = QuotaSampleFingerprint(base)

        // The same facts: the same fingerprint, whatever the time or the clamp flag.
        var later = base
        later.readingMs += 600_000
        later.flags.insert(.futureReading)
        XCTAssertEqual(QuotaSampleFingerprint(later), original)
        XCTAssertEqual(QuotaSampleFingerprint(try row(resets: 1_800_400_000.3)), original, "jitter inside the minute is one epoch")
        XCTAssertEqual(Set([original, QuotaSampleFingerprint(try row())]).count, 1, "Hashable agrees with ==")

        let changes: [(String, QuotaSampleRow)] = [
            ("used", try row(used: 47)),
            ("isActive", try row(isActive: true)),
            ("isActive nil", try row(isActive: nil)),
            ("severity", try row(severity: "warning")),
            ("lockedReason", try row(locked: "plan_limit")),
            ("share used", try row(share: 24)),
            ("share allowance", try row(allowance: 51)),
            ("new epoch", try row(resets: 1_800_400_000 + 7 * 86_400)),
            ("value not stated", try row(stated: false)),
        ]
        for (what, changed) in changes {
            XCTAssertNotEqual(QuotaSampleFingerprint(changed), original, what)
        }
    }

    // MARK: - Reset grants

    func testResetGrantsMapToObservationsSortedByIdWithSortedJoinedClears() {
        let ends = Date(timeIntervalSince1970: 1_800_086_400.4)
        let state = ClaudeResetState(eligible: true, grants: [
            ClaudeResetGrant(id: "g-b", resetsLeft: 2, endsAt: ends,
                             clears: ["seven_day", "five_hour", "seven_day_opus"]),
            ClaudeResetGrant(id: "g-a", resetsLeft: 1, endsAt: nil, clears: []),
            ClaudeResetGrant(id: "g-c", resetsLeft: 0, endsAt: Date(timeIntervalSince1970: 1_800_000_000), clears: ["five_hour"]),
        ])

        let result = ResetGrantObservation.observations(from: state)

        XCTAssertEqual(result, [
            ResetGrantObservation(id: "g-a", resetsLeft: 1, endsAtMs: nil, clears: ""),
            ResetGrantObservation(id: "g-b", resetsLeft: 2, endsAtMs: 1_800_086_400_400,
                                  clears: "five_hour,seven_day,seven_day_opus"),
            ResetGrantObservation(id: "g-c", resetsLeft: 0, endsAtMs: 1_800_000_000_000, clears: "five_hour"),
        ])
    }

    func testEqualGrantSetsMapToEqualArraysWhateverTheResponseOrder() {
        let a = ClaudeResetGrant(id: "g1", resetsLeft: 1, endsAt: Date(timeIntervalSince1970: 1_800_100_000), clears: ["five_hour", "seven_day"])
        let b = ClaudeResetGrant(id: "g2", resetsLeft: 1, endsAt: Date(timeIntervalSince1970: 1_800_000_000), clears: ["five_hour"])
        let c = ClaudeResetGrant(id: "g1", resetsLeft: 1, endsAt: Date(timeIntervalSince1970: 1_800_200_000), clears: ["seven_day", "five_hour"])

        XCTAssertEqual(
            ResetGrantObservation.observations(from: ClaudeResetState(eligible: true, grants: [a, b, c])),
            ResetGrantObservation.observations(from: ClaudeResetState(eligible: true, grants: [c, b, a])))
        XCTAssertEqual(
            ResetGrantObservation.observations(from: ClaudeResetState(eligible: true, grants: [a])).first?.clears,
            ResetGrantObservation.observations(from: ClaudeResetState(eligible: true, grants: [c])).first?.clears,
            "clears are order-independent")
    }

    func testAnEmptyOrIneligibleStateMapsToAnEmptySet() {
        XCTAssertEqual(ResetGrantObservation.observations(from: ClaudeResetState()), [])
        XCTAssertEqual(ResetGrantObservation.observations(from: ClaudeResetState(eligible: true, grants: [])), [])
        XCTAssertEqual(ResetGrantObservation.observations(from: ClaudeResetState(eligible: false, ineligibleReason: "seat")), [])
    }

    func testAGrantWithADeadlineThatIsNotADateKeepsNoDeadline() {
        let state = ClaudeResetState(eligible: true, grants: [
            ClaudeResetGrant(id: "g", resetsLeft: 1, endsAt: Date(timeIntervalSince1970: .infinity), clears: ["five_hour"])])

        XCTAssertNil(ResetGrantObservation.observations(from: state).first?.endsAtMs)
    }

    // MARK: - Legacy observations

    private func observation(
        _ provider: Provider = .claude, window: String = "five_hour", remaining: Double = 60,
        at seconds: TimeInterval = 1_800_000_000.25, resets: Date? = Date(timeIntervalSince1970: 1_800_003_600),
        source: QuotaSnapshot.SourceKind? = nil
    ) -> QuotaObservation {
        QuotaObservation(provider: provider, windowID: window, remainingPercent: remaining,
                         observedAt: Date(timeIntervalSince1970: seconds), resetsAt: resets, source: source)
    }

    func testASourceLessObservationBecomesUnknownAndNeverOAuth() throws {
        let result = QuotaSampleRow.legacyRows(from: [observation(), observation(window: "seven_day", remaining: 33)])

        XCTAssertEqual(result.count, 2)
        for row in result {
            XCTAssertEqual(row.source, .unknown)
            XCTAssertNotEqual(row.source, .oauth)
            XCTAssertTrue(row.flags.contains(.legacy))
        }
        let first = try XCTUnwrap(result.first)
        XCTAssertEqual(first.usedPercent, 40, "100 - remaining")
        XCTAssertEqual(first.readingMs, 1_800_000_000_250)
        XCTAssertEqual(first.recordedMs, first.readingMs, "the landing time was not kept")
        XCTAssertNil(first.fetchedMs)
        XCTAssertNil(first.cachedMs)
        XCTAssertEqual(first.resetsAtMs, 1_800_003_600_000)
        XCTAssertNil(first.plan)
        XCTAssertNil(first.tier)
        XCTAssertNil(first.cycleSeconds)
        XCTAssertNil(first.isActive)
        XCTAssertFalse(first.flags.contains(.futureReading))
        XCTAssertFalse(first.flags.contains(.valueNotStated))
    }

    func testALegacyObservationThatNamesItsSourceKeepsItAndIsFlaggedLegacy() {
        let result = QuotaSampleRow.legacyRows(from: [
            observation(at: 1_800_000_000, source: .oauth),
            observation(at: 1_800_000_060, source: .cli),
            observation(at: 1_800_000_120, source: nil),
        ])

        XCTAssertEqual(result.map(\.source), [.oauth, .cli, .unknown])
        XCTAssertTrue(result.allSatisfy { $0.flags == [.legacy] })
    }

    func testLegacyWindowsWithoutAResetTimeKeepItNil() {
        let result = QuotaSampleRow.legacyRows(from: [observation(remaining: 100, resets: nil)])

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].resetsAtMs)
        XCTAssertNil(result[0].resetEpochSeconds)
        XCTAssertEqual(result[0].usedPercent, 0)
    }

    func testLegacyRowsAreClaudeOnlyAndSkipSourcesThatAreNeverStored() {
        let result = QuotaSampleRow.legacyRows(from: [
            observation(.codex, window: "primary"), observation(.copilot, window: "premium_interactions"),
            observation(at: 1_800_000_000, source: .rolloutFile), observation(at: 1_800_000_030, source: .unavailable),
            observation(at: 1_800_000_060),
        ])

        XCTAssertEqual(result.map(\.provider), [.claude])
        XCTAssertEqual(result.first?.readingMs, 1_800_000_060_000)
        XCTAssertEqual(QuotaSampleRow.legacyRows(from: []), [])
    }

    func testLegacyRowsKeepOrderAndDropRepeatedKeys() {
        let result = QuotaSampleRow.legacyRows(from: [
            observation(at: 1_800_000_060, source: .oauth),
            observation(remaining: 10, at: 1_800_000_060, source: .oauth),
            observation(at: 1_800_000_060, source: .cli),
            observation(at: 1_800_000_000, source: .oauth),
        ])

        XCTAssertEqual(result.map(\.readingMs), [1_800_000_060_000, 1_800_000_060_000, 1_800_000_000_000])
        XCTAssertEqual(result.map(\.source), [.oauth, .cli, .oauth])
        XCTAssertEqual(result.first?.usedPercent, 40, "the first of a repeated key wins")
    }

    func testLegacyRowsOfARealisticDay() {
        // 24 h at 5-minute spacing for three windows: every row is legacy, unknown, Claude.
        var observations: [QuotaObservation] = []
        for step in 0..<288 {
            for window in ["five_hour", "seven_day", "seven_day_fable"] {
                observations.append(observation(window: window, remaining: 100 - Double(step % 90),
                                                at: 1_800_000_000 + Double(step) * 300))
            }
        }

        let result = QuotaSampleRow.legacyRows(from: observations)

        XCTAssertEqual(result.count, 288 * 3)
        XCTAssertTrue(result.allSatisfy { $0.source == .unknown && $0.flags == [.legacy] && $0.provider == .claude })
    }
}
