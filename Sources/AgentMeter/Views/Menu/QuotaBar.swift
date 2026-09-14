import SwiftUI

/// Threshold color shared by the quota bar and the headline percentage.
enum QuotaColor {
    static func forRemaining(_ pct: Double) -> Color {
        switch pct {
        case ..<10: return .red
        case ..<25: return .orange
        case ..<50: return .yellow
        default: return .green
        }
    }
}

/// Continuous quota bar: a rounded neutral track with a threshold-colored fill.
/// `fillsByUsed` drains it from full or grows it toward the limit; either way
/// the colour reads the remainder, so the bar goes red because little is left
/// rather than because a lot was used and `QuotaColor` keeps one definition.
struct QuotaBar: View {
    let remainingPercent: Double   // 0...100
    /// Deliberately has no default: a renderer that does not say which end it
    /// draws would silently disagree with the rest of the app once the
    /// preference is on.
    let fillsByUsed: Bool

    private var fraction: Double {
        let remaining = max(0, min(100, remainingPercent)) / 100
        return fillsByUsed ? 1 - remaining : remaining
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(QuotaColor.forRemaining(remainingPercent))
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}
