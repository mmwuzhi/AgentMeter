import Foundation

// What a usage scan hands the history for one transcript, built from the
// values the scan holds anyway: no extra I/O, no copy of the parsed records
// (the batch shares `ClaudeFileUsage`'s buffers with the parse cache), and
// the observations themselves are only materialised when the store asks.

extension ClaudeJSONLScanner.FileScan {
    /// The file's committed state as of this scan, or nil when the read failed
    /// (an empty or stale state must never regress what the history holds).
    /// A resumed parse also carries the records that changed since its base,
    /// which the store applies only when the base is what it already holds.
    func historyBatch(scan ticket: UInt64) -> HistoryFileBatch? {
        guard origin != .readFailed else { return nil }
        // Captured as a value, never `self`: the closure outlives the scan.
        let usage = self.usage
        let parserVersion = Int(ClaudeUsageCacheStore.formatVersion)
        let watermark = HistoryFileWatermark(
            fileID: fingerprint.fileID, volumeID: fingerprint.volumeID,
            size: fingerprint.size, modifiedAt: fingerprint.modifiedAt,
            parsedBytes: parsedBytes, boundaryDigest: usage.boundaryDigest,
            parserVersion: parserVersion)
        let delta = resume.map { base in
            HistoryFileBatch.Delta(
                basedOnParsedBytes: base.parsedBytes,
                // A resume requires the same filesystem object, so the base's
                // identity is the fingerprint's.
                basedOnFileID: fingerprint.fileID,
                basedOnBoundaryDigest: base.boundaryDigest,
                basedOnParserVersion: parserVersion,
                requests: base.changed.map { usage.observation(at: $0) })
        }
        return HistoryFileBatch(
            path: fingerprint.path, scan: ticket, watermark: watermark, delta: delta,
            allRequests: { usage.allObservations() }, events: usage.extras)
    }
}

extension ClaudeFileUsage {
    /// What this file says about the request at `keyed[index]`: the standing
    /// record's parts, finality, attributes and thinking, plus the times and
    /// flags folded over every record of the key in the file.
    func observation(at index: Int) -> RequestObservation {
        let record = keyed[index]
        let stamp = record.stamp
        var parts: [RequestPart] = []
        parts.reserveCapacity(record.earlierIterations.count + 1)
        record.forEachPart { parts.append(RequestPart(model: $0.model, counts: $0.counts)) }
        let attributes = stamp.attributes == 0 ? RecordAttributes() : attributeSets[Int(stamp.attributes) - 1]
        return RequestObservation(
            key: record.key, parts: parts, finality: record.finality,
            firstMs: stamp.first, lastMs: stamp.lastMs, finalMs: stamp.finalMs,
            thinkingTokens: stamp.thinking == RecordStamp.noThinking ? nil : Int(stamp.thinking),
            ccVersion: attributes.version, effort: attributes.effort, entrypoint: attributes.entrypoint,
            flags: stamp.flags)
    }

    /// Every keyed request of the file, in file order. Records without a
    /// message id cannot be keyed and are not part of the history.
    func allObservations() -> [RequestObservation] {
        keyed.indices.map { observation(at: $0) }
    }
}
