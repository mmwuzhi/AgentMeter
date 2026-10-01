import Foundation

/// Rolls per-(day, model) token counts into a `UsageReport`. Shared by the
/// Claude and Codex scanners so both carry the same shape: the counts
/// themselves (`dayModels`, what the UI and the spend ledger price at display
/// time), plus day buckets and rolling-window totals priced under `table` now,
/// which older builds still read out of `last-state.json`.
enum UsageRollup {
    static func report(
        provider: Provider,
        entries: [DayModelUsage],
        table: PriceTable,
        now: Date = Date(),
        isCompleteHistory: Bool = false
    ) -> UsageReport {
        // totalCostUSD/totalTokens/byModel are surfaced as the "30-day" totals
        // (ModelBreakdown), so they use the same rolling cutoff as
        // SpendWindows.lastDays(UsageReport.totalsWindowDays) — not every day
        // the buffered file scan happened to pick up.
        let cutoff = UsageReport.totalsCutoff(now: now)

        var bucketByDay: [Date: UsageBucket] = [:]
        var modelTotals: [String: (tokens: Int, cost: Double)] = [:]
        var totalCost = 0.0
        for entry in entries {
            let cost = table.cost(model: entry.model, counts: entry.counts)
            var bucket = bucketByDay[entry.day] ?? UsageBucket(
                day: entry.day, inputTokens: 0, outputTokens: 0,
                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: 0)
            bucket.inputTokens += entry.counts.input
            bucket.outputTokens += entry.counts.output
            bucket.cacheWrite5m += entry.counts.cacheWrite5m
            bucket.cacheWrite1h += entry.counts.cacheWrite1h
            bucket.cacheRead += entry.counts.cacheRead
            bucket.costUSD += cost
            bucketByDay[entry.day] = bucket

            guard entry.day >= cutoff else { continue }
            totalCost += cost
            var totals = modelTotals[entry.model] ?? (0, 0)
            totals.tokens += entry.counts.total
            totals.cost += cost
            modelTotals[entry.model] = totals
        }

        let buckets = bucketByDay.values.sorted { $0.day < $1.day }
        let totalTokens = buckets
            .filter { $0.day >= cutoff }
            .reduce(0) { $0 + $1.totalTokens }
        let byModel = modelTotals
            .map { ModelSpend(model: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted { $0.costUSD > $1.costUSD }
        // Sorted so a report compares and encodes the same way on every scan.
        let dayModels = entries.sorted {
            $0.day != $1.day ? $0.day < $1.day : $0.model < $1.model
        }
        return UsageReport(provider: provider, buckets: buckets, totalCostUSD: totalCost,
                           totalTokens: totalTokens, byModel: byModel, dayModels: dayModels,
                           isCompleteHistory: isCompleteHistory)
    }
}
