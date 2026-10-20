import Dispatch
import Foundation
import os

/// The only owner of `events.jsonl` (format in `AgentMeterEventLog.swift`):
/// the record of what AgentMeter noticed and told the user about, which of
/// those the user has read, and the dedup memory that keeps a restart or a
/// rescan from announcing the same thing twice.
///
///  * Runs on a private serial queue used as the actor's executor, like
///    `HistoryStore`: file I/O never happens on the MainActor or on a
///    cooperative-pool thread.
///  * Every change is written before the call returns (one small append; no
///    buffer to flush at quit). A compaction rewrites the file atomically.
///  * The file is read lazily, on the first call (`prepare()` at launch).
///  * Before each call it catches up with lines another process appended
///    (a second instance, a test build next to the installed app) and
///    re-reads the file when another process replaced it, keeping the
///    events it knew that the new file lacks. Without a file lock two
///    processes can still both record one id within the same instant.
///  * When a write fails the change stays in memory, so dedup and read state
///    hold for this process; the next write rewrites the whole file.
///  * Limits, applied at a compaction: read events older than `retention`
///    go; unread ones stay however old. Past `maximumEvents` the oldest read
///    events go first; only when unread events alone exceed it do the oldest
///    unread ones go, counted in `unreadOverflow()` and logged, never
///    silently. An unread event recorded for the history only
///    (`Limits.historyOnlyReasons`) counts as read for these limits. Nothing
///    here ever marks an event read on its own.
///  * The first read of the log in a run marks events an earlier run left
///    `pending` as `interrupted`: terminal, never retried.
actor AgentMeterEventStore {
    struct Limits: Sendable, Equatable {
        /// Applies to read events only.
        var retention: TimeInterval = 180 * 86_400
        /// A hard ceiling on all events, read or not, so the file and memory
        /// stay bounded (about 400 B an event).
        var maximumEvents = 10_000
        /// A compaction runs once superseded lines (delivery and read
        /// updates, unreadable lines) outnumber both the live events and this.
        var minimumSupersededLines = 512
        /// Suppression reasons of events their producer recorded for the
        /// history only: nothing asks the user to read them, so unread they
        /// age out and yield to the cap like read events, and never count as
        /// overflow (`AgentMeterEventLogState.pruning`).
        var historyOnlyReasons: Set<String> = TaskOutcomeAnnouncement.historyOnlyReasons

        static let standard = Limits()
    }

    static let fileName = "events.jsonl"

    /// The app's store, next to `history.sqlite`. Lazy: a test that never
    /// touches it never reads the real file.
    static let shared = AgentMeterEventStore(
        fileURL: HistoryStore.defaultDirectory.appendingPathComponent(fileName), log: systemLog)

    /// Keeps everything in memory only (the test initialiser of
    /// `NotificationManager`).
    static func inMemory(limits: Limits = .standard, clock: @escaping @Sendable () -> Date = { Date() }) -> AgentMeterEventStore {
        AgentMeterEventStore(fileURL: nil, limits: limits, clock: clock)
    }

    private let queue = DispatchSerialQueue(label: "agentmeter.events", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated let fileURL: URL?
    nonisolated let limits: Limits
    nonisolated let clock: @Sendable () -> Date
    nonisolated let logSink: @Sendable (String) -> Void

    private var state = AgentMeterEventLogState()
    private var loaded = false
    /// The file as `state` knows it: which one, and how many of its bytes
    /// have been applied. Nil while there is no file, or after it vanished.
    private var file: (identity: AtomicFile.Identity, length: UInt64)?
    /// Memory holds what the file lacks (a failed write, a file that
    /// vanished or was replaced without some events): the next write
    /// rewrites the file whole instead of appending.
    private var needsRewrite = false
    /// False while the file exists but cannot be read: nothing is written
    /// then, since a rewrite from memory would replace events never read.
    private var readable = true
    private var writeFailures = 0
    private var loggedNewerFormat = false
    /// Set once this run has read the log and settled what an earlier run
    /// left pending.
    private var settledEarlierRuns = false

    init(fileURL: URL?, limits: Limits = .standard, clock: @escaping @Sendable () -> Date = { Date() },
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.limits = limits
        self.clock = clock
        self.logSink = log
    }

    // MARK: - Writing

    /// Reads the file now (and compacts it if due), so the first event does
    /// not wait for that.
    func prepare() {
        synchronize()
    }

    /// Records a new event, unread and with its delivery pending. An id
    /// already on record returns that event untouched: whatever its delivery
    /// was (even `interrupted`, from a run that died before posting), it is
    /// not delivered again.
    @discardableResult
    func record(_ event: AgentMeterEvent) -> AgentMeterEventSubmission {
        synchronize()
        if let existing = state.events[event.id] { return .duplicate(existing) }
        // A read event this old may have been dropped already; recording it
        // again would bring it back unread.
        guard event.occurredAt >= clock().addingTimeInterval(-limits.retention) else { return .expired }
        var fresh = event
        fresh.delivery = .pending
        fresh.readAt = nil
        commit([.event(fresh)])
        return .recorded(state.events[fresh.id] ?? fresh)
    }

    /// Settles a delivery. It only moves forward (`State.rank`): a final
    /// state stays as it is, and the recording run's own outcome replaces an
    /// `interrupted` another run inferred while this one was still posting.
    @discardableResult
    func setDelivery(_ delivery: AgentMeterEventDelivery, forEventID id: String) -> AgentMeterEvent? {
        synchronize()
        guard let current = state.events[id] else { return nil }
        guard current.delivery.isSuperseded(by: delivery) else { return current }
        commit([.delivery(id: id, delivery: delivery)])
        return state.events[id]
    }

    /// Marks these events read at `date` (default now). Returns the ids that
    /// were unread; read ones keep their first `readAt`.
    @discardableResult
    func markRead(ids: [String], at date: Date? = nil) -> [String] {
        synchronize()
        var seen = Set<String>()
        let unread = ids.filter { seen.insert($0).inserted && state.events[$0]?.isUnread == true }
        guard !unread.isEmpty else { return [] }
        let at = date ?? clock()
        // Bounded lines, however many are read at once.
        let entries = stride(from: 0, to: unread.count, by: Self.idsPerReadLine).map {
            AgentMeterEventLogEntry.read(ids: Array(unread[$0..<min($0 + Self.idsPerReadLine, unread.count)]), at: at)
        }
        commit(entries)
        return unread
    }

    @discardableResult
    func markRead(matching filter: AgentMeterEventFilter, at date: Date? = nil) -> [String] {
        synchronize()
        let ids = state.events.values.filter { $0.isUnread && filter.matches($0) }
            .sorted(by: AgentMeterEventLogState.oldestFirst).map(\.id)
        return markRead(ids: ids, at: date)
    }

    static let idsPerReadLine = 256

    // MARK: - Reading

    func event(id: String) -> AgentMeterEvent? {
        synchronize()
        return state.events[id]
    }

    /// Newest first (by discovery). `limit` nil: all that match.
    func events(matching filter: AgentMeterEventFilter = .all, limit: Int? = nil) -> [AgentMeterEvent] {
        synchronize()
        let matching = state.events.values.filter(filter.matches)
            .sorted { AgentMeterEventLogState.oldestFirst($1, $0) }
        guard let limit else { return matching }
        return Array(matching.prefix(max(0, limit)))
    }

    func unreadCount(matching filter: AgentMeterEventFilter = .all) -> Int {
        synchronize()
        return state.events.values.reduce(0) { $0 + ($1.isUnread && filter.matches($1) ? 1 : 0) }
    }

    /// Unread events dropped at the cap so far; nil when none ever were.
    func unreadOverflow() -> AgentMeterUnreadOverflow? {
        synchronize()
        return state.unreadOverflow
    }

    /// For tests and diagnostics.
    func statistics() -> Statistics {
        synchronize()
        return Statistics(events: state.events.count, lines: state.lineCount, unreadableLines: state.unreadableLines,
                          newestFormatVersion: state.newestFormatVersion, writeFailures: writeFailures,
                          needsRewrite: needsRewrite, unreadOverflow: state.unreadOverflow?.count ?? 0)
    }

    struct Statistics: Sendable, Equatable {
        var events: Int
        var lines: Int
        var unreadableLines: Int
        var newestFormatVersion: Int
        var writeFailures: Int
        var needsRewrite: Bool
        var unreadOverflow: Int
    }

    // MARK: - File

    /// Brings `state` up to date with the file before any call.
    private func synchronize() {
        guard let fileURL else {
            loaded = true
            return
        }
        guard loaded, readable else { return reload(fileURL) }
        guard let current = AtomicFile.status(fileURL) else {
            // Removed under us: memory is all there is now, and the next
            // write puts it back whole.
            needsRewrite = !state.events.isEmpty
            file = nil
            return
        }
        guard let known = file, known.identity == current.identity, current.length >= known.length else {
            // Replaced (another process compacted it), shrunk, or created by
            // someone else since we found none.
            return reload(fileURL)
        }
        guard current.length > known.length else { return }
        do {
            guard let tail = try AtomicFile.read(fileURL, from: known.length), tail.identity == known.identity else {
                return reload(fileURL)
            }
            let consumed = state.consume(tail.data)
            file = (known.identity, known.length + UInt64(consumed))
        } catch {
            logReadFailure(error)
        }
    }

    /// Reads the file whole into a fresh state, keeping the events memory
    /// had that the file lacks, then compacts if due.
    private func reload(_ fileURL: URL) {
        let firstLoad = !loaded
        loaded = true
        var fresh = AgentMeterEventLogState()
        do {
            if let contents = try AtomicFile.read(fileURL) {
                let consumed = fresh.consume(contents.data)
                file = (contents.identity, UInt64(consumed))
            } else {
                file = nil
            }
        } catch {
            // There but unreadable (permissions): run on memory, write
            // nothing, and try the file again at the next call.
            if readable { logReadFailure(error) }
            readable = false
            return
        }
        readable = true
        let missing = state.events.values.filter { fresh.events[$0.id] == nil }
        missing.forEach { fresh.carry($0) }
        state = fresh
        if firstLoad {
            logSink("loaded \(state.events.count) events (\(state.lineCount) lines, \(state.unreadableLines) unreadable)")
        }
        noteNewerFormat()
        if !missing.isEmpty { needsRewrite = true }
        // Before the compaction, so a due rewrite folds the marks in.
        settleEarlierRuns()
        // A due compaction writes the carried events too; otherwise they go
        // back on their own.
        compactIfDue()
        if needsRewrite { rewrite(fileURL) }
    }

    /// At this run's first successful read, every event still pending was
    /// recorded by a run that ended before writing its outcome (or by
    /// another instance still posting it, whose own outcome then outranks
    /// this mark). Marking them `interrupted` makes that terminal: they are
    /// never posted again, and they do not sit pending forever.
    private func settleEarlierRuns() {
        guard !settledEarlierRuns else { return }
        settledEarlierRuns = true
        let pending = state.events.values.filter { $0.delivery.state == .pending }
            .sorted(by: AgentMeterEventLogState.oldestFirst)
        guard !pending.isEmpty else { return }
        let interrupted = AgentMeterEventDelivery.interrupted(at: clock())
        commit(pending.map { .delivery(id: $0.id, delivery: interrupted) })
        logSink("\(pending.count) events an earlier run left pending marked interrupted (not retried)")
    }

    /// Applies `entries` to memory first, so dedup and read state hold even
    /// when the disk does not, then writes them.
    private func commit(_ entries: [AgentMeterEventLogEntry]) {
        for entry in entries { state.apply(entry) }
        if let fileURL, readable {
            if needsRewrite {
                rewrite(fileURL)
            } else {
                append(entries, to: fileURL)
            }
        }
        compactIfDue()
    }

    private func append(_ entries: [AgentMeterEventLogEntry], to fileURL: URL) {
        var data = Data()
        do {
            for entry in entries { data.append(try AgentMeterEventLogCodec.encode(entry)) }
            let appended = try AtomicFile.append(data, to: fileURL, startOnNewLine: true)
            state.noteLinesWritten(entries.count)
            if let known = file, known.identity == appended.identity, known.length == appended.lengthBefore {
                file = (known.identity, known.length + appended.written)
            } else if file == nil, appended.lengthBefore == 0 {
                file = (appended.identity, appended.written)
            }
            // Otherwise another process wrote since we last looked: the next
            // `synchronize` reads its lines, and ours again, which is harmless.
        } catch {
            needsRewrite = true
            logWriteFailure(error)
        }
    }

    private func compactIfDue() {
        let pruning = state.pruning(now: clock(), retention: limits.retention, maximumEvents: limits.maximumEvents,
                                    historyOnlyReasons: limits.historyOnlyReasons)
        let superseded = state.supersededLines > max(state.liveLines, limits.minimumSupersededLines)
        guard !pruning.isEmpty || superseded else { return }
        guard let fileURL else {
            // Memory only: the limits apply all the same.
            return prune(pruning)
        }
        // Pruning only ever happens together with a rewrite, so memory and
        // the file agree on what is kept.
        guard readable, !state.hasNewerFormat else { return noteNewerFormat() }
        prune(pruning)
        rewrite(fileURL)
    }

    /// Removes what `pruning` names; unread events among them go into the
    /// overflow total, which the rewrite then keeps.
    private func prune(_ pruning: AgentMeterEventLogState.Pruning) {
        state.remove(pruning.ids)
        guard !pruning.unread.isEmpty else { return }
        let now = clock()
        let base = state.unreadOverflow
            ?? AgentMeterUnreadOverflow(count: 0, throughDiscoveredAt: .distantPast, lastDroppedAt: now)
        let total = base.adding(pruning.unread, at: now)
        state.apply(.unreadOverflow(total))
        logSink("cap of \(limits.maximumEvents) reached with unread events only: dropped the "
                + "\(pruning.unread.count) oldest unread (\(total.count) so far)")
    }

    /// One `event` line per live event, oldest first, replacing the file.
    private func rewrite(_ fileURL: URL) {
        guard !state.hasNewerFormat else {
            // A newer build wrote lines this one may not fully understand:
            // appending stays safe, rewriting does not.
            noteNewerFormat()
            needsRewrite = false
            return
        }
        do {
            var data = Data()
            if let overflow = state.unreadOverflow {
                data.append(try AgentMeterEventLogCodec.encode(.unreadOverflow(overflow)))
            }
            for event in state.events.values.sorted(by: AgentMeterEventLogState.oldestFirst) {
                data.append(try AgentMeterEventLogCodec.encode(.event(event)))
            }
            try AtomicFile.replace(fileURL, with: data)
            state.didRewrite()
            needsRewrite = false
            if let now = AtomicFile.status(fileURL) { file = now } else { file = nil }
        } catch {
            needsRewrite = true
            logWriteFailure(error)
        }
    }

    // MARK: - Log

    /// The unified log, marked public: every line is counts and error codes,
    /// never a path or anything an event says. Filter Console on
    /// "AgentMeter: events".
    static let systemLog: @Sendable (String) -> Void = {
        eventsLogger.notice("AgentMeter: events \($0, privacy: .public)")
    }

    private static let eventsLogger = Logger(subsystem: "com.shu.agentmeter", category: "events")

    private func logWriteFailure(_ error: any Error) {
        writeFailures += 1
        guard HistoryStore.isLogged(occurrence: writeFailures) else { return }
        logSink("write failed (\(Self.logReason(error)), \(writeFailures) so far); kept in memory")
    }

    private func logReadFailure(_ error: any Error) {
        logSink("read failed (\(Self.logReason(error)))")
    }

    private func noteNewerFormat() {
        guard state.hasNewerFormat, !loggedNewerFormat else { return }
        loggedNewerFormat = true
        logSink("written by a newer build (format \(state.newestFormatVersion)); appending only, never rewriting")
    }

    private static func logReason(_ error: any Error) -> String {
        if let failure = error as? AtomicFile.Failure { return failure.logReason }
        return String(describing: type(of: error))
    }
}

/// What submitting an event came to.
enum AgentMeterEventSubmission: Sendable, Equatable {
    /// New. From the store: recorded with its delivery pending. From
    /// `NotificationManager.submit`: recorded and its delivery decided.
    case recorded(AgentMeterEvent)
    /// An event with this id is already on record, from this run or an
    /// earlier one. Nothing was posted.
    case duplicate(AgentMeterEvent)
    /// Older than the retention: the log would drop it at once, and it could
    /// not be told from one it already dropped. Nothing was recorded.
    case expired
}
