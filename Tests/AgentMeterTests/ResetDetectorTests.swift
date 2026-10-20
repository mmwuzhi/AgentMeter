import Foundation
@testable import AgentMeter
import XCTest

/// The truth table of `ResetDetector.detect` over two consecutive samples of
/// one window.
final class ResetDetectorTests: XCTestCase {
    /// 2027-01-15 07:00:00 UTC: a five-hour epoch end, to the second.
    private static let epoch: Int64 = 1_800_000_000
    private static let fiveHours: Int64 = 18_000
    private static let t0: Int64 = 1_799_990_000_000

    private func row(
        _ used: Double?,
        epoch: Int64? = ResetDetectorTests.epoch,
        epochMsOffset: Int64 = 0,
        at ms: Int64 = ResetDetectorTests.t0,
        window: String = "five_hour",
        provider: Provider = .claude,
        source: QuotaSampleSource = .oauth,
        oneTime: Bool? = nil,
        flags: QuotaSampleRow.Flags = []
    ) -> QuotaSampleRow {
        QuotaSampleRow(
            provider: provider, windowID: window, source: source, readingMs: ms, fetchedMs: ms, cachedMs: nil,
            recordedMs: ms, usedPercent: used, resetsAtMs: epoch.map { $0 * 1000 + epochMsOffset },
            cycleSeconds: 18_000, isModelScoped: nil, isOneTimeCredit: oneTime, isActive: nil, severity: nil,
            lockedReason: nil, scopeName: nil, shareUsedOfWeekly: nil, shareAllowanceOfWeekly: nil,
            plan: "max", tier: nil, flags: flags)
    }

    private func detect(_ previous: QuotaSampleRow, _ next: QuotaSampleRow) -> ResetEventKind? {
        ResetDetector.detect(previous: previous, next: next)
    }

    private static let later: Int64 = t0 + 60_000

    // MARK: - Epoch rollover

    func testEpochChangeWithALowerPercentIsARollover() {
        XCTAssertEqual(detect(row(83), row(2, epoch: Self.epoch + Self.fiveHours, at: Self.later)), .epochRollover)
        XCTAssertEqual(detect(row(100), row(0, epoch: Self.epoch + Self.fiveHours, at: Self.later)), .epochRollover)
        XCTAssertEqual(detect(row(3), row(2.5, epoch: Self.epoch + Self.fiveHours, at: Self.later)), .epochRollover,
                       "any fall counts once the epoch moved")
    }

    func testEpochChangeWithoutAFallIsNotAReset() {
        XCTAssertNil(detect(row(10), row(10, epoch: Self.epoch + Self.fiveHours, at: Self.later)))
        XCTAssertNil(detect(row(10), row(14, epoch: Self.epoch + Self.fiveHours, at: Self.later)),
                     "used again inside the gap: not provable from two samples")
        XCTAssertNil(detect(row(0), row(0, epoch: Self.epoch + Self.fiveHours, at: Self.later)))
    }

    func testAResetTimeThatAppearsOrDisappearsCountsAsAMovedEpoch() {
        // An idle five-hour window reports no reset time: the epoch ending is a rollover.
        XCTAssertEqual(detect(row(40), row(0, epoch: nil, at: Self.later)), .epochRollover)
        XCTAssertNil(detect(row(0, epoch: nil), row(3, epoch: Self.epoch, at: Self.later)), "a window starting is not a reset")
        XCTAssertNil(detect(row(0, epoch: nil), row(0, epoch: nil, at: Self.later)))
    }

    // MARK: - Early drop

    func testAFallOfFivePointsOrMoreInsideOneEpochIsAnEarlyDrop() {
        XCTAssertEqual(detect(row(60), row(55, at: Self.later)), .earlyDrop, "exactly the threshold")
        XCTAssertEqual(detect(row(60), row(0, at: Self.later)), .earlyDrop)
        XCTAssertEqual(detect(row(12.5), row(7.4, at: Self.later)), .earlyDrop)
        XCTAssertEqual(ResetDetector.earlyDropMinPoints, 5)
    }

    func testASmallFallOrARiseInsideOneEpochIsNothing() {
        XCTAssertNil(detect(row(60), row(55.1, at: Self.later)))
        XCTAssertNil(detect(row(60), row(59, at: Self.later)))
        XCTAssertNil(detect(row(60), row(60, at: Self.later)))
        XCTAssertNil(detect(row(60), row(80, at: Self.later)))
    }

    /// 59.979 s and 0.005 s past the minute are one epoch: the nearest-minute
    /// rounding makes this an early drop, not a rollover.
    func testJitterAroundTheMinuteIsNotAnEpochChange() {
        let before = row(60, epoch: Self.epoch - 1, epochMsOffset: 979)            // hh:59:59.979
        let after = row(20, epoch: Self.epoch, epochMsOffset: 5, at: Self.later)    // hh:00:00.005
        XCTAssertEqual(before.resetEpochSeconds, after.resetEpochSeconds)
        XCTAssertEqual(detect(before, after), .earlyDrop)
        XCTAssertNil(detect(before, row(58, epoch: Self.epoch, epochMsOffset: 5, at: Self.later)))
    }

    func testAnEarlierEpochIsJudgedByTheEarlyDropRule() {
        XCTAssertEqual(detect(row(60), row(20, epoch: Self.epoch - Self.fiveHours, at: Self.later)), .earlyDrop)
        XCTAssertNil(detect(row(60), row(58, epoch: Self.epoch - Self.fiveHours, at: Self.later)))
        XCTAssertNil(detect(row(60), row(70, epoch: Self.epoch - Self.fiveHours, at: Self.later)))
    }

    func testTwoWindowsWithoutAResetTimeFallBackToTheEarlyDropRule() {
        XCTAssertEqual(detect(row(60, epoch: nil), row(20, epoch: nil, at: Self.later)), .earlyDrop)
        XCTAssertNil(detect(row(60, epoch: nil), row(58, epoch: nil, at: Self.later)))
    }

    // MARK: - Which pairs qualify

    func testOnlyClaudeOAuthRowsOfTheSameWindowQualify() {
        let down = { (source: QuotaSampleSource, provider: Provider, window: String) in
            ResetDetector.detect(previous: self.row(60, provider: provider), next:
                self.row(0, at: Self.later, window: window, provider: provider, source: source))
        }
        XCTAssertEqual(down(.oauth, .claude, "five_hour"), .earlyDrop)
        for source in [QuotaSampleSource.cli, .unknown, .appServer, .rolloutFile] {
            XCTAssertNil(down(source, .claude, "five_hour"), "\(source)")
        }
        XCTAssertNil(down(.oauth, .codex, "five_hour"))
        XCTAssertNil(down(.oauth, .copilot, "five_hour"))
        XCTAssertNil(detect(row(60), row(0, at: Self.later, window: "seven_day")), "another window")

        // A mixed pair never qualifies, whichever side is the odd one.
        XCTAssertNil(detect(row(60, source: .cli), row(0, at: Self.later)))
        XCTAssertNil(detect(row(60), row(0, at: Self.later, source: .cli)))
        XCTAssertNil(detect(row(60, provider: .codex), row(0, at: Self.later)))
        XCTAssertNil(detect(row(60), row(0, at: Self.later, provider: .codex)))
    }

    func testOnlyAForwardPairQualifies() {
        XCTAssertNil(detect(row(60), row(0, at: Self.t0)), "the same instant")
        XCTAssertNil(detect(row(60), row(0, at: Self.t0 - 1)), "an older sample after a newer one")
        XCTAssertEqual(detect(row(60), row(0, at: Self.t0 + 1)), .earlyDrop)
    }

    func testAPlaceholderOrAOneTimeCreditIsNoReset() {
        XCTAssertNil(detect(row(60), row(0, at: Self.later, flags: [.valueNotStated])), "a placeholder 0 is not a fall")
        XCTAssertNil(detect(row(0, flags: [.valueNotStated]), row(0, epoch: Self.epoch + Self.fiveHours, at: Self.later)))
        XCTAssertNil(detect(row(60, oneTime: true), row(0, at: Self.later, oneTime: true)))
        XCTAssertNil(detect(row(60, oneTime: true), row(0, epoch: Self.epoch + 1_000_000, at: Self.later, oneTime: true)))
        XCTAssertEqual(detect(row(60, oneTime: false), row(0, at: Self.later, oneTime: false)), .earlyDrop)
    }

    func testAFutureReadingStillCounts() {
        XCTAssertEqual(detect(row(60), row(0, at: Self.later, flags: [.futureReading])), .earlyDrop)
    }

    /// A window that stated no utilization has no value to fall from or to,
    /// with or without the flag.
    func testARowWithNoValueNeverDetects() {
        XCTAssertNil(detect(row(60), row(nil, at: Self.later)))
        XCTAssertNil(detect(row(nil), row(0, at: Self.later)))
        XCTAssertNil(detect(row(nil), row(nil, epoch: Self.epoch + Self.fiveHours, at: Self.later)))
        XCTAssertNil(detect(row(60), row(nil, epoch: Self.epoch + Self.fiveHours, at: Self.later, flags: [.valueNotStated])))
        XCTAssertNil(detect(row(nil, flags: [.valueNotStated]), row(0, epoch: Self.epoch + Self.fiveHours, at: Self.later)))
        XCTAssertNil(ResetDetector.draft(previous: row(60), next: row(nil, at: Self.later)))
    }

    // MARK: - The draft

    func testDraftCarriesTheFactsOfTheEvent() throws {
        let previous = row(83, at: Self.t0)
        let next = row(2, epoch: Self.epoch + Self.fiveHours, at: Self.later)

        let draft = try XCTUnwrap(ResetDetector.draft(previous: previous, next: next))

        XCTAssertEqual(draft, ResetEventDraft(
            provider: .claude, windowID: "five_hour", kind: .epochRollover,
            detectedMs: Self.later, prevSampleMs: Self.t0, prevPercent: 83, newPercent: 2,
            prevEpochSeconds: Self.epoch, newEpochSeconds: Self.epoch + Self.fiveHours))
        XCTAssertNil(ResetDetector.draft(previous: row(10), next: row(11, at: Self.later)))
        XCTAssertEqual(ResetDetector.detectorVersion, 1)
    }

    func testKindsHaveStableStoredNames() {
        XCTAssertEqual(ResetEventKind.epochRollover.rawValue, "epoch_rollover")
        XCTAssertEqual(ResetEventKind.earlyDrop.rawValue, "early_drop")
        XCTAssertEqual(Set(ResetEventKind.allCases.map(\.rawValue)).count, 2)
    }

    /// A walk over a day of readings: the events are exactly the rollovers.
    func testWalkingAStreamFindsTheRolloversAndNothingElse() {
        // Five-hour epochs 5 h apart; used climbs inside an epoch and restarts at the next.
        var samples: [QuotaSampleRow] = []
        var minute: Int64 = 0
        for epochIndex in 0..<3 {
            let epoch = Self.epoch + Int64(epochIndex) * Self.fiveHours
            for step in 0..<6 {
                samples.append(row(Double(step * 15 + epochIndex), epoch: epoch, epochMsOffset: step.isMultiple(of: 2) ? 700 : -300,
                                   at: Self.t0 + minute * 60_000))
                minute += 50
            }
        }
        var kinds: [ResetEventKind] = []
        for index in 1..<samples.count {
            if let kind = ResetDetector.detect(previous: samples[index - 1], next: samples[index]) { kinds.append(kind) }
        }
        XCTAssertEqual(kinds, [.epochRollover, .epochRollover])
    }
}
