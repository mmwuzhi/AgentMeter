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

    /// Merge freshly-scanned day buckets into the ledger. Per provider-day the
    /// stored value only ever grows: a day shrinking in a fresh scan means its
    /// log files aged out or were pruned, not that the spend was refunded.
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
                if var stored = byKey[Key(fresh)] {
                    stored.costUSD = max(stored.costUSD, fresh.costUSD)
                    stored.tokens = max(stored.tokens, fresh.tokens)
                    byKey[Key(fresh)] = stored
                } else {
                    byKey[Key(fresh)] = fresh
                }
            }
        }
        return byKey.values.sorted {
            ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue)
        }
    }

    static func totalCostUSD(_ records: [LifetimeDayRecord], provider: Provider) -> Double {
        records.reduce(0) { $0 + ($1.provider == provider ? $1.costUSD : 0) }
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
