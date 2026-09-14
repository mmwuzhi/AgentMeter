import SwiftUI

/// Compact daily-token sparkline for the collapsed "Activity" row (last N days).
/// One bar per day; hovering a bar shows that day's tokens + spend.
struct MiniSparkline: View {
    let points: [UsageDayPoint]
    var tint: Color
    var days: Int = 21

    private struct DayValue: Identifiable {
        let day: Date
        let tokens: Int
        let cost: Double
        var id: Date { day }
    }

    private var values: [DayValue] {
        let cal = Calendar.current
        var byDay: [Date: Int] = [:]
        var byDayCost: [Date: Double] = [:]
        for p in points {
            let key = cal.startOfDay(for: p.day)
            byDay[key, default: 0] += p.tokens
            byDayCost[key, default: 0] += p.costUSD
        }
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayValue(day: d, tokens: byDay[d] ?? 0, cost: byDayCost[d] ?? 0)
        }
    }

    var body: some View {
        let vals = values
        let maxV = max(1, vals.map(\.tokens).max() ?? 1)
        GeometryReader { geo in
            let count = max(1, vals.count)
            let spacing: CGFloat = 2
            let barW = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(vals) { v in
                    // Sqrt-ish scaling keeps one spike day from flattening
                    // every other bar into an unreadable dot.
                    let frac = pow(Double(v.tokens) / Double(maxV), 0.6)
                    let h = v.tokens == 0 ? 2 : max(3, geo.size.height * CGFloat(frac))
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v.tokens == 0 ? Color.primary.opacity(0.08) : tint.opacity(0.85))
                            .frame(height: h)
                    }
                    .frame(width: barW)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .help(UsageHeatmap.tooltip(v.day, v.tokens, v.cost))
                }
            }
        }
    }
}

/// GitHub-style usage heatmap: weeks × 7 days, opacity by daily token volume.
struct UsageHeatmap: View {
    let points: [UsageDayPoint]
    var weeks: Int = 24
    var tint: Color = .blue

    private let cellHeight: CGFloat = 10
    private let cellSpacing: CGFloat = 2

    struct Cell: Identifiable {
        let id: Int
        let day: Date
        let tokens: Int
        let cost: Double
    }

    // Map day -> tokens/cost, then build a week-aligned grid ending today.
    nonisolated static func grid(points: [UsageDayPoint], weeks: Int, today: Date,
                                 calendar cal: Calendar) -> [[Cell?]] {
        var byDay: [Date: Int] = [:]
        var byDayCost: [Date: Double] = [:]
        for p in points {
            let key = cal.startOfDay(for: p.day)
            byDay[key, default: 0] += p.tokens
            byDayCost[key, default: 0] += p.costUSD
        }

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

    var body: some View {
        let cal = Calendar.current
        let cols = Self.grid(points: points, weeks: weeks,
                             today: cal.startOfDay(for: Date()), calendar: cal)
        // Scale to what is actually drawn. Points outside the grid — the ledger
        // reaches further back than `weeks` — must not dim every visible cell.
        let maxTokens = max(1, cols.lazy.joined().compactMap { $0?.tokens }.max() ?? 1)
        HStack(alignment: .top, spacing: cellSpacing) {
            ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                VStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { d in
                        cellView(col[d], maxTokens: maxTokens)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func cellView(_ cell: Cell?, maxTokens: Int) -> some View {
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
