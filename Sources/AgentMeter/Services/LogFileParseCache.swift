import Foundation
import os

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

/// The process-wide scan ticket sequence behind `LogFileParseCache.beginScan`.
private let logFileScanTickets = OSAllocatedUnfairLock(initialState: UInt64(0))

actor LogFileParseCache<Value: Sendable> {
    private struct Entry: Sendable {
        let fingerprint: LogFileFingerprint
        let value: Value
        /// Byte offset (a line boundary) up to which `value` accounts for the file.
        /// Lets a grown file resume parsing from here instead of from the top.
        let parsedBytes: Int64
        /// The scan that stored it (`beginScan`); 0 for callers that do not
        /// order their scans.
        let scan: UInt64
    }

    private var entries: [String: Entry] = [:]

    /// A ticket for one scan, handed to `store`: a scan that started later
    /// fingerprinted every file later, so what it stores is at least as new,
    /// and an earlier scan that finishes after it must not put its older view
    /// back. Scans that overlap are real — a refresh stalled past 30 s lets
    /// another start beside it.
    ///
    /// Drawn from ONE process-wide sequence, not per cache: the history store
    /// drops a file batch whose ticket is older than one it already applied
    /// for the path, so tickets of two caches feeding it (a cache recreated
    /// over the same directory) must never restart at 1 below it.
    func beginScan() -> UInt64 {
        logFileScanTickets.withLock { ticket in
            ticket += 1
            return ticket
        }
    }

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
              Self.canResume(from: entry.fingerprint, parsedBytes: entry.parsedBytes, to: fingerprint) else {
            return nil
        }
        return (entry.value, entry.parsedBytes)
    }

    /// Whether a read of the file `previous` described, which stopped at the
    /// line boundary `parsedBytes`, can go on from there on the file `current`
    /// describes: the same filesystem object, not dated earlier, and longer
    /// than what was parsed. The same length under a newer modification date
    /// is a rewrite, not an append, and reads from the top.
    static func canResume(from previous: LogFileFingerprint, parsedBytes: Int64, to current: LogFileFingerprint) -> Bool {
        previous.hasSameStableIdentity(as: current)
            && parsedBytes < current.size
            && current.modifiedAt >= previous.modifiedAt
    }

    func store(_ value: Value, for fingerprint: LogFileFingerprint, parsedBytes: Int64, scan: UInt64 = 0) {
        if let existing = entries[fingerprint.path], existing.scan > scan { return }
        entries[fingerprint.path] = Entry(fingerprint: fingerprint, value: value, parsedBytes: parsedBytes, scan: scan)
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
