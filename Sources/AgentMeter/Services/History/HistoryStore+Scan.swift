import Foundation

// The scan driver. Per file: register the path, compare watermarks, apply its
// observations. Pieces of files are packed into transactions of at most
// `scanChunkObservations` (1,000) observations: a backfill of 2,600 small
// transcripts in 2,600 transactions wrote twice the WAL frames and spent half
// its time in autocheckpoint fsyncs. A file's LAST piece and its watermark,
// events and session fold are always in one transaction, so rows never land
// without the watermark that says they are in, and a scan stopped between two
// transactions (a rebuild, a failure, `shutdown()`) leaves no watermark that
// claims more than was applied.
extension HistoryStore {
    /// One file's piece inside a pending transaction.
    private struct Piece {
        let plan: HistoryFilePlan
        /// The file's position in the scan: identifies it in `failed`.
        let file: Int
        let range: Range<Int>
        let isLast: Bool
    }

    /// The transaction being filled, and what the scan has done so far.
    private struct ScanRun {
        var pieces: [Piece] = []
        var weight = 0
        var paths: Set<String> = []
        /// Files with a piece in a transaction that rolled back: no watermark for them.
        var failed: Set<Int> = []
        var filesWritten = 0
    }

    func applyScanCommand(_ scan: HistoryScanBatch) async throws {
        try guarded { try prepareDatabase($0) }
        var run = ScanRun()
        let size = memory.scanChunkSize
        for (n, batch) in scan.files.enumerated() {
            // A path twice in one scan: its first batch must land before the
            // second one's watermark comparison reads it.
            if run.paths.contains(batch.path) { try await flush(&run) }
            let plan = try guarded { db in
                try db.planFile(batch, lastScan: memory.scanTickets[batch.path], deltasOnly: scan.isSessionRead)
            }
            counters.skippedInvalidObservations += plan.invalidObservations
            counters.skippedInvalidEvents += plan.invalidEvents
            guard plan.decision.applies else {
                counters.skippedFileBatches += 1
                if plan.decision == .skipEqual { noteScanTicket(plan) }
                continue
            }
            let ranges = plan.chunkRanges(size: size)
            for (i, range) in ranges.enumerated() {
                let weight = max(range.count, 1)
                if run.weight + weight > size && !run.pieces.isEmpty { try await flush(&run) }
                run.pieces.append(Piece(plan: plan, file: n, range: range, isLast: i == ranges.count - 1))
                run.weight += weight
                run.paths.insert(plan.path)
            }
        }
        try await flush(&run)
        let filesWritten = run.filesWritten
        let complete = scan.isCompleteHistory && run.failed.isEmpty
        try guarded { db in
            // A session read covers a few files, never the corpus up to a time.
            if !scan.isSessionRead {
                try db.recordScanCoverage(scan, filesWritten: filesWritten, complete: complete)
            }
            // After an ingest of some size only: a checkpoint fsyncs the file.
            // PASSIVE, never TRUNCATE: the integrity reader may be open.
            let changes = db.conn.totalChanges
            if changes - memory.changesAtCheckpoint >= Self.checkpointAfterChanges {
                _ = try? db.conn.checkpointPassive()
                memory.changesAtCheckpoint = changes
            }
        }
        await maintainIfDue()
    }

    /// Rows written since the last `wal_checkpoint(PASSIVE)` that trigger the next.
    static let checkpointAfterChanges: Int64 = 20_000

    /// Observations per scan transaction. The merge costs about 40 us per
    /// observation (five statements over random B-tree pages with a 2 MB page
    /// cache), not the 5 us per plain row behind `defaultChunkSize`: on the
    /// corpus-shaped backfill 2,000 held a queued call for ~85 ms (p90), 1,000
    /// for ~50 ms and 500 for ~30 ms, at 4.3 / 5.3 / 6.0 s of total time.
    /// Autocheckpoint fsync stalls come on top whatever the size.
    static let scanChunkObservations = 1_000

    /// Commits the pending pieces in ONE transaction (through `inChunks`, so
    /// its error policy applies), then yields so a queued call gets in.
    private func flush(_ run: inout ScanRun) async throws {
        guard !run.pieces.isEmpty else { return }
        let pieces = run.pieces
        let failed = run.failed
        run.pieces = []
        run.weight = 0
        run.paths = []
        let rebuildsBefore = counters.rebuilds
        let result = await inChunks([pieces], size: 1) { db, slice in
            for p in slice.first ?? [] {
                try db.applyFileChunk(p.plan, range: p.range, isLast: p.isLast, writeWatermark: !failed.contains(p.file))
            }
        }
        // Cancelled, unavailable or rebuilt underneath: stop (the rest re-arrives
        // with the next scan) and say why, so the drain counts a failed command.
        guard result.completed else {
            try Task.checkCancellation()
            if counters.rebuilds != rebuildsBefore { throw HistoryStoreError.rebuilt(quarantinedTo: nil) }
            _ = try openedDatabase()
            throw HistoryStoreError.closed
        }
        if result.failed > 0 { run.failed.formUnion(pieces.map(\.file)) }
        for p in pieces where p.isLast && !run.failed.contains(p.file) {
            noteScanTicket(p.plan)
            run.filesWritten += 1
        }
        await Task.yield()
    }

    private func noteScanTicket(_ plan: HistoryFilePlan) {
        memory.scanTickets[plan.path] = max(memory.scanTickets[plan.path] ?? 0, plan.scan)
    }
}
