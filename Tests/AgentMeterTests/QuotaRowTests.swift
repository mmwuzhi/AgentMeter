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

    func testRunwayAlertOnlyShowsWithinThirtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let near = QuotaRunway(
            provider: .claude,
            windowID: "five_hour",
            status: .atRisk,
            percentPerHour: 10,
            estimatedDepletionAt: now.addingTimeInterval(29 * 60),
            safePercentPerHour: 5,
            message: "would run out in 29m"
        )
        let far = QuotaRunway(
            provider: .claude,
            windowID: "five_hour",
            status: .atRisk,
            percentPerHour: 10,
            estimatedDepletionAt: now.addingTimeInterval(31 * 60),
            safePercentPerHour: 5,
            message: "would run out in 31m"
        )

        XCTAssertTrue(QuotaRow.shouldShowRunwayAlert(near, now: now))
        XCTAssertFalse(QuotaRow.shouldShowRunwayAlert(far, now: now))
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
            message: "using 10%/h"
        )
        let missingDate = QuotaRunway(
            provider: .claude,
            windowID: "five_hour",
            status: .atRisk,
            percentPerHour: 10,
            estimatedDepletionAt: nil,
            safePercentPerHour: 5,
            message: "would run out soon"
        )

        XCTAssertFalse(QuotaRow.shouldShowRunwayAlert(watch, now: now))
        XCTAssertFalse(QuotaRow.shouldShowRunwayAlert(missingDate, now: now))
    }
}
