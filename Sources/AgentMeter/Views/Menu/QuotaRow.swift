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
                Text("\(verb) \(Self.relative(resets))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let runway, Self.shouldShowRunwayAlert(runway) {
                Text(runway.message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    nonisolated static func shouldShowRunwayAlert(_ runway: QuotaRunway, now: Date = Date()) -> Bool {
        guard runway.status == .atRisk,
              let depletion = runway.estimatedDepletionAt else { return false }
        return depletion.timeIntervalSince(now) <= alertLeadTime
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

}
