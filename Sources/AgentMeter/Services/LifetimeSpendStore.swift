import Foundation

/// Persists the long-lived spend ledger separately from `last-state.json`.
/// Older AgentMeter builds rewrite the state snapshot without unknown fields,
/// so keeping the ledger only there makes downgrades erase all-time spend.
enum LifetimeSpendStore {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AgentMeter", isDirectory: true)
    }

    private static var fileURL: URL {
        dir.appendingPathComponent("lifetime-spend.json")
    }

    static func load() -> [LifetimeDayRecord]? {
        load(from: fileURL)
    }

    static func save(_ records: [LifetimeDayRecord]) {
        save(records, to: fileURL)
    }

    static func load(from url: URL) -> [LifetimeDayRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LifetimeDayRecord].self, from: data)
    }

    static func save(_ records: [LifetimeDayRecord], to url: URL) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
