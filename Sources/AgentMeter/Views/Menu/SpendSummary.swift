import SwiftUI

/// Spend + tokens rolled up over a time window.
private struct WindowTotals {
    var cost: Double
    var tokens: Int
}

/// Shared window math so the headline row and the breakdown grid agree. Tokens
/// come off the day buckets; dollars are the report's per-model counts priced
/// under the table the caller hands over, never the buckets' scan-time
/// `costUSD`. That figure was priced under whatever table the scan happened to
/// hold, so it can disagree with the footer's all-time total, which is priced
/// under the view model's table like everything else on screen.
private enum SpendWindows {
    /// Tokens on the local day.
    static func todayTokens(_ usage: UsageReport) -> Int {
        let start = todayStart()
        return usage.buckets.first { $0.day == start }?.totalTokens ?? 0
    }

    /// Tokens over the rolling window of the last `days` day-buckets (incl. today).
    static func lastDaysTokens(_ days: Int, _ usage: UsageReport) -> Int {
        guard let cutoff = cutoff(days) else { return 0 }
        return usage.buckets.filter { $0.day >= cutoff }.reduce(0) { $0 + $1.totalTokens }
    }

    static func today(_ usage: UsageReport, table: PriceTable) -> WindowTotals {
        WindowTotals(cost: usage.costUSD(on: todayStart(), table: table),
                     tokens: todayTokens(usage))
    }

    /// Rolling window covering the last `days` day-buckets (incl. today). For
    /// `UsageReport.totalsWindowDays` the cutoff is the same day as
    /// `UsageReport.totalsCutoff()`, which the by-model rows use.
    static func lastDays(_ days: Int, _ usage: UsageReport, table: PriceTable) -> WindowTotals {
        guard let cutoff = cutoff(days) else { return WindowTotals(cost: 0, tokens: 0) }
        return WindowTotals(cost: usage.costUSD(from: cutoff, table: table),
                            tokens: lastDaysTokens(days, usage))
    }

    private static func todayStart() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    /// First day of the window, or nil for a window of no days.
    private static func cutoff(_ days: Int) -> Date? {
        guard days > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayStart())
    }
}

/// Collapsed headline: token usage for local day / 7-day / 30-day, as evenly-spread
/// right-aligned columns whose right edge lines up with the quota bars above.
/// The full $/token breakdown lives in SpendBreakdownGrid.
struct SpendSummary: View {
    let usage: UsageReport

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            cell("local day", TokenFormat.short(SpendWindows.todayTokens(usage)))
            cell("7-day", TokenFormat.short(SpendWindows.lastDaysTokens(7, usage)))
            cell("30-day", TokenFormat.short(SpendWindows.lastDaysTokens(UsageReport.totalsWindowDays, usage)))
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
    /// Prices the dollars at display time, so every figure on screen shares one table.
    let table: PriceTable

    private let labelWidth: CGFloat = 44
    private let columnSpacing: CGFloat = 6

    var body: some View {
        let cols: [(label: String, totals: WindowTotals)] = [
            ("local day", SpendWindows.today(usage, table: table)),
            ("7-day", SpendWindows.lastDays(7, usage, table: table)),
            ("30-day", SpendWindows.lastDays(UsageReport.totalsWindowDays, usage, table: table)),
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
    /// Prices the dollars at display time, so every figure on screen shares one table.
    let table: PriceTable
    var limit: Int = 4

    var body: some View {
        // The same cutoff as the grid's 30-day column, so these rows add up to
        // the figure right above them.
        let models = Array(usage.modelSpend(from: UsageReport.totalsCutoff(), table: table).prefix(limit))
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
