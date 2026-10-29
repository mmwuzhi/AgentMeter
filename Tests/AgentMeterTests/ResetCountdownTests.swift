import Foundation
@testable import AgentMeter
import XCTest

final class ResetCountdownTests: XCTestCase {
    /// The clock is always an argument, so nothing here waits for real time.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func text(in seconds: TimeInterval, at clock: TimeInterval = 0) -> String? {
        ResetCountdown.text(until: now.addingTimeInterval(seconds), now: now.addingTimeInterval(clock))
    }

    // MARK: Format

    func testFiveHourWindowReadsHoursAndMinutes() {
        let reset = now.addingTimeInterval(3 * 3600 + 23 * 60)

        XCTAssertEqual(ResetCountdown.text(until: reset, now: now), "3h23m")
        XCTAssertEqual(text(in: 5 * 3600), "5h00m")
        XCTAssertEqual(text(in: 4 * 3600 + 5 * 60), "4h05m")
    }

    func testMinutesRoundUpSoItMatchesTheClockDifference() {
        // 14:00 seen at 10:37:xx is 3h23m for the whole minute, as the clock
        // difference says, and the caption changes when the clock minute does.
        let reset = now.addingTimeInterval(3 * 3600 + 23 * 60)

        XCTAssertEqual(ResetCountdown.text(until: reset, now: now), "3h23m")
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now.addingTimeInterval(1)), "3h23m")
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now.addingTimeInterval(59)), "3h23m")
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now.addingTimeInterval(60)), "3h22m")
    }

    func testUnderAnHourReadsMinutesOnly() {
        XCTAssertEqual(text(in: 45 * 60), "45m")
        XCTAssertEqual(text(in: 59 * 60), "59m")
        XCTAssertEqual(text(in: 60 * 60), "1h00m")
        XCTAssertEqual(text(in: 5 * 60 + 1), "6m")
    }

    func testTheLastSecondsNeverReadZeroMinutes() {
        XCTAssertEqual(text(in: 60), "1m")
        XCTAssertEqual(text(in: 30), "1m")
        XCTAssertEqual(text(in: 0.001), "1m")
    }

    func testWeeklyWindowReadsDaysAndHours() {
        XCTAssertEqual(text(in: 6 * 86_400 + 12 * 3600), "6d12h")
        XCTAssertEqual(text(in: 7 * 86_400), "7d00h")
        XCTAssertEqual(text(in: 6 * 86_400 + 11 * 3600 + 59 * 60), "6d11h")
        XCTAssertEqual(text(in: 2 * 86_400 + 5 * 3600), "2d05h")
    }

    func testDayBoundary() {
        XCTAssertEqual(text(in: 86_400), "1d00h")
        XCTAssertEqual(text(in: 86_400 - 60), "23h59m")
        XCTAssertEqual(text(in: 86_400 + 3600), "1d01h")
    }

    func testCaptionKeepsItsLengthWhileCountingDown() {
        // The minute and hour fields are padded, so within a form the caption
        // changes length only when its leading number gains a digit (10h, 10d):
        // the item's length follows its text, and each change would move the popover.
        for minutes in stride(from: 60, to: 24 * 60, by: 7) {
            let hours = minutes / 60
            XCTAssertEqual(text(in: TimeInterval(minutes * 60))?.count, String(hours).count + 4, "\(minutes) min")
        }
        for hours in stride(from: 24, to: 99 * 24, by: 5) {
            let days = hours / 24
            XCTAssertEqual(text(in: TimeInterval(hours * 3600))?.count, String(days).count + 4, "\(hours) h")
        }
    }

    // MARK: No usable reset

    func testNoResetStatedHasNoCountdown() {
        XCTAssertNil(ResetCountdown.text(until: nil, now: now))
    }

    func testPassedResetHasNoCountdown() {
        XCTAssertNil(text(in: 0))
        XCTAssertNil(text(in: -1))
        XCTAssertNil(text(in: -86_400))
    }

    func testResetBeyondTheDayDigitsHasNoCountdown() {
        // The cap is on the rounded minutes, so the day count never reaches 100.
        let limit = TimeInterval(ResetCountdown.maximumMinutes * 60)

        XCTAssertEqual(text(in: limit - 60), "99d23h")
        XCTAssertNil(text(in: limit - 59))
        XCTAssertNil(text(in: limit - 0.5))
        XCTAssertNil(text(in: limit))
        XCTAssertNil(text(in: 400 * 86_400))
    }

    func testAbsurdProviderDatesAreRefusedWithoutTrapping() {
        // The integer conversion sits behind the range check, so a date a
        // provider response could not have meant never reaches it.
        for seconds in [1e300, Double.greatestFiniteMagnitude, Double.infinity, Double.nan] {
            let reset = Date(timeIntervalSince1970: seconds)
            XCTAssertNil(ResetCountdown.text(until: reset, now: now), "\(seconds)")
            XCTAssertNil(ResetCountdown.nextChange(of: reset, after: now), "\(seconds)")
        }
    }

    // MARK: A moving clock

    func testSameResetCountsDownAsTheClockAdvances() {
        // No new usage data arrives: only the clock moves.
        let reset = now.addingTimeInterval(3 * 3600 + 23 * 60)
        let clock: [TimeInterval] = [0, 60, 120, 1380, 12_150, 12_179]
        let readings = clock.map { ResetCountdown.text(until: reset, now: now.addingTimeInterval($0)) }

        XCTAssertEqual(readings, ["3h23m", "3h22m", "3h21m", "3h00m", "1m", "1m"])
    }

    func testResumingAfterSleepReadsTheClockNotTheLastTick() {
        let reset = now.addingTimeInterval(3 * 3600 + 23 * 60)
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now), "3h23m")

        // The lid was shut for 1h28m; nothing ticked in between.
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now.addingTimeInterval(88 * 60)), "1h55m")
        // Or for longer than the window had left.
        XCTAssertNil(ResetCountdown.text(until: reset, now: now.addingTimeInterval(8 * 3600)))
    }

    func testAClockSetBackExtendsTheCountdown() {
        let reset = now.addingTimeInterval(30 * 60)
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now.addingTimeInterval(10 * 60)), "20m")
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now.addingTimeInterval(-3600)), "1h30m")
    }

    func testAChangedResetReplacesTheCountdown() {
        let first = now.addingTimeInterval(20 * 60)
        let moved = now.addingTimeInterval(5 * 3600)

        XCTAssertEqual(ResetCountdown.text(until: first, now: now), "20m")
        XCTAssertEqual(ResetCountdown.text(until: moved, now: now), "5h00m")
    }

    // MARK: When the caption changes next

    func testNextChangeIsTheNextMinuteBoundary() {
        let reset = now.addingTimeInterval(3 * 3600 + 23 * 60)

        // 3h23m holds for the whole minute and becomes 3h22m at its end.
        XCTAssertEqual(ResetCountdown.nextChange(of: reset, after: now), now.addingTimeInterval(60))
        XCTAssertEqual(ResetCountdown.nextChange(of: reset, after: now.addingTimeInterval(30)),
                       now.addingTimeInterval(60))
        XCTAssertEqual(ResetCountdown.nextChange(of: reset, after: now.addingTimeInterval(60)),
                       now.addingTimeInterval(120))
    }

    func testNextChangeOfTheLastMinuteIsTheReset() {
        let reset = now.addingTimeInterval(30)

        XCTAssertEqual(ResetCountdown.nextChange(of: reset, after: now), reset)
    }

    func testNextChangeInTheDayFormSkipsTheMinutesItDoesNotShow() {
        // 6d12h30m reads "6d12h" until the minute count drops under 6d12h: the
        // hour is the finest thing the caption says, so the 30 minutes in
        // between need no tick.
        let remainingSeconds = 6 * 86_400 + 12 * 3600 + 30 * 60
        let reset = now.addingTimeInterval(TimeInterval(remainingSeconds))

        XCTAssertEqual(ResetCountdown.text(until: reset, now: now), "6d12h")
        XCTAssertEqual(ResetCountdown.nextChange(of: reset, after: now), now.addingTimeInterval(31 * 60))
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now.addingTimeInterval(30 * 60)), "6d12h")
        XCTAssertEqual(ResetCountdown.text(until: reset, now: now.addingTimeInterval(31 * 60 + 1)), "6d11h")
    }

    func testNothingToScheduleWithoutACountdown() {
        XCTAssertNil(ResetCountdown.nextChange(of: now, after: now))
        XCTAssertNil(ResetCountdown.nextChange(of: now.addingTimeInterval(-60), after: now))
    }

    func testNextChangeIsExactlyWhereTheCaptionChanges() {
        // Whatever the instant and whatever form the caption is in, the text
        // holds up to the returned instant and differs from it on. The offsets
        // run from seconds to the day-form range and include fractional seconds,
        // which provider timestamps carry.
        var generator = SeededGenerator(seed: 7)
        var offsets: [TimeInterval] = [0.001, 1, 59.999, 60, 60.001, 3599, 3600, 3601, 86_399, 86_400, 86_401,
                                       86_400 + 3599, 86_400 + 3600, 7 * 86_400]
        for _ in 0..<1500 { offsets.append(Double.random(in: 0.01...(8 * 86_400), using: &generator)) }

        for offset in offsets {
            let reset = now.addingTimeInterval(offset + 0.37)
            let before = ResetCountdown.text(until: reset, now: now)
            guard let change = ResetCountdown.nextChange(of: reset, after: now) else {
                return XCTFail("no next change at offset \(offset)")
            }
            XCTAssertGreaterThan(change, now, "offset \(offset)")
            XCTAssertEqual(ResetCountdown.text(until: reset, now: change.addingTimeInterval(-0.001)), before,
                           "offset \(offset): changed early")
            XCTAssertNotEqual(ResetCountdown.text(until: reset, now: change.addingTimeInterval(0.001)), before,
                              "offset \(offset): did not change at \(change.timeIntervalSince(now))")
        }
    }
}

/// A seeded generator, so a failing offset can be reproduced.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
