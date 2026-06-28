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
struct QuotaBar: View {
    let remainingPercent: Double   // 0...100

    private var fraction: Double { max(0, min(1, remainingPercent / 100)) }

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
