import AgentStatusCore
import Foundation

// What a session row says about how the session's latest turn ended, next to
// what the session is doing now. Two things stay apart:
//
//  * the session's state (Working / Waiting / Idle / Error): what its process,
//    Claude Code's registry and the hooks say right now, unchanged;
//  * the latest turn's result: a turn the outcome detector saw end, as its
//    event recorded it (`TaskOutcomeAnnouncement`, `events.jsonl`). Finished
//    is a turn that ended, never the session: the process stays, and the next
//    prompt starts the next turn.
//
// The state always wins: a working or waiting row shows no result, and a
// result shows only while the turn it belongs to is still the session's
// latest (the turn ledger saw no prompt after it ended) and for
// `ActiveAgent.turnResultWindow` after it ended. Nothing is marked read and
// nothing has to be dismissed: a result goes by itself.

/// How a session's latest turn ended, from its newest task outcome event.
/// Only the two ends the detector confirms: finished (`task_completed`) and
/// failed (`task_failed`). A newer wait, interruption or unconfirmed end
/// leaves nothing to show, and so does an event older than the session's
/// latest prompt (`SessionTurnResults.current`).
struct SessionTurnResult: Sendable, Equatable {
    enum Outcome: String, Sendable, Equatable {
        case finished, failed
    }

    var outcome: Outcome
    /// When the turn ended: the event's `occurredAt` (the `Stop`, or the
    /// failure).
    var endedAt: Date
    /// The producer's detail line ("12m run", "Rate limit · after 3m"),
    /// sanitized; nil when it had none.
    var detail: String?
}

enum SessionTurnResults {
    /// The task outcome kinds, every one of which ends what came before it.
    /// Only a finished or failed one is shown; a newer wait (the session asked
    /// mid-turn), interruption (the user's own Esc) or unconfirmed end
    /// (background work still running at the last check) hides an older
    /// result, which belongs to an earlier turn.
    static let eventKinds: Set<AgentMeterEventKind> = [
        .taskCompleted, .taskFailed, .taskWaiting, .taskInterrupted, .taskUnknown,
    ]

    /// Each session's newest task outcome event (by when it happened), as a
    /// result when it is a finished or failed turn. A session whose newest
    /// event is anything else has no entry.
    ///
    /// A wait never outranks the end of its own task: it can be stamped a few
    /// milliseconds after the `Stop` (its time is its start plus the waiting
    /// delay, and the registry reading behind it may be carried over), and a
    /// wait in a later turn of the task comes after a prompt, which hides the
    /// older end anyway (`current`).
    static func newestBySession(_ events: [AgentMeterEvent]) -> [String: SessionTurnResult] {
        let ended = Set(events.lazy.filter { $0.kind == .taskCompleted || $0.kind == .taskFailed }.map(taskOf))
        var newest: [String: AgentMeterEvent] = [:]
        for event in events where eventKinds.contains(event.kind) {
            guard let sessionID = event.subject.sessionID, !sessionID.isEmpty else { continue }
            if event.kind == .taskWaiting, ended.contains(taskOf(event)) { continue }
            if let current = newest[sessionID], !isNewer(event, than: current) { continue }
            newest[sessionID] = event
        }
        return newest.compactMapValues(result)
    }

    /// The results whose turn is still the session's latest: the ledger's
    /// `lastPromptAt` (a person's prompt or a background report's, which
    /// starts the next turn) is not after the turn ended. A session the
    /// ledger no longer knows (swept a day after its process went) keeps its
    /// result. Compared in whole milliseconds, as the event stores its times.
    static func current(_ results: [String: SessionTurnResult],
                        turnStarts: [String: Date]) -> [String: SessionTurnResult] {
        results.filter { sessionID, result in
            guard let start = turnStarts[sessionID] else { return true }
            return HistoryTime.ms(start) <= HistoryTime.ms(result.endedAt)
        }
    }

    private static func result(_ event: AgentMeterEvent) -> SessionTurnResult? {
        let outcome: SessionTurnResult.Outcome
        switch event.kind {
        case .taskCompleted: outcome = .finished
        case .taskFailed: outcome = .failed
        default: return nil
        }
        return SessionTurnResult(outcome: outcome, endedAt: event.occurredAt, detail: detail(event.content.body))
    }

    private static func taskOf(_ event: AgentMeterEvent) -> String {
        "\(event.subject.sessionID ?? "")|\(event.subject.taskKey ?? event.id)"
    }

    /// The body's second line (the first names the session).
    static func detail(_ body: String) -> String? {
        let lines = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2 else { return nil }
        return SessionLabel.title(String(lines[1]))
    }

    /// Occurrence, then discovery, then id: total, so the answer does not
    /// depend on the order the log returned them in.
    private static func isNewer(_ a: AgentMeterEvent, than b: AgentMeterEvent) -> Bool {
        if a.occurredAt != b.occurredAt { return a.occurredAt > b.occurredAt }
        if a.discoveredAt != b.discoveredAt { return a.discoveredAt > b.discoveredAt }
        return a.id > b.id
    }
}

/// What a session row (and a collapsed group's header) marks about the latest
/// turn, next to the state.
enum SessionTurnMarker: Sendable, Equatable {
    case finished(at: Date)
    /// Nil only for a hook-reported failure without a time.
    case failed(at: Date?)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension ActiveAgent {
    /// How long a finished or failed turn stays marked on an idle row after
    /// it ended. Long enough to come back from a meeting to a list that says
    /// which sessions finished meanwhile; short enough that a mark is news.
    /// After it the row reads plain idle with its age, as before.
    static let turnResultWindow: TimeInterval = 3_600

    /// The latest turn's mark for this row, measured at the row's own
    /// `observedAt` like its other ages. None while it works or waits: the
    /// state is what it is doing now. A hook-reported failure (`error`, red
    /// for `errorAttentionWindow`) is the failed turn itself and keeps its
    /// own time. Otherwise the session's latest result (`SessionTurnResults
    /// .current`) within `turnResultWindow`.
    func turnMarker(in results: [String: SessionTurnResult]) -> SessionTurnMarker? {
        switch displayStatus {
        case .working, .waiting:
            return nil
        case .error:
            return .failed(at: statusUpdatedAt)
        case .idle, nil:
            guard let sessionID = session?.id, let result = results[sessionID] else { return nil }
            // A turn may end after the row's last full refresh (its
            // `observedAt` moves only then, every refresh interval while a
            // popover is open): it shows at once, as "0s ago" until then.
            // Both times are this Mac's clock.
            guard observedAt.timeIntervalSince(result.endedAt) <= Self.turnResultWindow else { return nil }
            switch result.outcome {
            case .finished: return .finished(at: result.endedAt)
            case .failed: return .failed(at: result.endedAt)
            }
        }
    }

    /// The row's state words with the mark in place of the plain state:
    /// "last turn finished · 3m ago", "last turn failed · 3m ago".
    func activityText(marker: SessionTurnMarker?) -> String {
        switch marker {
        case let .finished(at):
            return "last turn finished · \(Self.relativeAge(from: at, to: observedAt))"
        case let .failed(at):
            guard let at else { return "last turn failed" }
            return "last turn failed · \(Self.relativeAge(from: at, to: observedAt))"
        case nil:
            return activityText
        }
    }
}

extension ActiveAgentGroup {
    /// The mark a group's header carries: a failure while a session in it is
    /// in `error`; while nothing in it works or waits, a failed turn before a
    /// finished one. Working and waiting headers keep their dot.
    func turnMarker(in results: [String: SessionTurnResult]) -> SessionTurnMarker? {
        switch topStatus {
        case .working, .waiting:
            return nil
        case .error, .idle, nil:
            let markers = allAgents.compactMap { $0.turnMarker(in: results) }
            return markers.first(where: \.isFailure) ?? markers.first
        }
    }

    /// The collapsed header: total, then the most urgent state with how many
    /// sessions are in it, or, with every session idle, how many latest turns
    /// finished or failed; then the usage. "3 · 1 finished · 2.5M · $1.20".
    func collapsedSummary(turnResults results: [String: SessionTurnResult]) -> String {
        var parts = ["\(agentCount)"]
        if let status = topStatus, status != .idle {
            let count = allAgents.filter { $0.displayStatus == status }.count
            parts.append("\(count) \(status == .error ? "failed" : status.rawValue)")
        } else {
            let markers = allAgents.compactMap { $0.turnMarker(in: results) }
            let failed = markers.filter(\.isFailure).count
            if failed > 0 { parts.append("\(failed) failed") }
            if markers.count > failed { parts.append("\(markers.count - failed) finished") }
        }
        if let usage = aggregatedUsageText {
            parts.append(usage)
        }
        return parts.joined(separator: " · ")
    }
}
