import Dispatch
import Foundation
import os

/// The only owner of the history database. Everything that touches SQLite runs
/// on a private serial queue used as this actor's executor, so it
///  * never runs on the MainActor,
///  * never occupies a thread of the Swift cooperative pool while blocked in
///    an fsync (a pool thread stuck for 1-2 s is a thread the rest of the app's
///    async code cannot use),
///  * lets `Task.yield()` between chunks admit queued callers FIFO.
///
/// How to use it:
///  * Producers (the scan, the quota refresh) call the four non-isolated
///    `submit` methods of `HistoryIngesting`. They append to a lock-protected
///    FIFO inbox in well under a microsecond and never wait for the disk, the
///    store's queue or a drain (`HistoryStore+Inbox.swift`).
///  * Everything else is an isolated call: `status()`, `statistics()`,
///    `withDatabase`, and the chunk runner `inChunks`.
///  * `init` does no I/O; the file is opened, migrated and, if needed, rebuilt
///    on the first isolated call.
///  * `shutdown()` at quit closes it for good.
///  * It logs one line per state change (opened, unavailable, rebuilt,
///    closed) and rate-limited lines for dropped or failed work, never per
///    scan and never anything read from a transcript (`HistoryStore+Log.swift`).
///
/// Why an actor with a `HistoryDatabase` inside and not the database as an
/// actor: the connection is a non-Sendable class owned by the actor, so the
/// compiler proves it never leaves (returning it from an isolated method is an
/// error). The actor's executor serialises every call, which is all SQLite's
/// multi-thread mode requires.
///
/// Reentrancy rules for code running here: never hold a `HistoryDatabase` or a
/// statement across an `await` (the connection can be replaced by a rebuild in
/// between; `guarded` fetches the current one per call), and never rely on
/// state read before an `await` still being true after it.
actor HistoryStore: HistoryIngesting {
    /// The generic default of `inChunks`, sized for plain rows (about 5 us
    /// each). No production path uses it: the scan packs its own transactions
    /// of `scanChunkObservations` (1,000) observations, ~40 us each, and
    /// passes one pack per chunk.
    static let defaultChunkSize = 2_000
    /// After a failed open that may heal (another instance holds the lock, a
    /// transient SQLite error) the next call retries once this much later.
    static let defaultLockRetryInterval: Duration = .seconds(60)

    /// `~/Library/Application Support/AgentMeter`. NOT inside a
    /// `claude-usage-cache*` directory: `ClaudeUsageCacheStore.prune` deletes
    /// every foreign file it finds there.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
    }

    /// The app's instance. Lazy, so a test that never touches it never creates
    /// the real database; tests build their own over a temporary directory.
    /// Its accounting zone follows the system zone: `TimeZone.current` is what
    /// the usage ledger's `Calendar.current` days use, so a zone change while
    /// the app runs moves both at the next scan instead of at the next launch.
    /// It is also the one that logs (`systemLog`); stores a test builds by
    /// the hundred stay silent unless they pass a sink.
    static let shared = HistoryStore(directory: defaultDirectory, timeZoneSource: { TimeZone.current }, log: systemLog)

    private let queue = DispatchSerialQueue(label: "agentmeter.history", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated let directory: URL
    nonisolated let databaseURL: URL
    nonisolated let retention: HistoryRetention
    /// The store owns the clock and the accounting time zone, so a test can pin
    /// both and the database hooks never call `Date()` themselves.
    nonisolated let clock: @Sendable () -> Date
    /// Read by every command and every read (`prepareDatabase`): a different
    /// zone than the open database's recomputes every `acct_day` first.
    nonisolated let timeZoneSource: @Sendable () -> TimeZone
    nonisolated var timeZone: TimeZone { timeZoneSource() }
    /// Monotonic time for the retry latch only; a test advances it by hand.
    nonisolated let retryClock: @Sendable () -> ContinuousClock.Instant
    /// Where the state-change lines go (`HistoryStore+Log.swift`).
    nonisolated let logSink: @Sendable (String) -> Void

    private var configuration: HistoryDatabaseConfiguration
    let lockRetryInterval: Duration
    private var database: HistoryDatabase?
    private var latch = Latch.none
    private var lastRecovery: HistoryRecovery?
    /// Set by `shutdown()`; never cleared.
    private(set) var isShutDown = false
    /// Written by the store's own code only (`HistoryStore+Inbox.swift`, `inChunks`).
    var counters = HistoryStoreStatistics()
    /// Scan tickets, quota thinning state, per-open flags (`HistoryStoreMemory.swift`).
    var memory = HistoryStoreMemory()
    /// The last unavailable reason logged, so a latch retried every minute
    /// with the same answer (a second instance) logs once, not every minute.
    var lastLoggedUnavailable: String?

    /// The pending commands, oldest first, and whether a drain is running. See `HistoryStore+Inbox.swift`.
    nonisolated let inbox = OSAllocatedUnfairLock(initialState: Inbox())

    /// Why the store is not opening again right now.
    private enum Latch {
        case none
        /// A newer schema, an unrecoverable file, a failed migration, an old
        /// SQLite, or `shutdown()`: retrying cannot change the answer within
        /// this process.
        case permanent(any Error)
        /// Another instance holds the lock, the lock or its directory cannot
        /// be had, the file is not writable, or a transient open error: try
        /// again once `retryClock` passes `after`.
        case retry(after: ContinuousClock.Instant, error: any Error)
    }

    /// Does no I/O and takes no lock beyond allocation: cheap enough for a
    /// static initialiser or the MainActor. `timeZone` pins the accounting
    /// zone; `timeZoneSource`, when given, replaces it and is re-read before
    /// every command and read. `configure` adjusts the database configuration
    /// for tests (a fake SQLite version, no lock, fewer quarantined files);
    /// `retryClock` and `log` are test seams too. The closure parameters after
    /// `configure` stay after it so that a trailing closure keeps binding to
    /// `configure`.
    init(
        directory: URL,
        retention: HistoryRetention = HistoryRetention(),
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current,
        lockRetryInterval: Duration = HistoryStore.defaultLockRetryInterval,
        configure: @Sendable (inout HistoryDatabaseConfiguration) -> Void = { _ in },
        timeZoneSource: (@Sendable () -> TimeZone)? = nil,
        retryClock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.databaseURL = directory.appendingPathComponent(HistoryDatabase.fileName)
        self.retention = retention
        self.clock = clock
        let source = timeZoneSource ?? { timeZone }
        self.timeZoneSource = source
        self.lockRetryInterval = lockRetryInterval
        self.retryClock = retryClock
        self.logSink = log
        var config = HistoryDatabaseConfiguration(url: directory.appendingPathComponent(HistoryDatabase.fileName))
        config.clock = clock
        config.timeZone = source()
        config.retention = retention
        configure(&config)
        self.configuration = config
    }

    // MARK: Status

    /// Opens the database if it is not open (and the latch allows a try), then
    /// reports. Sticky: after a rebuild it stays `.rebuilt` for the life of the
    /// process, because what was lost does not come back.
    func status() -> HistoryStatus {
        do { _ = try openedDatabase() } catch { return .unavailable(reason: String(describing: error)) }
        if let recovery = lastRecovery { return .rebuilt(quarantinedTo: recovery.quarantinedTo?.path ?? "") }
        return .ready
    }

    func statistics() -> HistoryStoreStatistics { counters }

    // MARK: Opening, the latch and corruption handling

    /// The open database, opening it first when needed. Throws the latched
    /// error while the latch holds.
    func openedDatabase() throws -> HistoryDatabase {
        if let database { return database }
        switch latch {
        case let .permanent(error): throw error
        case let .retry(deadline, error): if retryClock() < deadline { throw error }
        case .none: break
        }
        counters.openAttempts += 1
        do {
            let opened = try HistoryDatabase.open(configuration)
            database = opened
            latch = .none
            if let recovery = opened.recovery { lastRecovery = recovery }
            logOpened(opened, schemaVersion: configuration.migrations.count)
            return opened
        } catch {
            latch = latch(for: error)
            logUnavailable(error, permanent: isPermanent(latch))
            throw error
        }
    }

    private func latch(for error: any Error) -> Latch {
        switch error as? HistoryStoreError {
        case .schemaTooNew, .unrecoverable, .migrationFailed, .sqliteTooOld, .foreignDatabase:
            return .permanent(error)
        default:
            // lockedByAnotherInstance, lockUnavailable, a read-only file, a
            // busy file, a transient I/O error.
            return .retry(after: retryClock() + lockRetryInterval, error: error)
        }
    }

    private func isPermanent(_ latch: Latch) -> Bool {
        if case .permanent = latch { return true }
        return false
    }

    /// Runs `body` on the current database. A corruption error from `body`
    /// closes the handle, quarantines the files, creates an empty database
    /// (same lock) and throws `HistoryStoreError.rebuilt`, so the caller knows
    /// the operation did not happen and the store is empty now. If recreating
    /// fails too, the store latches as unavailable and the error propagates.
    /// A defunct handle (`SQLiteError.isDefunctHandle`: the file went
    /// read-only, or was deleted or moved under it) is closed and latched for
    /// a retry.
    func guarded<T>(_ body: (HistoryDatabase) throws -> T) throws -> T {
        let db = try openedDatabase()
        do {
            return try body(db)
        } catch let error as SQLiteError where error.isCorruption {
            do {
                lastRecovery = try db.recreateAfterCorruption(reason: "\(error)")
                counters.rebuilds += 1
                logRebuilt(quarantinedTo: lastRecovery?.quarantinedTo, trigger: error)
            } catch {
                database?.close()
                database = nil
                latch = .permanent(error)
                logUnavailable(error, permanent: true)
                throw error
            }
            throw HistoryStoreError.rebuilt(quarantinedTo: lastRecovery?.quarantinedTo)
        } catch let error as SQLiteError where error.isDefunctHandle {
            // Deleted while the app runs (a manual reset: IOERR_VNODE), moved
            // (READONLY_DBMOVED), or its shared memory went read-only. The
            // handle would fail every read and write for the life of the
            // process; the reopen after the interval gets the file now at the
            // path (a deleted one comes back empty).
            close()
            latch = .retry(after: retryClock() + lockRetryInterval, error: error)
            logUnavailable(error, permanent: false)
            throw error
        }
    }

    /// Runs `body` on the database from outside the actor: tests and
    /// inspection. The store's own hooks run inside the actor through `guarded`.
    func withDatabase<T: Sendable>(_ body: @Sendable (HistoryDatabase) throws -> T) throws -> T {
        try guarded(body)
    }

    /// Closes the connection and releases the lock. The next isolated call
    /// opens again, unless the latch says otherwise.
    func close() {
        database?.close()
        database = nil
    }

    /// Points the open database, and every later open, at the zone source's
    /// current zone. True when that changed it (the caller then recomputes).
    func adoptCurrentTimeZone(_ db: HistoryDatabase) -> Bool {
        let zone = timeZoneSource()
        guard zone.identifier != db.config.timeZone.identifier else { return false }
        db.useAccountingTimeZone(zone)
        configuration.timeZone = zone
        return true
    }

    // MARK: Shutdown

    /// Ends the store for the rest of the process, at quit. In order:
    ///  * applies the quota, legacy-quota and reset-grant commands still in
    ///    the inbox (one short transaction each): the last readings of a
    ///    session cannot be fetched again;
    ///  * drops the queued scans and custom commands (counted): the next
    ///    launch's scan re-feeds whatever AMCU holds, so waiting for a cold
    ///    backfill would only delay the quit;
    ///  * resumes every queued `flush()`;
    ///  * latches `.closed` for good, so a later chunk of a scan in flight
    ///    (or anything submitted afterwards) cannot reopen the file;
    ///  * closes the connection. The last connection's close checkpoints the
    ///    WAL into the main file and empties it, so the next launch does not
    ///    take itself for a crash and run a full `integrity_check`. The one
    ///    exception is a quit while that check's own read-only connection is
    ///    open: the WAL stays, and the next launch runs the check once more.
    ///
    /// Isolated and synchronous, so it runs whole between two chunks of a
    /// scan in flight (at most one chunk, ~50-85 ms, after it is called). That
    /// scan's next chunk then finds the store closed and stops; a file's
    /// watermark is only ever written in the transaction of its last piece,
    /// so nothing on disk claims more than was applied, and the next launch
    /// re-applies the rest. Idempotent. Bound the wait with a deadline from
    /// the caller (`QuitSequence`): a chunk blocked in an fsync can take longer.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        let pending = inbox.withLock { state -> [Command] in
            defer { state.commands.removeAll() }
            return state.commands
        }
        var applied = 0, dropped = 0
        for command in pending {
            switch command {
            case let .barrier(continuation):
                continuation.resume()
            case .quota, .legacyQuota, .resetGrants:
                if performRecord(command) { applied += 1 }
            case .scan, .custom:
                counters.droppedSubmissions += 1
                dropped += 1
            }
        }
        latch = .permanent(HistoryStoreError.closed)
        let wasOpen = database != nil
        close()
        logShutdown(wasOpen: wasOpen, applied: applied, dropped: dropped)
    }

    /// `PRAGMA integrity_check` on a separate read-only connection and a global
    /// queue, never on the store's executor: it blocks for about 1.3 s per
    /// 100 MB. `["ok"]` is healthy. Throws if the file does not exist yet.
    nonisolated func runIntegrityCheck(limit: Int = 5) async throws -> [String] {
        let url = databaseURL
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try HistoryDatabase.runIntegrityCheck(at: url, limit: limit) })
            }
        }
    }

    // MARK: Chunked writes

    /// The skeleton of every large write: `items` in chunks of at most `size`,
    /// each chunk in ONE `BEGIN IMMEDIATE` transaction on the current database,
    /// `Task.checkCancellation()` before it and `Task.yield()` after it (never
    /// after the last), so a queued `status()`, read or `shutdown()` waits for
    /// at most the chunk in flight: a scan transaction of 1,000 observations
    /// (`scanChunkObservations`) held a queued call for ~50 ms at p90 on the
    /// corpus-shaped backfill, 2,000 for ~85 ms, plus any autocheckpoint fsync.
    ///
    /// Error policy, per chunk:
    ///  * a SQLite or other error from `body` rolls that chunk back, counts it
    ///    in `failedChunks` and the run CONTINUES with the next chunk: one bad
    ///    row must not silently drop everything after it. The right defence is
    ///    to validate rows before the transaction so this never fires.
    ///  * cancellation, an unavailable or shut-down store, an error that closed
    ///    the store (a file gone read-only), or a rebuild underneath the run
    ///    stops it (`completed == false`); the rest re-arrives with the next scan.
    ///
    /// `body` receives the CURRENT database for that chunk (a rebuild between
    /// chunks replaces it) and must not keep it past its return. The last chunk
    /// is the one with `slice.endIndex == items.endIndex`: the place for a
    /// file's watermark row.
    @discardableResult
    func inChunks<T>(
        _ items: [T],
        size: Int = HistoryStore.defaultChunkSize,
        _ body: (HistoryDatabase, ArraySlice<T>) throws -> Void
    ) async -> HistoryChunkRun {
        precondition(size > 0, "chunk size must be positive")
        var run = HistoryChunkRun()
        var start = 0
        while start < items.count {
            do { try Task.checkCancellation() } catch {
                run.completed = false
                return run
            }
            let end = min(start + size, items.count)
            do {
                try guarded { db in
                    try db.conn.transaction(.immediate) { try body(db, items[start..<end]) }
                }
                run.committed += 1
                counters.committedChunks += 1
            } catch {
                run.failed += 1
                counters.failedChunks += 1
                logFailedChunk(error)
                // `HistoryStoreError`: rebuilt underneath, latched or shut down.
                // No database: this chunk's error closed it. Either way the
                // next chunk could not land.
                if error is HistoryStoreError || database == nil {
                    run.completed = false
                    return run
                }
            }
            start = end
            if start < items.count { await Task.yield() }
        }
        return run
    }
}
