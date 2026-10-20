import Foundation

/// What the store keeps in memory next to the database, owned by the actor.
/// None of it is persisted: scan tickets are per-process counters, and the
/// quota thinning state is re-seeded from the newest stored rows.
///
/// Tied to one connection generation: an open, a reopen after `close()` or a
/// corruption rebuild starts from a fresh memory (`HistoryStore.syncMemory`),
/// because the rows it describes may be gone.
struct HistoryStoreMemory: Sendable {
    struct Generation: Equatable, Sendable {
        let opens: Int
        let rebuilds: Int
    }

    var generation: Generation?
    /// The newest scan ticket applied (or found already applied) per path.
    var scanTickets: [String: UInt64] = [:]
    var thinning = QuotaThinningState()
    /// Meta seeded and the accounting zone checked for this generation.
    var metaReady = false
    /// The integrity check owed after an unclean shutdown ran for this open.
    var uncleanCheckDone = false
    /// Observations per transaction of a scan (a test knob; survives a reset).
    var scanChunkSize = HistoryStore.scanChunkObservations
    /// `totalChanges` of the connection at the last passive checkpoint.
    var changesAtCheckpoint: Int64 = 0
}

/// The arrival-stream thinning of `quota_sample`, per (provider, window, source).
struct QuotaThinningState: Sendable {
    struct Key: Hashable, Sendable {
        let provider: Provider
        let windowID: String
        let source: QuotaSampleSource
    }

    struct Group: Sendable {
        /// The newest (by reading time) row stored for the group; nil when none is.
        var lastStored: QuotaSampleRow?
        /// The most recent reading skipped since `lastStored`.
        var skipped: QuotaSampleRow?
    }

    var groups: [Key: Group] = [:]
}

extension HistoryStore {
    /// Resets the memory when the connection it describes is not the current
    /// one any more. Call after the database is open.
    func syncMemory() {
        let current = HistoryStoreMemory.Generation(opens: counters.openAttempts, rebuilds: counters.rebuilds)
        guard memory.generation != current else { return }
        let chunk = memory.scanChunkSize
        memory = HistoryStoreMemory()
        memory.scanChunkSize = chunk
        memory.generation = current
    }

    /// Test knob: observations per scan transaction.
    func setScanChunkSize(_ size: Int) {
        precondition(size > 0)
        memory.scanChunkSize = size
    }

    /// Forgets tickets and thinning state, as a new process would.
    func resetIngestMemory() {
        memory.generation = nil
        syncMemory()
    }
}
