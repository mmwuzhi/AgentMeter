import Foundation

/// The caption a Claude quota column shows in place of its window code: how long
/// until that window's own `resets_at`.
///
/// Pure functions of a reset instant and a clock reading, so the one-minute
/// ticks, sleep and clock changes all reduce to "ask again with the current
/// time"; nothing here keeps state.
enum ResetCountdown {
    /// The day count has to stay at two digits for the caption to stay short, so
    /// a reset this far out or further is not shown as a countdown.
    static let maximumMinutes = 100 * 24 * 60

    /// `45m`, `3h05m`, `6d12h`: the two largest units, the smaller one padded to
    /// two digits so the caption keeps its width as it counts down. Minutes
    /// round up (14:00 seen at 10:37:20 reads 3h23m, the clock difference, and
    /// it never reads `0m` before the reset); the day form drops the leftover
    /// minutes. Nil when there is no future reset to count to: none stated, the
    /// time has passed, or it is `maximumMinutes` or more away.
    static func text(until reset: Date?, now: Date) -> String? {
        guard let minutes = minutesLeft(until: reset, now: now) else { return nil }
        let day = 24 * 60
        if minutes < 60 { return "\(minutes)m" }
        if minutes < day { return "\(minutes / 60)h\(twoDigits(minutes % 60))m" }
        return "\(minutes / day)d\(twoDigits(minutes % day / 60))h"
    }

    /// The first instant after `now` at which `text(until:now:)` reads
    /// differently, which includes becoming nil at the reset itself. Nil when it
    /// reads nil already.
    static func nextChange(of reset: Date, after now: Date) -> Date? {
        guard let minutes = minutesLeft(until: reset, now: now) else { return nil }
        // The caption holds until the minute count drops to `target`: one
        // minute lower, or, in the day form that shows whole hours only, to the
        // minute before the hour boundary.
        let day = 24 * 60
        let target = minutes >= day ? minutes / 60 * 60 - 1 : minutes - 1
        return reset.addingTimeInterval(-TimeInterval(target * 60))
    }

    private static func minutesLeft(until reset: Date?, now: Date) -> Int? {
        guard let reset else { return nil }
        let seconds = reset.timeIntervalSince(now)
        // Range-checked before the integer conversion: a provider-supplied date
        // can be arbitrarily far out, and NaN fails both comparisons.
        guard seconds > 0, seconds <= Double(maximumMinutes) * 60 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes < maximumMinutes ? minutes : nil
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
