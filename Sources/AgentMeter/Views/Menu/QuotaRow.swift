import SwiftUI

/// One quota window: label + large remaining % anchor + continuous bar + reset countdown.
struct QuotaRow: View {
    let window: QuotaWindow
    var runway: QuotaRunway?
    nonisolated private static let alertLeadTime: TimeInterval = 30 * 60

    private var color: Color { QuotaColor.forRemaining(window.remainingPercent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(window.remainingPercent.rounded()))")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("% left")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(color)
            }
            QuotaBar(remainingPercent: window.remainingPercent)
            if let resets = window.resetsAt {
                let verb = window.isOneTimeCredit == true ? "expires" : "resets"
                Text("\(verb) \(Self.absolute(resets))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("\(verb) \(Self.relative(resets))")
            }
            if let runway, Self.shouldShowRunwayAlert(runway) {
                Text(runway.message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if let pace = Self.pace(runway, resetsAt: window.resetsAt) {
                Text(pace.text)
                    .font(.caption2)
                    .foregroundStyle(pace.overBudget ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .help(pace.help)
            }
        }
    }

    struct PaceLine: Equatable {
        let text: String
        let overBudget: Bool
        let help: String
    }

    /// Always-visible pace readout. Windows resetting within
    /// `QuotaTrendTracker.longWindowHorizon` show the observed drain rate vs the
    /// "budget" rate (remaining % spread evenly over the time left until reset)
    /// and turn orange when pace exceeds budget. Longer windows show pace alone:
    /// their even-spread rate sits below any active use, so a raw comparison
    /// would be orange whenever the user is working at all — instead they turn
    /// orange only when the runway projection (with its burst-evidence and
    /// shorter-window guards) says the window would run out before reset. Nil
    /// when the rate or reset date is unknown, so the row stays clean on first
    /// launch or for windows without a reset date.
    nonisolated static func pace(
        _ runway: QuotaRunway?,
        resetsAt: Date?,
        now: Date = Date()
    ) -> PaceLine? {
        guard let runway,
              let rate = runway.percentPerHour,
              let resetsAt else { return nil }
        if resetsAt.timeIntervalSince(now) > QuotaTrendTracker.longWindowHorizon {
            return PaceLine(
                text: "pace \(trimRate(rate))%/h",
                overBudget: runway.status == .atRisk,
                help: "Current drain rate. Turns orange only if this window is projected to run out before it resets."
            )
        }
        guard let budget = runway.safePercentPerHour, budget > 0 else { return nil }
        return PaceLine(
            text: "pace \(trimRate(rate))%/h · budget \(trimRate(budget))%/h",
            overBudget: rate > budget,
            help: "Current drain vs the even-spread rate that would exactly last until reset."
        )
    }

    nonisolated private static func trimRate(_ value: Double) -> String {
        let s = String(format: "%.1f", value)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    nonisolated static func shouldShowRunwayAlert(_ runway: QuotaRunway, now: Date = Date()) -> Bool {
        guard runway.status == .atRisk,
              let depletion = runway.estimatedDepletionAt else { return false }
        return depletion.timeIntervalSince(now) <= alertLeadTime
    }

    /// Wall-clock phrasing for the reset line ("at 20:29", "tomorrow at 07:59",
    /// "Tue 23:59", "on 30 Sep 2026"): a clock time is easier to plan around than
    /// a countdown. The countdown form stays available as the hover tooltip.
    /// Time rendering follows the system 12/24-hour setting via the locale.
    nonisolated static func absolute(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if date.timeIntervalSince(now) <= 0 { return "now" }
        func formatter() -> DateFormatter {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            return f
        }
        let dayDelta = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch dayDelta {
        case ..<1:
            let time = formatter()
            time.timeStyle = .short
            return "at \(time.string(from: date))"
        case 1:
            let time = formatter()
            time.timeStyle = .short
            return "tomorrow at \(time.string(from: date))"
        case 2...6:
            // A weekday name is only unambiguous inside the next week; 7 days
            // out wraps around to today's own weekday, so use a date there.
            let f = formatter()
            f.setLocalizedDateFormatFromTemplate("EEEjmm")
            return f.string(from: date)
        default:
            let f = formatter()
            f.dateStyle = .medium
            return "on \(f.string(from: date))"
        }
    }

    nonisolated static func relative(_ date: Date, prefixed: Bool = true) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        // Smallest formatter unit is a minute, so sub-60s would read "0 min".
        if interval < 60 { return prefixed ? "in under a minute" : "under a minute" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        let duration = f.string(from: interval) ?? "?"
        return prefixed ? "in \(duration)" : duration
    }

    /// Past-tense counterpart of `relative`, for stale-data captions.
    nonisolated static func age(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return (f.string(from: interval) ?? "?") + " ago"
    }

}
