import Foundation

struct LogFileFingerprint: Hashable, Sendable {
    let path: String
    let size: Int64
    let modifiedAt: TimeInterval

    static func current(for url: URL) -> LogFileFingerprint? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = values[.size] as? NSNumber,
              let modifiedAt = values[.modificationDate] as? Date else { return nil }
        return LogFileFingerprint(
            path: url.path,
            size: size.int64Value,
            modifiedAt: modifiedAt.timeIntervalSince1970
        )
    }
}

actor LogFileParseCache<Value: Sendable> {
    private struct Entry: Sendable {
        let fingerprint: LogFileFingerprint
        let value: Value
    }

    private var entries: [String: Entry] = [:]

    func value(for fingerprint: LogFileFingerprint) -> Value? {
        guard let entry = entries[fingerprint.path], entry.fingerprint == fingerprint else { return nil }
        return entry.value
    }

    func store(_ value: Value, for fingerprint: LogFileFingerprint) {
        entries[fingerprint.path] = Entry(fingerprint: fingerprint, value: value)
    }

    func prune(keeping fingerprints: [LogFileFingerprint]) {
        let livePaths = Set(fingerprints.map(\.path))
        entries = entries.filter { livePaths.contains($0.key) }
    }

    func clear() {
        entries.removeAll()
    }
}
