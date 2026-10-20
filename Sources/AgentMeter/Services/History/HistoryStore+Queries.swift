import Foundation

// Thin isolated wrappers of the read queries in `HistoryDatabase+Queries.swift`
// and `HistoryDatabase+Quota.swift`. Reads run between commands (or between
// two chunks of a scan), never inside a transaction of one. Each first runs
// `prepareDatabase`, like the write commands: a read right after a launch in
// another zone (or after the system zone changed) must not see the old zone's
// `acct_day` until some write happens to recompute it.
extension HistoryStore {
    /// The canonical logical content (the order-independence oracle: compare
    /// `sha256Hex`).
    func logicalDump() throws -> HistoryLogicalDump {
        try prepared { try $0.logicalDump() }
    }

    func dayModelUsage() throws -> [HistoryDayModelUsage] {
        try prepared { try $0.dayModelUsage() }
    }

    func sessionUsage(sessionID: String) throws -> HistorySessionUsage {
        try prepared { try $0.sessionUsage(sessionID: sessionID) }
    }

    /// The stored rows of one key, by its lowercase hex (`DedupKey.historyHex`).
    func requestRows(keyHex: String) throws -> [HistoryLogicalDump.Request] {
        guard let bytes = HistoryHex.decode(keyHex), bytes.count == 16 else { return [] }
        return try prepared { try $0.requestRows(keyBytes: bytes) }
    }

    /// Claude OAuth samples of one window only (`provider = 'claude' AND source = 'oauth'`).
    func oauthSamples(window: String, fromMs: Int64 = .min, toMs: Int64 = .max) throws -> [QuotaSampleRow] {
        try prepared { try $0.oauthSamples(window: window, fromMs: fromMs, toMs: toMs) }
    }

    /// Rows per table, `meta.quota_conflicts` and the process counters.
    func historyStatistics() throws -> HistoryContentStatistics {
        var stats = try prepared { try $0.contentStatistics() }
        stats.counters = counters
        return stats
    }

    private func prepared<T>(_ read: @Sendable (HistoryDatabase) throws -> T) throws -> T {
        try guarded { db in
            try prepareDatabase(db)
            return try read(db)
        }
    }
}
