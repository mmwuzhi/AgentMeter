import Foundation

// One file batch of a scan: what is stored about the path, whether the batch
// applies (the watermark rules), and the writes of one chunk of it. The actor
// side (`HistoryStore+Apply.swift`) drives the chunks.

/// What the history holds about a path.
struct HistoryStoredFile: Sendable {
    let fileRef: Int64
    /// nil when the path was registered but no batch of it completed yet.
    let watermark: HistoryFileWatermark?
}

enum HistoryFileDecision: String, Sendable, Equatable {
    /// The stored watermark is the batch's: its rows are already in.
    case skipEqual
    /// A newer scan of the path was already applied in this process (the
    /// per-path ticket kept in memory). The only defence against a stale batch:
    /// tickets reset on every open, so after a restart any batch is accepted.
    case skipOlderScan
    /// A session read's file whose delta is not based on the stored
    /// watermark, or that has none (`HistoryScanBatch.isSessionRead`): left
    /// to the next scan, whose ticket stays good.
    case skipNoDeltaBase
    /// The batch's delta is based on exactly the stored watermark.
    case delta
    /// Everything the batch's committed state holds.
    case whole

    var applies: Bool { self == .delta || self == .whole }
}

/// Everything decided about one file batch before any write.
struct HistoryFilePlan: Sendable {
    let path: String
    let scan: UInt64
    let decision: HistoryFileDecision
    /// Class/session/agent/run from the path; birth stat'd only for a new path.
    let source: HistorySourceFile
    /// Validated observations (empty for a skip).
    let observations: [RequestObservation]
    let invalidObservations: Int
    let events: HistoryFileEvents
    let invalidEvents: Int
    let watermark: HistoryFileWatermark
    let ingestVersion: Int64

    /// Chunk ranges over `observations`; one empty range when there is none,
    /// so registration, events and the watermark still get their transaction.
    func chunkRanges(size: Int) -> [Range<Int>] {
        guard !observations.isEmpty else { return [0..<0] }
        return stride(from: 0, to: observations.count, by: size).map { $0..<min($0 + size, observations.count) }
    }
}

extension HistoryDatabase {
    func storedFile(path: String) throws -> HistoryStoredFile? {
        try conn.withStatement("""
            SELECT file_ref, file_id, volume_id, size, mtime, parsed_bytes, boundary_digest, parser_version
            FROM source_file WHERE path = ?1
            """) { s -> HistoryStoredFile? in
            s.bind(1, path)
            guard try s.step() else { return nil }
            var wm: HistoryFileWatermark?
            if !s.isNull(5) {
                wm = HistoryFileWatermark(
                    fileID: s.isNull(1) ? nil : s.uint64(1), volumeID: s.isNull(2) ? nil : s.uint64(2),
                    size: s.int64(3), modifiedAt: s.double(4), parsedBytes: s.int64(5),
                    boundaryDigest: Data(s.blob(6) ?? []), parserVersion: Int(s.int64(7)))
            }
            return HistoryStoredFile(fileRef: s.int64(0), watermark: wm)
        }
    }

    /// The watermark rules: an older scan ticket for the path -> skip; equal
    /// watermark -> skip; a delta whose base IS the stored watermark (file id,
    /// parsed bytes, boundary digest, parser version) -> the delta; anything
    /// else -> every request of the batch, and the watermark moves to the
    /// batch's, also to FEWER parsed bytes: a transcript truncated and rewritten
    /// under the same inode is parsed from the top and must be ingested (union
    /// semantics keep what the earlier content contributed). There is no
    /// "fewer bytes than stored" skip: it stalled such a file until it grew past
    /// the old size.
    /// `deltasOnly`: the batch is a session read's (`HistoryScanBatch.isSessionRead`).
    func planFile(_ batch: HistoryFileBatch, lastScan: UInt64?, deltasOnly: Bool = false) throws -> HistoryFilePlan {
        let stored = try storedFile(path: batch.path)
        func skip(_ d: HistoryFileDecision) -> HistoryFilePlan {
            HistoryFilePlan(path: batch.path, scan: batch.scan, decision: d,
                            source: HistorySourceFile.parse(path: batch.path), observations: [],
                            invalidObservations: 0, events: .empty, invalidEvents: 0,
                            watermark: batch.watermark, ingestVersion: Int64(batch.watermark.parserVersion))
        }
        if let lastScan, batch.scan < lastScan { return skip(.skipOlderScan) }
        if let wm = stored?.watermark, wm == batch.watermark { return skip(.skipEqual) }
        let decision: HistoryFileDecision
        let raw: [RequestObservation]
        if let delta = batch.delta, let wm = stored?.watermark, wm.fileID == delta.basedOnFileID,
           wm.parsedBytes == delta.basedOnParsedBytes, wm.boundaryDigest == delta.basedOnBoundaryDigest,
           wm.parserVersion == delta.basedOnParserVersion {
            decision = .delta
            raw = delta.requests
        } else if deltasOnly {
            return skip(.skipNoDeltaBase)
        } else {
            decision = .whole
            raw = batch.allRequests()
        }
        let valid = raw.compactMap(HistoryObservationCheck.normalized)
        let (events, invalidEvents) = HistoryEventCheck.validated(batch.events)
        // Birth is read once, for a path the store has never registered.
        let birth = stored == nil ? config.birthTime(batch.path) : nil
        return HistoryFilePlan(path: batch.path, scan: batch.scan, decision: decision,
                               source: HistorySourceFile.parse(path: batch.path, birthMs: birth),
                               observations: valid, invalidObservations: raw.count - valid.count,
                               events: events, invalidEvents: invalidEvents, watermark: batch.watermark,
                               ingestVersion: Int64(batch.watermark.parserVersion))
    }

    /// One chunk of a file, inside the chunk's transaction. The last chunk also
    /// writes the file's events, its session fold and (unless an earlier chunk
    /// of the file failed) its watermark, so rows never land without one.
    func applyFileChunk(_ plan: HistoryFilePlan, range: Range<Int>, isLast: Bool, writeWatermark: Bool) throws {
        var ctx = makeIngestContext()
        let file = try registerFile(plan.source)
        for o in plan.observations[range] {
            try applyObservation(o, file: file, ingestVersion: plan.ingestVersion, &ctx)
        }
        guard isLast else { return }
        try applyEvents(plan.events, file: file, &ctx)
        if writeWatermark { try self.writeWatermark(fileRef: file.fileRef, plan.watermark) }
    }

    func writeWatermark(fileRef: Int64, _ wm: HistoryFileWatermark) throws {
        try conn.withStatement("""
            UPDATE source_file SET file_id = ?2, volume_id = ?3, size = ?4, mtime = ?5, parsed_bytes = ?6,
                boundary_digest = ?7, parser_version = ?8, ingested_ms = ?9
            WHERE file_ref = ?1
            """) { s in
            s.bind(1, fileRef)
            if let id = wm.fileID { s.bind(2, id) } else { s.bindNull(2) }
            if let v = wm.volumeID { s.bind(3, v) } else { s.bindNull(3) }
            s.bind(4, wm.size)
            s.bind(5, wm.modifiedAt)
            s.bind(6, wm.parsedBytes)
            s.bind(7, blob: wm.boundaryDigest)
            s.bind(8, Int64(wm.parserVersion))
            s.bind(9, HistoryTime.ms(config.clock()))
            try s.step()
        }
    }

    /// How far `meta.latest_scan_ms` may lag the newest scan that wrote no
    /// file: an unchanged windowed scan writes nothing at all unless the
    /// stored value is at least this old. Well above the app's refresh
    /// cadence (a scan every 60 s while nothing happens, whose starts land
    /// 60.000 s apart or a few ms more), so an idle night costs four small
    /// commits an hour, not one a minute. Nothing reads the value yet; a
    /// scan that writes a file, and every complete scan, still advances it.
    static let latestScanGranularityMs: Int64 = 15 * 60_000

    /// Records the scan's coverage; returns whether it wrote anything. Runs
    /// its own `BEGIN IMMEDIATE` transaction, and none when there is nothing
    /// to write.
    ///
    ///  * A scan that wrote a file, or a complete-history scan: an
    ///    `ingest_scan` row, `meta.latest_scan_ms`, and — when `complete`
    ///    (a complete-history scan none of whose files failed: each was
    ///    applied, or skipped because its watermark was already stored or a
    ///    newer scan of the path already applied) — `meta.complete_scan_ms`.
    ///    Both advance only, never move back (scans overlap and may land out
    ///    of order).
    ///  * A windowed scan that wrote no file: no row (an unchanged file means
    ///    zero writes); `meta.latest_scan_ms` only when the stored value is
    ///    `latestScanGranularityMs` or more older than this scan.
    @discardableResult
    func recordScanCoverage(_ scan: HistoryScanBatch, filesWritten: Int, complete: Bool) throws -> Bool {
        guard filesWritten > 0 || scan.isCompleteHistory else {
            if let latest = try metaInt("latest_scan_ms"), scan.startedMs - latest < Self.latestScanGranularityMs {
                return false
            }
            try conn.transaction(.immediate) { try advanceMeta("latest_scan_ms", to: scan.startedMs) }
            return true
        }
        try conn.transaction(.immediate) {
            try conn.withStatement("""
                INSERT INTO ingest_scan(started_ms, landed_ms, complete, files, files_written)
                VALUES (?1, ?2, ?3, ?4, ?5)
                """) { s in
                s.bind(1, scan.startedMs)
                s.bind(2, HistoryTime.ms(config.clock()))
                s.bind(3, Int64(complete ? 1 : 0))
                s.bind(4, Int64(scan.files.count))
                s.bind(5, Int64(filesWritten))
                try s.step()
            }
            try advanceMeta("latest_scan_ms", to: scan.startedMs)
            if complete { try advanceMeta("complete_scan_ms", to: scan.startedMs) }
        }
        return true
    }
}
