import SwiftUI

/// Spend + tokens rolled up over a time window.
private struct WindowTotals {
    var cost: Double
    var tokens: Int
}

/// Shared window math so the headline row and the breakdown grid agree.
private enum SpendWindows {
    static func today(_ usage: UsageReport) -> WindowTotals {
        let start = Calendar.current.startOfDay(for: Date())
        let bucket = usage.buckets.first { $0.day == start }
        return WindowTotals(cost: bucket?.costUSD ?? 0, tokens: bucket?.totalTokens ?? 0)
    }

    /// Rolling window covering the last `days` day-buckets (incl. today).
    static func lastDays(_ days: Int, _ usage: UsageReport) -> WindowTotals {
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date())) else {
            return WindowTotals(cost: 0, tokens: 0)
        }
        let recent = usage.buckets.filter { $0.day >= cutoff }
        return WindowTotals(cost: recent.reduce(0) { $0 + $1.costUSD },
                            tokens: recent.reduce(0) { $0 + $1.totalTokens })
    }

    static func tracked(_ usage: UsageReport) -> WindowTotals {
        WindowTotals(cost: usage.totalCostUSD, tokens: usage.totalTokens)
    }
}

/// Collapsed headline: token usage for local day / 7-day / 30-day, as evenly-spread
/// right-aligned columns whose right edge lines up with the quota bars above.
/// The full $/token breakdown lives in SpendBreakdownGrid.
struct SpendSummary: View {
    let usage: UsageReport

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            cell("local day", TokenFormat.short(SpendWindows.today(usage).tokens))
            cell("7-day", TokenFormat.short(SpendWindows.lastDays(7, usage).tokens))
            cell("30-day", TokenFormat.short(SpendWindows.lastDays(30, usage).tokens))
        }
        .help("Usage is read from recent local logs and the day resets at local midnight.")
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Expanded breakdown: $/token across local day / 7-day / 30-day. Equal-width
/// right-aligned columns spanning the full width, so numbers share one right edge.
struct SpendBreakdownGrid: View {
    let usage: UsageReport

    private let labelWidth: CGFloat = 44
    private let columnSpacing: CGFloat = 6

    var body: some View {
        let cols: [(label: String, totals: WindowTotals)] = [
            ("local day", SpendWindows.today(usage)),
            ("7-day", SpendWindows.lastDays(7, usage)),
            ("30-day", SpendWindows.lastDays(30, usage)),
        ]

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: columnSpacing) {
                Color.clear.frame(width: labelWidth, height: 0)
                ForEach(cols, id: \.label) { col in
                    Text(col.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            dataRow("Spend", cols.map { String(format: "$%.2f", $0.totals.cost) })
            dataRow("Tokens", cols.map { TokenFormat.short($0.totals.tokens) })
        }
    }

    private func dataRow(_ label: String, _ values: [String]) -> some View {
        HStack(spacing: columnSpacing) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// Recent spend split by model (top few). Shown in the expanded activity area so
/// you can see which model is actually driving cost.
struct ModelBreakdown: View {
    let usage: UsageReport
    var limit: Int = 4

    var body: some View {
        let models = Array(usage.byModel.prefix(limit))
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("By model · 30-day")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(models) { m in
                    HStack(spacing: 6) {
                        Text(Self.pretty(m.model))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(TokenFormat.short(m.tokens))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(String(format: "$%.2f", m.costUSD))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Trim vendor prefixes and a trailing -YYYYMMDD date so names stay readable.
    static func pretty(_ model: String) -> String {
        var s = model
        for p in ["claude-", "anthropic/", "openai/"] where s.hasPrefix(p) {
            s.removeFirst(p.count)
        }
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.isEmpty ? model : s
    }
}
