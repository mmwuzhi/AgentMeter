import Foundation

/// How long the rolling raw samples are kept. Request and event rows are
/// never auto-deleted: they are the point of a persistent store.
struct HistoryRetention: Sendable, Equatable {
    /// `quota_sample` and `reset_event` rows older than this are pruned by
    /// maintenance (at most once a day), and so are the `ingest_scan` rows of
    /// complete-history scans. nil keeps them forever.
    var quotaSampleDays: Int? = 400
    /// `ingest_scan` rows of windowed scans (`complete = 0`) older than this
    /// are pruned by maintenance: only the recent ones say anything the
    /// complete scans' rows do not. nil keeps them forever.
    var windowedScanDays: Int? = 14

    init(quotaSampleDays: Int? = 400, windowedScanDays: Int? = 14) {
        self.quotaSampleDays = quotaSampleDays
        self.windowedScanDays = windowedScanDays
    }
}

/// What the history can say about itself right now.
enum HistoryStatus: Sendable, Equatable {
    /// Open, migrated, writable.
    case ready
    /// The file was found damaged (or foreign) and replaced by an empty
    /// database; the old one is at `quarantinedTo`. Requests refill from the
    /// usage cache on the next scan, but quota and event samples older than
    /// that, and rows of transcripts Claude Code has since deleted, are lost.
    /// Stays set for the life of the process.
    case rebuilt(quarantinedTo: String)
    /// Running without history: a newer schema, an unrecoverable file, another
    /// instance holding the lock, a lock or directory that cannot be had, a
    /// file this process may not write, an old SQLite, or closed at quit.
    /// Submissions are dropped and counted. Everything outside the history
    /// keeps working.
    case unavailable(reason: String)
}

/// The exact counts behind the store's rate-limited log lines
/// (`HistoryStore+Log.swift`): tests and a future diagnostics view read them.
struct HistoryStoreStatistics: Sendable, Equatable {
    /// Commands that ran to the end.
    var appliedCommands = 0
    /// Commands the inbox dropped because the store was unavailable, and the
    /// queued scans and custom commands `shutdown()` dropped.
    var droppedSubmissions = 0
    /// Commands that threw (a rebuild in flight, a SQLite error in a hook).
    var failedCommands = 0
    /// Chunks that rolled back on a per-chunk error while the run went on.
    var failedChunks = 0
    var committedChunks = 0
    /// Corruption recoveries done while the store was running (an open-time
    /// quarantine is not counted: it shows in `HistoryStatus.rebuilt`).
    var rebuilds = 0
    var openAttempts = 0
    /// Request observations rejected by validation before a transaction
    /// (no part, a negative or absurd count, an unusable timestamp).
    var skippedInvalidObservations = 0
    /// Event observations (429s, /usage reports, cost states, compactions)
    /// rejected by validation, and quota rows with a non-finite value.
    var skippedInvalidEvents = 0
    /// File batches not applied: equal watermark, or an older scan of the path.
    var skippedFileBatches = 0
    /// Integrity checks run by maintenance, and the ones that failed (each
    /// failure quarantines and rebuilds the database).
    var integrityChecks = 0
    var failedIntegrityChecks = 0
}

/// What one `inChunks` run did.
struct HistoryChunkRun: Sendable, Equatable {
    var committed = 0
    var failed = 0
    /// False when the run stopped early: cancelled, the store became
    /// unavailable, or the database was rebuilt underneath it.
    var completed = true
}
