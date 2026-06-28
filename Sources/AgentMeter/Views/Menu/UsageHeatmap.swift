import SwiftUI

/// Compact daily-token sparkline for the collapsed "Activity" row (last N days).
struct MiniSparkline: View {
    let buckets: [UsageBucket]
    var tint: Color
    var days: Int = 21

    private var values: [Int] {
        let cal = Calendar.current
        var byDay: [Date: Int] = [:]
        for b in buckets { byDay[cal.startOfDay(for: b.day), default: 0] += b.totalTokens }
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return byDay[d] ?? 0
        }
    }

    var body: some View {
        let vals = values
        let maxV = max(1, vals.max() ?? 1)
        GeometryReader { geo in
            let count = max(1, vals.count)
            let spacing: CGFloat = 1.5
            let barW = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(vals.enumerated()), id: \.offset) { _, v in
                    let h = v == 0 ? 1.5 : max(2, geo.size.height * CGFloat(Double(v) / Double(maxV)))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(v == 0 ? Color.primary.opacity(0.12) : tint.opacity(0.85))
                        .frame(width: barW, height: h)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// GitHub-style usage heatmap: weeks × 7 days, opacity by daily token volume.
struct UsageHeatmap: View {
    let buckets: [UsageBucket]
    var weeks: Int = 24
    var tint: Color = .blue

    private let cellHeight: CGFloat = 10
    private let cellSpacing: CGFloat = 2

    private struct Cell: Identifiable {
        let id: Int
        let day: Date
        let tokens: Int
        let cost: Double
    }

    // Map day -> tokens/cost, then build a week-aligned grid ending today.
    private var grid: [[Cell?]] {
        let cal = Calendar.current
        var byDay: [Date: Int] = [:]
        var byDayCost: [Date: Double] = [:]
        for b in buckets {
            let key = cal.startOfDay(for: b.day)
            byDay[key, default: 0] += b.totalTokens
            byDayCost[key, default: 0] += b.costUSD
        }

        let today = cal.startOfDay(for: Date())
        // Start from the Sunday `weeks-1` weeks ago.
        let weekday = cal.component(.weekday, from: today) - 1 // 0=Sun
        guard let gridEndStart = cal.date(byAdding: .day, value: -weekday, to: today),
              let start = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: gridEndStart) else { return [] }

        var columns: [[Cell?]] = []
        var idx = 0
        for w in 0..<weeks {
            var col: [Cell?] = []
            for d in 0..<7 {
                if let date = cal.date(byAdding: .day, value: w * 7 + d, to: start) {
                    if date > today {
                        col.append(nil)
                    } else {
                        col.append(Cell(id: idx, day: date, tokens: byDay[date] ?? 0, cost: byDayCost[date] ?? 0))
                        idx += 1
                    }
                } else {
                    col.append(nil)
                }
            }
            columns.append(col)
        }
        return columns
    }

    private var maxTokens: Int {
        max(1, buckets.map(\.totalTokens).max() ?? 1)
    }

    var body: some View {
        let cols = grid
        HStack(alignment: .top, spacing: cellSpacing) {
            ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                VStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { d in
                        cellView(col[d])
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func cellView(_ cell: Cell?) -> some View {
        if let cell {
            let frac = Double(cell.tokens) / Double(maxTokens)
            RoundedRectangle(cornerRadius: 2)
                .fill(cell.tokens == 0 ? Color.primary.opacity(0.06)
                                       : tint.opacity(0.22 + 0.78 * pow(frac, 0.6)))
                .frame(maxWidth: .infinity)
                .frame(height: cellHeight)
                .help(Self.tooltip(cell.day, cell.tokens, cell.cost))
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.clear)
                .frame(maxWidth: .infinity)
                .frame(height: cellHeight)
        }
    }

    static func tooltip(_ day: Date, _ tokens: Int, _ cost: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return "\(f.string(from: day)): \(TokenFormat.short(tokens)) tokens · $\(String(format: "%.2f", cost))"
    }
}
