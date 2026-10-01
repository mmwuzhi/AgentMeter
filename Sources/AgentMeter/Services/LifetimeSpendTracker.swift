import Foundation

/// One provider-day of observed usage, kept forever so the popover footer can
/// show an all-time total. Local scanners only see a recent log window, so older
/// history survives here, in the persisted ledger.
///
/// A day is stored as token counts per model and priced under the current
/// `PriceTable` whenever it is shown. `costUSD` is only what those counts came
/// to under the table at the last merge, written for older builds that read
/// this file. A record with no `models` — written before the ledger kept
/// counts, or the synthetic legacy floor — has nothing else to price, so it
/// keeps that figure until a complete scan replaces the day.
struct LifetimeDayRecord: Codable, Sendable, Equatable {
    let provider: Provider
    let day: Date
    var costUSD: Double
    var tokens: Int
    var models: [String: TokenCounts]? = nil

    init(provider: Provider, day: Date, costUSD: Double, tokens: Int, models: [String: TokenCounts]? = nil) {
        self.provider = provider
        self.day = day
        self.costUSD = costUSD
        self.tokens = tokens
        self.models = models
    }

    /// Dollars under `table`: the counts priced now, or the frozen figure.
    func costUSD(under table: PriceTable) -> Double {
        guard let models else { return costUSD }
        return table.cost(models)
    }
}

enum LifetimeSpendTracker {
    private static let legacyFloorDay = Date(timeIntervalSinceReferenceDate: 0)

    /// Merge freshly-scanned days into the ledger.
    ///
    /// A windowed scan (`isCompleteHistory == false`) can only grow a stored
    /// provider-day: a day shrinking there means its log files aged out of the
    /// window or were pruned, not that the spend was refunded. Tokens decide
    /// growth, because dollars are no longer a stored fact.
    ///
    /// A scan that read every log file is instead the complete picture for every
    /// day it observed, so those days are replaced — including downward. That is
    /// the only way an over-count can ever be corrected, and over-counts happen:
    /// resuming a session copies the earlier transcript into a new file, so the
    /// same assistant message is present in both. Days such a scan did *not*
    /// observe still keep their stored value, because their logs are gone and
    /// the ledger is the only thing that still remembers them.
    ///
    /// `costUSD` on every record that carries counts is rewritten under `table`,
    /// so what an older build reads from the file is what this one shows.
    static func merge(existing: [LifetimeDayRecord], reports: [UsageReport], table: PriceTable) -> [LifetimeDayRecord] {
        var byKey: [Key: LifetimeDayRecord] = [:]
        byKey.reserveCapacity(existing.count + reports.reduce(0) { $0 + $1.buckets.count })
        for record in existing {
            byKey[Key(record)] = record
        }
        for report in reports {
            for fresh in freshRecords(report, table: table) {
                guard let stored = byKey[Key(fresh)] else {
                    byKey[Key(fresh)] = fresh
                    continue
                }
                if report.isCompleteHistory || fresh.tokens >= stored.tokens {
                    byKey[Key(fresh)] = fresh
                }
            }
        }
        return byKey.values
            .map { record in
                var record = record
                if let models = record.models {
                    record.costUSD = table.cost(models)
                }
                return record
            }
            .sorted { ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue) }
    }

    /// One record per day of the report: from its per-model counts, or, for a
    /// report an older build cached without them, from the day buckets.
    private static func freshRecords(_ report: UsageReport, table: PriceTable) -> [LifetimeDayRecord] {
        if report.dayModels.isEmpty {
            return report.buckets.map { bucket in
                LifetimeDayRecord(provider: report.provider, day: bucket.day,
                                  costUSD: bucket.costUSD, tokens: bucket.totalTokens)
            }
        }
        var byDay: [Date: [String: TokenCounts]] = [:]
        for entry in report.dayModels {
            byDay[entry.day, default: [:]][entry.model, default: TokenCounts()].add(entry.counts)
        }
        return byDay.map { day, models in
            LifetimeDayRecord(provider: report.provider, day: day,
                              costUSD: table.cost(models),
                              tokens: models.values.reduce(0) { $0 + $1.total },
                              models: models)
        }
    }

    static func totalCostUSD(_ records: [LifetimeDayRecord], provider: Provider, table: PriceTable) -> Double {
        records.reduce(0) { $0 + ($1.provider == provider ? $1.costUSD(under: table) : 0) }
    }

    /// Activity points for one provider's heatmap and sparkline, priced under
    /// `table` like every other figure on screen.
    ///
    /// The ledger decides every day it holds: `RefreshCoordinator` merges the
    /// report into it before the UI reads either, so the ledger is already at
    /// least as complete — and letting the report override would resurrect an
    /// over-count that a complete scan had just corrected, whenever the report
    /// still on screen is the one restored from `last-state.json`. The report
    /// only fills days the ledger has never heard of, which is what a lost or
    /// unreadable `lifetime-spend.json` looks like.
    ///
    /// The synthetic `legacyFloorDay` bootstrap record is dropped: it is an
    /// aggregate with no real date, so plotting it would both invent activity on
    /// 2001-01-01 and blow up the color scale.
    static func dayPoints(ledger: [LifetimeDayRecord], report: UsageReport, table: PriceTable) -> [UsageDayPoint] {
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        if report.dayModels.isEmpty {
            // A report restored from an older build's cache: scan-time dollars
            // are all it has, until the first refresh replaces it.
            for bucket in report.buckets {
                byDay[bucket.day] = (bucket.totalTokens, bucket.costUSD)
            }
        } else {
            for entry in report.dayModels {
                let sum = byDay[entry.day] ?? (0, 0)
                byDay[entry.day] = (sum.tokens + entry.counts.total,
                                    sum.cost + table.cost(model: entry.model, counts: entry.counts))
            }
        }
        for record in ledger
        where record.provider == report.provider && record.day != legacyFloorDay {
            byDay[record.day] = (record.tokens, record.costUSD(under: table))
        }
        return byDay
            .map { UsageDayPoint(day: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted { $0.day < $1.day }
    }

    /// Bootstraps the ledger from pre-ledger snapshots. Some older builds
    /// surfaced broader totals than the current bucket scan can reconstruct;
    /// preserve that aggregate as a synthetic floor so upgrading cannot lower
    /// the visible all-time spend.
    static func bootstrapFromLegacyReports(_ reports: [UsageReport], table: PriceTable) -> [LifetimeDayRecord] {
        var records = merge(existing: [], reports: reports, table: table)
        for report in reports {
            let storedCost = totalCostUSD(records, provider: report.provider, table: table)
            guard report.totalCostUSD > storedCost else { continue }
            let storedTokens = records.reduce(0) { $0 + ($1.provider == report.provider ? $1.tokens : 0) }
            records.append(
                LifetimeDayRecord(
                    provider: report.provider,
                    day: legacyFloorDay,
                    costUSD: report.totalCostUSD - storedCost,
                    tokens: max(0, report.totalTokens - storedTokens)
                )
            )
        }
        return records.sorted {
            ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue)
        }
    }

    private struct Key: Hashable {
        let provider: Provider
        let day: Date

        init(_ record: LifetimeDayRecord) {
            provider = record.provider
            day = record.day
        }
    }
}
