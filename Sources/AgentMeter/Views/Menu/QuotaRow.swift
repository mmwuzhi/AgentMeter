import SwiftUI

/// One quota window: label + large remaining % anchor + continuous bar + reset countdown.
struct QuotaRow: View {
    let window: QuotaWindow
    var runway: QuotaRunway?

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
                    Text("%")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(color)
            }
            QuotaBar(remainingPercent: window.remainingPercent)
            if let resets = window.resetsAt {
                Text("resets \(Self.relative(resets))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let runway, runway.status == .atRisk {
                Text(runway.message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    nonisolated static func relative(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return "in " + (f.string(from: interval) ?? "?")
    }

}
