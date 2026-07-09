import Foundation

struct LogFileFingerprint: Hashable, Sendable {
    let path: String
    let size: Int64
    let modifiedAt: TimeInterval
    let fileID: UInt64?
    let volumeID: UInt64?

    init(
        path: String,
        size: Int64,
        modifiedAt: TimeInterval,
        fileID: UInt64? = nil,
        volumeID: UInt64? = nil
    ) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.fileID = fileID
        self.volumeID = volumeID
    }

    static func current(for url: URL) -> LogFileFingerprint? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = values[.size] as? NSNumber,
              let modifiedAt = values[.modificationDate] as? Date else { return nil }
        return LogFileFingerprint(
            path: url.path,
            size: size.int64Value,
            modifiedAt: modifiedAt.timeIntervalSince1970,
            fileID: (values[.systemFileNumber] as? NSNumber)?.uint64Value,
            volumeID: (values[.systemNumber] as? NSNumber)?.uint64Value
        )
    }

    func hasSameStableIdentity(as other: LogFileFingerprint) -> Bool {
        guard let fileID, let volumeID, let otherFileID = other.fileID, let otherVolumeID = other.volumeID else {
            return false
        }
        return fileID == otherFileID && volumeID == otherVolumeID
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
        guard let entry = entries[fingerprint.path],
              entry.fingerprint == fingerprint,
              entry.parsedBytes == fingerprint.size else { return nil }
        return entry.value
    }

    /// A prior parse of the same path to resume from, but only if it is still the
    /// same filesystem object and has grown past the last consumed line boundary.
    /// A same-path replacement, truncation, or rotation must re-parse from the top.
    /// Same-size / same-mtime exact hits are served by `value(for:)`; this is the
    /// append-only grew case.
    func incrementalBase(for fingerprint: LogFileFingerprint) -> (value: Value, parsedBytes: Int64)? {
        guard let entry = entries[fingerprint.path],
              entry.fingerprint.hasSameStableIdentity(as: fingerprint),
              entry.parsedBytes <= fingerprint.size,
              fingerprint.modifiedAt >= entry.fingerprint.modifiedAt else { return nil }
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
