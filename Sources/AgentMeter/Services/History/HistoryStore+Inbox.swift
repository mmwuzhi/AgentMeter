import Foundation
import os

extension HistoryStore {
    /// One unit of work for the drain. Everything a producer hands over is
    /// plain `Sendable` data, so a command can sit in the inbox until the
    /// store's queue gets to it.
    enum Command: Sendable {
        case scan(HistoryScanBatch)
        case quota([QuotaSampleRow])
        case legacyQuota([QuotaSampleRow])
        case resetGrants([ResetGrantObservation], recordedMs: Int64)
        /// Resumed once everything submitted before it has been applied.
        case barrier(CheckedContinuation<Void, Never>)
        /// Runs on the store's executor with the actor isolated. The seam for
        /// explicit maintenance (`submitRebuildRequests`) and for tests that
        /// need a command that yields in the middle. Not subject to the
        /// unavailable-store drop: the body decides what to do about a missing
        /// database. A throw counts as a failed command. Dropped, not run,
        /// when still queued at `shutdown()`.
        case custom(@Sendable (isolated HistoryStore) async throws -> Void)
    }

    /// The state behind the inbox lock. `draining` lives INSIDE the locked
    /// state on purpose: deciding "start a drain" and appending the command
    /// must be one atomic step, and so must "the inbox is empty, stop".
    struct Inbox: Sendable {
        var commands: [Command] = []
        var draining = false
    }

    // MARK: Producers (non-isolated, O(1), never wait for the disk)

    nonisolated func submit(scan: HistoryScanBatch) { enqueue(.scan(scan)) }
    nonisolated func submit(quota: [QuotaSampleRow]) { enqueue(.quota(quota)) }
    nonisolated func submit(legacyQuota: [QuotaSampleRow]) { enqueue(.legacyQuota(legacyQuota)) }
    nonisolated func submit(resetGrants: [ResetGrantObservation], recordedMs: Int64) {
        enqueue(.resetGrants(resetGrants, recordedMs: recordedMs))
    }

    /// Runs `body` on the store's executor, in submission order with the data
    /// commands. See `Command.custom`.
    nonisolated func enqueue(_ body: @escaping @Sendable (isolated HistoryStore) async throws -> Void) {
        enqueue(.custom(body))
    }

    /// A barrier: returns after every command submitted before this call has
    /// been applied (or dropped). Never waits for commands submitted later.
    /// Non-isolated, so awaiting it does not first hop onto the store's queue.
    nonisolated func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue(.barrier(continuation))
        }
    }

    /// Appends `command` and starts a drain ONLY when none is running.
    ///
    /// Why not the simpler "start a drain when the inbox was empty": the
    /// drain pops a command, and while it applies that command it yields
    /// between chunks. A submit arriving in that window sees an empty inbox,
    /// starts a SECOND drain, and the two interleave at their yields: calls
    /// were applied out of order in 199 of 200 rounds. With the flag inside the
    /// lock there is exactly one consumer, so order is the order of the appends
    /// (and each producer's own calls are ordered by its own program order).
    nonisolated func enqueue(_ command: Command) {
        let startDrain = inbox.withLock { state -> Bool in
            state.commands.append(command)
            if state.draining { return false }
            state.draining = true
            return true
        }
        // `.utility` explicitly: a Task created from a high-QoS caller (the
        // MainActor refresh) would inherit that priority and drag the store's
        // queue up with it.
        if startDrain { Task(priority: .utility) { await self.drain() } }
    }

    // MARK: Consumer (the one drain)

    /// Pops ONE command at a time and applies it to the end before popping the
    /// next, so a command that yields between chunks cannot be overtaken (only
    /// `shutdown()` takes the queued ones past it, at quit, in order). The
    /// `draining` flag is cleared under the lock only when the inbox is empty;
    /// a producer that appends after that sees `draining == false` and starts a
    /// new drain, so a command is never stranded.
    private func drain() async {
        while true {
            let next = inbox.withLock { state -> Command? in
                guard !state.commands.isEmpty else {
                    state.draining = false
                    return nil
                }
                return state.commands.removeFirst()
            }
            guard let command = next else { return }
            await perform(command)
            // Lets queued isolated calls (status, withDatabase) run between
            // commands instead of waiting for a long inbox to empty.
            await Task.yield()
        }
    }

    private func perform(_ command: Command) async {
        switch command {
        case let .barrier(continuation):
            continuation.resume()
        case let .custom(body):
            do {
                try await body(self)
                counters.appliedCommands += 1
            } catch {
                countFailedCommand(error)
            }
        case let .scan(batch):
            guard isAvailableElseDrop() else { return }
            do {
                try await applyScanCommand(batch)
                counters.appliedCommands += 1
            } catch {
                countFailedCommand(error)
            }
        case .quota, .legacyQuota, .resetGrants:
            performRecord(command)
        }
    }

    /// A quota, legacy-quota or reset-grant command: one transaction, never
    /// suspends, so `shutdown()` can apply the queued ones in one go. True
    /// when it was applied.
    @discardableResult
    func performRecord(_ command: Command) -> Bool {
        guard isAvailableElseDrop() else { return false }
        do {
            try applyRecord(command)
            counters.appliedCommands += 1
            return true
        } catch {
            countFailedCommand(error)
            return false
        }
    }

    /// A data command on an unavailable store is dropped and counted: the
    /// observations are never retried forever, and the next scan re-feeds
    /// what AMCU still holds.
    private func isAvailableElseDrop() -> Bool {
        do {
            _ = try openedDatabase()
            return true
        } catch {
            counters.droppedSubmissions += 1
            logDropped(error)
            return false
        }
    }

    private func countFailedCommand(_ error: any Error) {
        counters.failedCommands += 1
        logFailedCommand(error)
    }
}
