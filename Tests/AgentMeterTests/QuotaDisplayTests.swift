import Foundation
@testable import AgentMeter
import XCTest

final class QuotaDisplayTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: QuotaDisplay.defaultsKey)
        super.tearDown()
    }

    func testDefaultsToRemaining() {
        // The reading the app has always shown; an upgrade must not silently
        // turn every row over.
        UserDefaults.standard.removeObject(forKey: QuotaDisplay.defaultsKey)
        XCTAssertFalse(QuotaDisplay.showsUsed)
    }

    func testPreferenceIsReadBackFromDefaults() {
        UserDefaults.standard.set(true, forKey: QuotaDisplay.defaultsKey)
        XCTAssertTrue(QuotaDisplay.showsUsed)
        UserDefaults.standard.set(false, forKey: QuotaDisplay.defaultsKey)
        XCTAssertFalse(QuotaDisplay.showsUsed)
    }

    func testPercentReadsEitherEndOfTheSameWindow() {
        XCTAssertEqual(QuotaDisplay.percent(remaining: 15, showsUsed: false), 15)
        XCTAssertEqual(QuotaDisplay.percent(remaining: 15, showsUsed: true), 85)
    }

    func testPercentClampsAnOverrun() {
        // Providers have been seen to report over 100% utilization, which
        // arrives here as a negative remainder.
        XCTAssertEqual(QuotaDisplay.percent(remaining: -3, showsUsed: true), 100)
        XCTAssertEqual(QuotaDisplay.percent(remaining: -3, showsUsed: false), 0)
        XCTAssertEqual(QuotaDisplay.percent(remaining: 140, showsUsed: true), 0)
        XCTAssertEqual(QuotaDisplay.percent(remaining: 140, showsUsed: false), 100)
    }

    func testCaptionNamesTheEndTheFigureCountsFrom() {
        XCTAssertEqual(QuotaDisplay.caption(showsUsed: false), "% left")
        XCTAssertEqual(QuotaDisplay.caption(showsUsed: true), "% used")
    }

    func testCaptionIsBuiltFromTheSpokenWord() {
        // The menu bar's accessibility summary speaks the word on its own, so
        // the two must not be able to drift apart.
        XCTAssertEqual(QuotaDisplay.word(showsUsed: false), "left")
        XCTAssertEqual(QuotaDisplay.word(showsUsed: true), "used")
        for showsUsed in [true, false] {
            XCTAssertEqual(
                QuotaDisplay.caption(showsUsed: showsUsed),
                "% " + QuotaDisplay.word(showsUsed: showsUsed)
            )
        }
    }
}
