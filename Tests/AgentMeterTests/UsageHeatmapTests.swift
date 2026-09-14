import Foundation
@testable import AgentMeter
import XCTest

final class UsageHeatmapTests: XCTestCase {
    private let cal = Calendar.current

    private func day(_ offset: Int, from today: Date) -> Date {
        cal.date(byAdding: .day, value: offset, to: today)!
    }

    private func point(_ day: Date, tokens: Int, cost: Double = 1) -> UsageDayPoint {
        UsageDayPoint(day: day, tokens: tokens, costUSD: cost)
    }

    func testGridPlotsADayThatOnlyTheLedgerKnows() {
        let today = cal.startOfDay(for: Date())
        let old = day(-100, from: today)

        let cells = UsageHeatmap.grid(points: [point(old, tokens: 42)], weeks: 24,
                                      today: today, calendar: cal)
            .joined().compactMap { $0 }

        XCTAssertEqual(cells.first { $0.day == old }?.tokens, 42)
    }

    func testGridCoversTwentyFourWeeksBackFromToday() {
        let today = cal.startOfDay(for: Date())
        let cells = UsageHeatmap.grid(points: [], weeks: 24, today: today, calendar: cal)
            .joined().compactMap { $0 }

        XCTAssertNotNil(cells.first { $0.day == day(-160, from: today) },
                        "a 24-week grid must reach back past 160 days")
        XCTAssertNil(cells.first { $0.day > today },
                     "future days are blanks, not cells")
    }

    /// The ledger now feeds the heatmap and reaches further back than the grid.
    /// A huge day outside the window must not become the color scale's maximum,
    /// which would wash every visible cell out to the faintest tint.
    func testDaysOutsideTheGridAreNotPlotted() {
        let today = cal.startOfDay(for: Date())
        let cells = UsageHeatmap.grid(
            points: [point(day(-400, from: today), tokens: 9_000_000),
                     point(day(-3, from: today), tokens: 10)],
            weeks: 24, today: today, calendar: cal
        ).joined().compactMap { $0 }

        XCTAssertEqual(cells.map(\.tokens).max(), 10)
    }

    func testGridSumsMultiplePointsOnTheSameDay() {
        let today = cal.startOfDay(for: Date())
        let d = day(-5, from: today)

        let cells = UsageHeatmap.grid(points: [point(d, tokens: 3, cost: 1.5),
                                               point(d, tokens: 4, cost: 2.5)],
                                      weeks: 24, today: today, calendar: cal)
            .joined().compactMap { $0 }

        let cell = cells.first { $0.day == d }
        XCTAssertEqual(cell?.tokens, 7)
        XCTAssertEqual(cell?.cost ?? 0, 4, accuracy: 0.001)
    }
}
