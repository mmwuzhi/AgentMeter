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
            // Both lines can show at once: the pace line answers "how fast right
            // now", the run-out line "how long at the recent pace". One never
            // replaces the other.
            if let pace = Self.pace(runway) {
                Text(pace.text)
                    .font(.caption2)
                    .foregroundStyle(pace.overBudget ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .help(pace.help)
            }
            if let runway, let alert = Self.alertLine(runway) {
                Text(alert.text)
                    .font(.caption2)
                    .foregroundStyle(alert.urgent ? Color.red : Color.orange)
                    .help(alert.help)
            }
        }
    }

    struct PaceLine: Equatable {
        let text: String
        let overBudget: Bool
        let help: String
    }

    struct AlertLine: Equatable {
        let text: String
        /// Depletion inside `alertLeadTime`: red instead of orange.
        let urgent: Bool
        let help: String
    }

    /// Always-visible pace readout: `now · avg · budget`, rendered per the
    /// runway's `paceStyle` (decided by `QuotaTrendTracker`). `now` is the
    /// short-window drain and is omitted when the tracker has nothing recent
    /// enough; `avg` is the long-window drain behind the run-out estimate.
    /// Short windows also show the even-spread "budget" rate and turn orange
    /// when `now` (or `avg`, if `now` is missing) exceeds it; long-horizon
    /// windows omit the budget and turn orange only on an at-risk runway,
    /// because their even-spread rate sits below any active use. Nil when the
    /// avg rate or budget is unknown, so the row stays clean on first launch or
    /// for windows without a reset date.
    nonisolated static func pace(_ runway: QuotaRunway?) -> PaceLine? {
        guard let runway, let average = runway.percentPerHour else { return nil }
        var parts: [String] = []
        if let now = runway.nowPercentPerHour {
            parts.append("now \(trimRate(now))%/h")
        }
        parts.append("avg \(trimRate(average))%/h")
        switch runway.paceStyle {
        case .hidden:
            return nil
        case .paceOnly:
            return PaceLine(
                text: parts.joined(separator: " · "),
                overBudget: runway.status == .atRisk,
                help: paceHelp(runway, style: .paceOnly)
            )
        case .paceVersusBudget:
            guard let budget = runway.safePercentPerHour, budget > 0 else { return nil }
            parts.append("budget \(trimRate(budget))%/h")
            let leading = runway.nowPercentPerHour ?? average
            return PaceLine(
                text: parts.joined(separator: " · "),
                overBudget: leading > budget,
                help: paceHelp(runway, style: .paceVersusBudget)
            )
        }
    }

    /// Hover text names the spans each rate actually covers, so a `now` that had
    /// to stretch across a sampling gap (background refresh cadence) says so
    /// instead of pretending to be instantaneous.
    nonisolated private static func paceHelp(_ runway: QuotaRunway, style: QuotaPaceStyle) -> String {
        // The style is the tracker's decision; this only puts words to it.
        let hasBudget = style == .paceVersusBudget
        var lines: [String] = []
        if runway.nowPercentPerHour != nil {
            let span = runway.nowSpan.map { "over the last \(spanText($0))" } ?? "over a short recent span"
            // Step-anchored windows move in whole-point steps, so their `now`
            // span is however long the latest step took rather than a fixed
            // slice; the runway says which reading this was.
            let stretch: String
            switch runway.nowAnchor {
            case .step:
                stretch = " The span runs from the step before the latest whole-point step to now."
            case .lookback:
                stretch = " Fewer than two whole-point steps landed in the last hour, so the span reaches back across it."
            case .burst, .slice, nil:
                stretch = ""
            }
            lines.append("now: drain \(span).\(stretch)")
        }
        let avgSpan = runway.avgSpan.map { "over the last \(spanText($0))" } ?? "over the recent history"
        lines.append("avg: drain \(avgSpan); the run-out estimate uses this.")
        if hasBudget {
            lines.append("budget: the even-spread rate that would exactly last until reset. Orange when now exceeds budget.")
        } else {
            lines.append("Turns orange only if this window is projected to run out before it resets.")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func trimRate(_ value: Double) -> String {
        let s = String(format: "%.1f", value)
        // A weekly window idling at a fraction of a point per hour is not "0".
        if s == "0.0", value > 0 { return "<0.1" }
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    nonisolated private static func spanText(_ interval: TimeInterval) -> String {
        if interval < 60 { return "minute" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f.string(from: interval) ?? "?"
    }

    /// Run-out line: shown for every at-risk runway that carries a depletion
    /// date, red inside `alertLeadTime` and orange beyond it. Nil for `.watch`
    /// (pace shown without a date) and for runways a shorter window constrains.
    nonisolated static func alertLine(_ runway: QuotaRunway, now: Date = Date()) -> AlertLine? {
        guard runway.status == .atRisk,
              let depletion = runway.estimatedDepletionAt else { return nil }
        let avgSpan = runway.avgSpan.map { " over the last \(spanText($0))" } ?? ""
        return AlertLine(
            text: runway.message,
            urgent: depletion.timeIntervalSince(now) <= alertLeadTime,
            help: "Projected from the avg drain\(avgSpan). Red inside the last 30 minutes."
        )
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
