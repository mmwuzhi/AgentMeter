import Foundation
@testable import AgentMeter
import XCTest

final class QuotaRowTests: XCTestCase {
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
