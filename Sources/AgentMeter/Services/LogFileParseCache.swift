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
        /// Byte offset (a line boundary) up to which `value` accounts for the file.
        /// Lets a grown file resume parsing from here instead of from the top.
        let parsedBytes: Int64
    }

    private var entries: [String: Entry] = [:]

    func value(for fingerprint: LogFileFingerprint) -> Value? {
        guard let entry = entries[fingerprint.path], entry.fingerprint == fingerprint else { return nil }
        return entry.value
    }

    /// A prior parse of the same path to resume from, but only if the file hasn't
    /// shrunk below what we already consumed — a smaller file means truncation or
    /// rotation, so the caller must re-parse from the top instead. (Same-size /
    /// same-mtime exact hits are served by `value(for:)`; this is the grew case.)
    func incrementalBase(forPath path: String, notExceeding size: Int64) -> (value: Value, parsedBytes: Int64)? {
        guard let entry = entries[path], entry.parsedBytes <= size else { return nil }
        return (entry.value, entry.parsedBytes)
    }

    func store(_ value: Value, for fingerprint: LogFileFingerprint, parsedBytes: Int64) {
        entries[fingerprint.path] = Entry(fingerprint: fingerprint, value: value, parsedBytes: parsedBytes)
    }

    /// Non-incremental callers store the whole file; the fingerprint's size is the
    /// consumed offset.
    func store(_ value: Value, for fingerprint: LogFileFingerprint) {
        store(value, for: fingerprint, parsedBytes: fingerprint.size)
    }

    func prune(keeping fingerprints: [LogFileFingerprint]) {
        let livePaths = Set(fingerprints.map(\.path))
        entries = entries.filter { livePaths.contains($0.key) }
    }

    func clear() {
        entries.removeAll()
    }
}
