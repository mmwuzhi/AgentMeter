import Foundation
@testable import AgentMeter
import XCTest

final class QuotaRowTests: XCTestCase {
    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    // 24-hour locale so expected strings don't depend on the machine's
    // 12/24-hour setting or ICU's AM/PM spacing.
    private static let locale = Locale(identifier: "en_GB")

    private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Self.utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func absolute(_ date: Date, now: Date) -> String {
        QuotaRow.absolute(date, now: now, calendar: Self.utc, locale: Self.locale)
    }

    func testAbsoluteResetSameDayIsBareClockTime() {
        let now = utcDate(2026, 7, 10, 16, 47)

        XCTAssertEqual(absolute(utcDate(2026, 7, 10, 20, 29), now: now), "at 20:29")
    }

    func testAbsoluteResetNextDaySaysTomorrow() {
        let now = utcDate(2026, 7, 10, 23, 30)

        XCTAssertEqual(absolute(utcDate(2026, 7, 11, 7, 59), now: now), "tomorrow at 07:59")
    }

    func testAbsoluteResetWithinWeekUsesWeekday() {
        let now = utcDate(2026, 7, 10, 16, 47)

        let text = absolute(utcDate(2026, 7, 14, 23, 59), now: now)

        XCTAssertTrue(text.contains("23:59"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("tue"), text)
    }

    func testAbsoluteResetBeyondWeekUsesDate() {
        let now = utcDate(2026, 7, 10, 16, 47)

        let text = absolute(utcDate(2026, 9, 30, 4, 13), now: now)

        XCTAssertTrue(text.hasPrefix("on "), text)
        XCTAssertTrue(text.contains("2026"), text)
        // No clock time on far dates: the day is the signal there.
        XCTAssertFalse(text.contains(":"), text)
    }

    func testAbsoluteResetInPastReadsNow() {
        let now = utcDate(2026, 7, 10, 16, 47)

        XCTAssertEqual(absolute(utcDate(2026, 7, 10, 16, 46), now: now), "now")
    }

    func testRunwayAlertShowsBeyondThirtyMinutesButOnlyTurnsRedInsideIt() {
        let now = Date(timeIntervalSince1970: 1_000)
        let near = alertRunway(in: 29 * 60, from: now, message: "would run out in 29m")
        let far = alertRunway(in: 31 * 60, from: now, message: "would run out in 31m")

        // The line itself is not gated on the lead time any more — the user
        // needs "how long at this pace" well before the last half hour.
        XCTAssertEqual(QuotaRow.alertLine(near, now: now)?.text, "would run out in 29m")
        XCTAssertEqual(QuotaRow.alertLine(near, now: now)?.urgent, true)
        XCTAssertEqual(QuotaRow.alertLine(far, now: now)?.text, "would run out in 31m")
        XCTAssertEqual(QuotaRow.alertLine(far, now: now)?.urgent, false)
    }

    func testRunwayAlertRequiresAtRiskStatusAndDepletionDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let watch = QuotaRunway(
            provider: .claude,
            windowID: "five_hour",
            status: .watch,
            percentPerHour: 10,
            estimatedDepletionAt: now.addingTimeInterval(10 * 60),
            safePercentPerHour: 5,
            paceStyle: .paceVersusBudget,
            message: "using 10%/h"
        )
        let missingDate = QuotaRunway(
            provider: .claude,
            windowID: "five_hour",
            status: .atRisk,
            percentPerHour: 10,
            estimatedDepletionAt: nil,
            safePercentPerHour: 5,
            paceStyle: .paceVersusBudget,
            message: "would run out soon"
        )

        XCTAssertNil(QuotaRow.alertLine(watch, now: now))
        XCTAssertNil(QuotaRow.alertLine(missingDate, now: now))
    }

    func testRunwayAlertHelpNamesTheShortWindowThatPacesTheEstimate() {
        let now = Date(timeIntervalSince1970: 1_000)
        var paced = alertRunway(in: 7 * 3600, from: now, message: "would run out in 7h")
        paced.pacedBy = "5-hour"
        let projected = alertRunway(in: 5 * 3600, from: now, message: "would run out in 5h")

        // Same line, different footing: the tracker decided the floor, the
        // view only says where the date came from.
        XCTAssertEqual(QuotaRow.alertLine(paced, now: now)?.text, "would run out in 7h")
        XCTAssertTrue(
            QuotaRow.alertLine(paced, now: now)?.help.contains("No sooner than the 5-hour limit allows") ?? false
        )
        XCTAssertTrue(
            QuotaRow.alertLine(projected, now: now)?.help.hasPrefix("Projected from the avg drain") ?? false
        )
    }

    func testPaceComparesDrainRateAgainstBudgetRateForShortWindows() {
        let over = pace(runway(percentPerHour: 6.07, safePercentPerHour: 4.4))
        XCTAssertEqual(over?.text, "avg 6.1%/h · budget 4.4%/h")
        XCTAssertEqual(over?.overBudget, true)

        let under = pace(runway(percentPerHour: 2, safePercentPerHour: 4.4))
        XCTAssertEqual(under?.text, "avg 2%/h · budget 4.4%/h")
        XCTAssertEqual(under?.overBudget, false)

        let idle = pace(runway(percentPerHour: 0, safePercentPerHour: 5))
        XCTAssertEqual(idle?.text, "avg 0%/h · budget 5%/h")
        XCTAssertEqual(idle?.overBudget, false)
    }

    func testPaceShowsCurrentAndAverageRatesTogether() {
        let line = pace(runway(nowPercentPerHour: 12, percentPerHour: 3, safePercentPerHour: 4.4))

        XCTAssertEqual(line?.text, "now 12%/h · avg 3%/h · budget 4.4%/h")
    }

    func testPaceColorFollowsTheCurrentRateNotTheAverage() {
        // A burst that just started: the hour-long average is still under
        // budget, but the user can only act on what they are spending now.
        let starting = pace(runway(nowPercentPerHour: 12, percentPerHour: 3, safePercentPerHour: 4.4))
        XCTAssertEqual(starting?.overBudget, true)

        // The mirror case: they already stopped. The average still carries the
        // burst, but the line should not keep nagging.
        let stopped = pace(runway(nowPercentPerHour: 1, percentPerHour: 8, safePercentPerHour: 4.4))
        XCTAssertEqual(stopped?.overBudget, false)
    }

    func testPaceRendersTinyButNonZeroRatesAsLessThanATenth() {
        let line = pace(runway(nowPercentPerHour: 0, percentPerHour: 0.04, safePercentPerHour: 5))

        XCTAssertEqual(line?.text, "now 0%/h · avg <0.1%/h · budget 5%/h")
    }

    func testPaceHelpNamesTheSpansEachRateCovers() {
        let help = pace(
            runway(
                nowPercentPerHour: 12,
                percentPerHour: 3,
                safePercentPerHour: 4.4,
                nowSpan: 5 * 60,
                avgSpan: 60 * 60
            )
        )?.help ?? ""

        XCTAssertTrue(help.contains("now: drain over the last "), help)
        XCTAssertTrue(help.contains("avg: drain over the last "), help)
        XCTAssertTrue(help.contains("budget:"), help)
    }

    func testPaceHelpPutsWordsToTheAnchorTheRunwayReports() {
        func weekly(_ anchor: QuotaNowAnchor, now: Double, span: TimeInterval) -> String {
            pace(runway(nowPercentPerHour: now, percentPerHour: 1, safePercentPerHour: nil,
                        paceStyle: .paceOnly, nowSpan: span, nowAnchor: anchor))?.help ?? ""
        }
        let stepped = weekly(.step, now: 1.5, span: 40 * 60)
        let flat = weekly(.lookback, now: 0, span: 3600)
        let burst = weekly(.burst, now: 90, span: 120)
        let fiveHour = pace(
            runway(nowPercentPerHour: 12, percentPerHour: 3, safePercentPerHour: 4.4, nowSpan: 5 * 60, nowAnchor: .burst)
        )?.help ?? ""

        XCTAssertTrue(stepped.contains("now: drain over the last 40m. The span runs from the step before the latest whole-point step to now."), stepped)
        XCTAssertTrue(flat.contains("now: drain over the last 1h. Fewer than two whole-point steps landed in the last hour"), flat)
        // A burst on a long window reads like a short window's slice, and the
        // help must not claim a step that never landed.
        XCTAssertFalse(burst.contains("whole-point step"), burst)
        XCTAssertFalse(fiveHour.contains("whole-point step"), fiveHour)
    }

    func testPaceOmitsTheNowSegmentWhenRecentHistoryIsTooSparse() {
        let line = pace(runway(percentPerHour: 3, safePercentPerHour: 4.4, avgSpan: 60 * 60))

        XCTAssertEqual(line?.text, "avg 3%/h · budget 4.4%/h")
        XCTAssertFalse(line?.help.contains("now:") ?? true, line?.help ?? "")
    }

    func testPaceOnLongWindowsOmitsBudgetAndIgnoresRawComparison() {
        // Weekly-style scenario: any active use dwarfs the even-spread rate, so
        // the raw pace > budget comparison must not color the line.
        let bursting = pace(
            runway(nowPercentPerHour: 9, percentPerHour: 6.2, safePercentPerHour: 0.6, paceStyle: .paceOnly)
        )
        XCTAssertEqual(bursting?.text, "now 9%/h · avg 6.2%/h")
        XCTAssertEqual(bursting?.overBudget, false)
    }

    func testPaceOnLongWindowsTurnsOrangeOnlyWhenAtRisk() {
        let atRisk = pace(
            runway(percentPerHour: 6.2, safePercentPerHour: 0.6, status: .atRisk, paceStyle: .paceOnly)
        )
        XCTAssertEqual(atRisk?.text, "avg 6.2%/h")
        XCTAssertEqual(atRisk?.overBudget, true)
    }

    func testPaceOnLongWindowsShowsWithoutBudgetRate() {
        let line = pace(runway(percentPerHour: 2, safePercentPerHour: nil, paceStyle: .paceOnly))
        XCTAssertEqual(line?.text, "avg 2%/h")
    }

    func testPaceHiddenWithoutRateBudgetOrResetDate() {
        XCTAssertNil(pace(nil))
        XCTAssertNil(pace(runway(percentPerHour: nil, safePercentPerHour: 4)))
        XCTAssertNil(pace(runway(percentPerHour: 2, safePercentPerHour: nil)))
        XCTAssertNil(pace(runway(percentPerHour: 2, safePercentPerHour: 0)))
        XCTAssertNil(pace(runway(percentPerHour: 2, safePercentPerHour: 4, paceStyle: .hidden)))
        // A `now` rate alone is not enough: the avg is what the row is anchored on.
        XCTAssertNil(pace(runway(nowPercentPerHour: 9, percentPerHour: nil, safePercentPerHour: 4)))
    }

    func testTrackerClassifiesPaceStyleByResetHorizon() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(QuotaTrendTracker.paceStyle(resetsAt: nil, now: now), .hidden)
        XCTAssertEqual(
            QuotaTrendTracker.paceStyle(resetsAt: now.addingTimeInterval(3 * 3600), now: now),
            .paceVersusBudget
        )
        XCTAssertEqual(
            QuotaTrendTracker.paceStyle(
                resetsAt: now.addingTimeInterval(QuotaTrendTracker.longWindowHorizon), now: now),
            .paceVersusBudget,
            "exactly at the horizon still counts as a short window"
        )
        XCTAssertEqual(
            QuotaTrendTracker.paceStyle(resetsAt: now.addingTimeInterval(6 * 24 * 3600), now: now),
            .paceOnly
        )
    }

    private func pace(_ runway: QuotaRunway?) -> QuotaRow.PaceLine? {
        QuotaRow.pace(runway)
    }

    func testUpperBoundNowRendersWithALessThanSign() {
        let line = QuotaRow.pace(
            runway(
                nowPercentPerHour: 0.42,
                percentPerHour: 4.4,
                safePercentPerHour: nil,
                paceStyle: .paceOnly,
                nowSpan: 8580,
                nowAnchor: .flat,
                nowIsUpperBound: true
            )
        )
        XCTAssertEqual(line?.text, "now <0.4%/h · avg 4.4%/h")
        XCTAssertTrue(line?.help.contains("ceiling, not a measured rate") == true)
    }

    func testUpperBoundNowBelowATenthKeepsOneLessThanSign() {
        // `trimRate` writes its own `<` for a positive rate that rounds to zero,
        // and "<<0.1%/h" is not a reading.
        let line = QuotaRow.pace(
            runway(
                nowPercentPerHour: 0.04,
                percentPerHour: 2,
                safePercentPerHour: nil,
                paceStyle: .paceOnly,
                nowIsUpperBound: true
            )
        )
        XCTAssertEqual(line?.text, "now <0.1%/h · avg 2%/h")
    }

    func testUpperBoundNowDoesNotDecideTheBudgetVerdict() {
        // A ceiling says the rate is *below* its figure, so it can never
        // establish an overrun. A two-minute flat span bounds at 30%/h, which
        // would otherwise paint an idle row orange against an 8%/h budget.
        let bounded = QuotaRow.pace(
            runway(
                nowPercentPerHour: 30,
                percentPerHour: 2.9,
                safePercentPerHour: 8.2,
                nowIsUpperBound: true
            )
        )
        XCTAssertEqual(bounded?.overBudget, false)

        // Measured, and over: still orange.
        let measured = QuotaRow.pace(
            runway(nowPercentPerHour: 30, percentPerHour: 2.9, safePercentPerHour: 8.2)
        )
        XCTAssertEqual(measured?.overBudget, true)
    }

    func testStaleMeasuredNowDoesNotDecideTheBudgetVerdict() {
        // `now` outranks `avg` for the colour only because it is fresher. A
        // step-anchored `now` reaches back further than `avg` whenever the last
        // step is old, and a 40-minute reading has no business overriding a
        // 20-minute one on the grounds of being current.
        let stale = QuotaRow.pace(
            runway(
                nowPercentPerHour: 12,
                percentPerHour: 3,
                safePercentPerHour: 4.4,
                nowSpan: 40 * 60,
                avgSpan: 20 * 60
            )
        )
        XCTAssertEqual(stale?.overBudget, false)
        // Still rendered — it is a true reading, it just does not set the colour.
        XCTAssertEqual(stale?.text, "now 12%/h · avg 3%/h · budget 4.4%/h")

        // A burst inside the average's own window keeps the privilege.
        let fresh = QuotaRow.pace(
            runway(
                nowPercentPerHour: 12,
                percentPerHour: 3,
                safePercentPerHour: 4.4,
                nowSpan: 3 * 60,
                avgSpan: 20 * 60
            )
        )
        XCTAssertEqual(fresh?.overBudget, true)
    }

    private func alertRunway(in seconds: TimeInterval, from now: Date, message: String) -> QuotaRunway {
        QuotaRunway(
            provider: .claude,
            windowID: "five_hour",
            status: .atRisk,
            percentPerHour: 10,
            estimatedDepletionAt: now.addingTimeInterval(seconds),
            safePercentPerHour: 5,
            paceStyle: .paceVersusBudget,
            message: message
        )
    }

    private func runway(
        nowPercentPerHour: Double? = nil,
        percentPerHour: Double?,
        safePercentPerHour: Double?,
        status: QuotaRunwayStatus = .watch,
        paceStyle: QuotaPaceStyle = .paceVersusBudget,
        nowSpan: TimeInterval? = nil,
        avgSpan: TimeInterval? = nil,
        nowAnchor: QuotaNowAnchor? = nil,
        nowIsUpperBound: Bool = false
    ) -> QuotaRunway {
        QuotaRunway(
            provider: .claude,
            windowID: "five_hour",
            status: status,
            percentPerHour: percentPerHour,
            estimatedDepletionAt: nil,
            safePercentPerHour: safePercentPerHour,
            paceStyle: paceStyle,
            message: "",
            nowPercentPerHour: nowPercentPerHour,
            nowSpan: nowSpan,
            avgSpan: avgSpan,
            nowAnchor: nowAnchor,
            nowIsUpperBound: nowIsUpperBound
        )
    }
}
