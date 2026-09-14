import Foundation

/// One provider-day of observed spend, kept forever so the popover footer can
/// show an all-time total. Local scanners only see a recent log window, so older
/// history survives here, in the persisted ledger.
struct LifetimeDayRecord: Codable, Sendable, Equatable {
    let provider: Provider
    let day: Date
    var costUSD: Double
    var tokens: Int
}

enum LifetimeSpendTracker {
    private static let legacyFloorDay = Date(timeIntervalSinceReferenceDate: 0)

    /// Merge freshly-scanned day buckets into the ledger.
    ///
    /// A windowed scan (`isCompleteHistory == false`) can only grow a stored
    /// provider-day: a day shrinking there means its log files aged out of the
    /// window or were pruned, not that the spend was refunded.
    ///
    /// A scan that read every log file is instead the complete picture for every
    /// day it observed, so those days are replaced — including downward. That is
    /// the only way an over-count can ever be corrected, and over-counts happen:
    /// resuming a session copies the earlier transcript into a new file, so the
    /// same assistant message is present in both. Days such a scan did *not*
    /// observe still keep their stored value, because their logs are gone and
    /// the ledger is the only thing that still remembers them.
    static func merge(existing: [LifetimeDayRecord], reports: [UsageReport]) -> [LifetimeDayRecord] {
        var byKey: [Key: LifetimeDayRecord] = [:]
        byKey.reserveCapacity(existing.count + reports.reduce(0) { $0 + $1.buckets.count })
        for record in existing {
            byKey[Key(record)] = record
        }
        for report in reports {
            for bucket in report.buckets {
                let fresh = LifetimeDayRecord(
                    provider: report.provider,
                    day: bucket.day,
                    costUSD: bucket.costUSD,
                    tokens: bucket.totalTokens
                )
                guard var stored = byKey[Key(fresh)] else {
                    byKey[Key(fresh)] = fresh
                    continue
                }
                if report.isCompleteHistory {
                    stored.costUSD = fresh.costUSD
                    stored.tokens = fresh.tokens
                } else {
                    stored.costUSD = max(stored.costUSD, fresh.costUSD)
                    stored.tokens = max(stored.tokens, fresh.tokens)
                }
                byKey[Key(fresh)] = stored
            }
        }
        return byKey.values.sorted {
            ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue)
        }
    }

    static func totalCostUSD(_ records: [LifetimeDayRecord], provider: Provider) -> Double {
        records.reduce(0) { $0 + ($1.provider == provider ? $1.costUSD : 0) }
    }

    /// Activity points for one provider's heatmap and sparkline.
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
    static func dayPoints(ledger: [LifetimeDayRecord], report: UsageReport) -> [UsageDayPoint] {
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        for bucket in report.buckets {
            byDay[bucket.day] = (bucket.totalTokens, bucket.costUSD)
        }
        for record in ledger
        where record.provider == report.provider && record.day != legacyFloorDay {
            byDay[record.day] = (record.tokens, record.costUSD)
        }
        return byDay
            .map { UsageDayPoint(day: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted { $0.day < $1.day }
    }

    /// Bootstraps the ledger from pre-ledger snapshots. Some older builds
    /// surfaced broader totals than the current bucket scan can reconstruct;
    /// preserve that aggregate as a synthetic floor so upgrading cannot lower
    /// the visible all-time spend.
    static func bootstrapFromLegacyReports(_ reports: [UsageReport]) -> [LifetimeDayRecord] {
        var records = merge(existing: [], reports: reports)
        for report in reports {
            let storedCost = totalCostUSD(records, provider: report.provider)
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
