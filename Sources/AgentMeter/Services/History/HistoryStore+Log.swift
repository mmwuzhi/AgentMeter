import Foundation
import os

// What the store says in Console. Nothing in the app reads `status()` or the
// counters yet, so without these lines a store that runs without history for
// weeks (a second instance, a newer schema, a read-only file) or rebuilt
// itself would go unnoticed, and quota samples AMCU cannot refill would be
// lost silently.
//
// Rules: one line per state CHANGE (opened, unavailable with a reason,
// quarantined and rebuilt, closed at quit), and rate-limited lines for work
// that is dropped or fails; nothing per scan, so a healthy store logs once per
// launch. Every line is content-free: reasons are error cases and SQLite codes
// (`logReason`), file names only (never a directory path), never a SQLite
// message (it can name a path), SQL text or anything read from a transcript.
extension HistoryStore {
    /// The unified log, marked public. `NSLog` (what `LoginItem` uses) lands
    /// there as `<private>` on current macOS, so Console would show nothing
    /// readable; every line here is content-free by the rules above, which is
    /// what makes `.public` safe. Filter Console on "AgentMeter: history".
    static let systemLog: @Sendable (String) -> Void = {
        historyLogger.notice("AgentMeter: history \($0, privacy: .public)")
    }

    private static let historyLogger = Logger(subsystem: "com.shu.agentmeter", category: "history")

    /// The first occurrence, then every 100th: enough to see that something
    /// keeps failing without one line per refresh.
    static func isLogged(occurrence n: Int) -> Bool { n == 1 || n % 100 == 0 }

    func logOpened(_ db: HistoryDatabase, schemaVersion: Int) {
        lastLoggedUnavailable = nil
        let shutdown = db.openedAfterUncleanShutdown ? "after an unclean shutdown, integrity check due" : "clean"
        logSink("opened (schema \(schemaVersion), \(shutdown))")
        if let recovery = db.recovery {
            let moved = recovery.quarantinedTo?.lastPathComponent ?? "nothing (only sidecar files)"
            logSink("the database was damaged at open: quarantined as \(moved), rebuilt empty")
        }
    }

    /// Once per distinct reason: a latch retried every minute with the same
    /// answer (another instance holds the lock) logs once until something changes.
    func logUnavailable(_ error: any Error, permanent: Bool) {
        let reason = HistoryStoreError.logReason(error)
        guard reason != lastLoggedUnavailable else { return }
        lastLoggedUnavailable = reason
        if permanent {
            logSink("unavailable for the rest of this process: \(reason)")
        } else {
            logSink("unavailable, retrying after \(lockRetryInterval): \(reason)")
        }
    }

    func logRebuilt(quarantinedTo: URL?, trigger: SQLiteError) {
        let moved = quarantinedTo?.lastPathComponent ?? "nothing (only sidecar files)"
        logSink("damaged database found while running (\(trigger.logReason)): quarantined as \(moved), rebuilt empty")
    }

    func logShutdown(wasOpen: Bool, applied: Int, dropped: Int) {
        logSink("closed for quit (\(wasOpen ? "database closed" : "was not open"), "
                + "\(applied) queued quota commands applied, \(dropped) queued scans or custom commands dropped)")
    }

    func logDropped(_ error: any Error) {
        let n = counters.droppedSubmissions
        guard !isShutDown, Self.isLogged(occurrence: n) else { return }
        logSink("dropped \(n) submission(s) so far, store unavailable: \(HistoryStoreError.logReason(error))")
    }

    func logFailedChunk(_ error: any Error) {
        let n = counters.failedChunks
        guard !isShutDown, Self.isLogged(occurrence: n) else { return }
        logSink("\(n) write transaction(s) rolled back so far, latest: \(HistoryStoreError.logReason(error))")
    }

    func logFailedCommand(_ error: any Error) {
        let n = counters.failedCommands
        guard !isShutDown, Self.isLogged(occurrence: n) else { return }
        logSink("\(n) command(s) failed so far, latest: \(HistoryStoreError.logReason(error))")
    }
}
