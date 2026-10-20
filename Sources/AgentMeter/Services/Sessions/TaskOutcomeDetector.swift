import AgentStatusCore
import Foundation

// Decides what became of a Claude session's task from three things the
// session writes for itself: the turn ledger (`TaskLedger`, from the hook
// helper), Claude Code's registry entry, and the status payload. Pure: the
// caller reads the files, passes the clock, and reads a transcript tail only
// when asked to.
//
// What each outcome rests on (Claude Code 2.1.301, POC C1–C3 and C1d):
//
// - Completed. The main `Stop` lists no subagent or workflow, and the
//   registry has left `busy` since: it turns `idle` (or `shell`, the REPL's
//   idle-with-a-shell) 30–70 ms after the final `Stop` on both the REPL and
//   the SDK path VS Code uses, and stays `busy`, keeping the stamp of the
//   turn's start, for as long as background agents run (C1, C2). A busy
//   registry holds the task whatever its stamp; a Stop hook that continues
//   the turn (C10, not measured) is expected to keep it busy too. Held for
//   `confirmDelay` so a flicker cannot end a task. Without a registry entry,
//   a quiet window stands in.
// - Paused. The `Stop` lists a subagent or workflow: they report back as a
//   prompt, which the ledger joins to the same task. Nothing to announce.
// - Uncertain end. No agent in flight, but a background shell or monitor
//   this task started is still running (or one of unknown owner after
//   background agents ran). When it ends, the agent that started it wakes
//   and reports: a subagent is revived (C1a), the main agent is notified.
//   In 45 days of local transcripts that happened for 86 of 88 subagent
//   shells (launch to revival p50 44 s, p90 527 s, p95 610 s) and for 73 of
//   90 main shells still running at a turn end (84% within 10 min of it);
//   the other 17 never ended (servers). Neither the hook input nor the
//   registry says when it will be — on the SDK path the registry is `idle`
//   while such a shell runs and stays `idle` while a revived subagent works
//   (C1d) — so such a task is never called finished: it stays uncertain
//   until a `Stop` with nothing of its own left running. After
//   `uncertainWindow` (and any later tool call) with no report, that state
//   is recorded once as `task_unknown`, never announced; a report then or
//   later joins the task, and its real end is announced as Completed. A
//   shell with no launch on record counts as the task's (conservative). A
//   session that ends meanwhile ends the watch without an outcome.
// - Failed. The main `StopFailure`. Not yet seen in a real session, so it is
//   announced only once the registry has left `busy`, or after a quiet
//   window without one; a registry that stays `busy` (background agents)
//   delays it to `failureBusyCap`.
// - Waiting. The registry says `waiting` (a permission prompt, a question)
//   for `waitingDelay`; without a registry entry, a permission notice the
//   payload still shows for `waitingDelayWithoutRegistry`. At most one per
//   turn. `dialog open` counts only while the turn runs: Claude Code writes
//   it for its own decision dialogs ("Session paused": retry on a fallback
//   model, continue on usage credits) and for the auto-mode billing notice,
//   which come up mid-turn, and also for a command UI the user opened
//   (`/config`), which comes up between turns (2.1.301 binary).
// - Interrupted. No `Stop` or `StopFailure` (Esc fires neither, C3), and the
//   registry turned idle after the turn began; the transcript's last message
//   record must be Claude Code's interruption marker. Recorded, never
//   announced. A registry-idle turn without the marker is left alone.

/// A registry reading for one session: the live process's entry.
struct TaskOutcomeRegistryReading: Sendable, Equatable {
    var status: ClaudeSessionRegistryEntry.Status?
    var waitingFor: String?
    var statusUpdatedAt: Date?

    init(status: ClaudeSessionRegistryEntry.Status?, waitingFor: String? = nil, statusUpdatedAt: Date?) {
        self.status = status
        self.waitingFor = waitingFor
        self.statusUpdatedAt = statusUpdatedAt
    }

    init(_ entry: ClaudeSessionRegistryEntry) {
        self.init(status: entry.status, waitingFor: entry.waitingFor, statusUpdatedAt: entry.statusUpdatedAt)
    }

    /// The main loop is idle: `idle`, or the REPL's `shell` (idle while a
    /// background shell runs).
    var isIdle: Bool { status == .idle || status == .shell }
    var isActive: Bool { status == .busy || status == .waiting }
}

/// What the transcript's tail says about the last turn.
enum TaskTranscriptVerdict: Sendable, Equatable {
    /// The last message record is Claude Code's `[Request interrupted by user…]`.
    case interrupted
    /// It is something else.
    case other
    /// No transcript, or it could not be read.
    case unavailable
}

struct TaskOutcome: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case completed, failed, waiting, interrupted
        /// The main agent stopped, but a background shell this task started
        /// still runs past `uncertainWindow`: not finished, not known to be
        /// coming back. Recorded only.
        case uncertain
        /// The turn ended without a hook saying how (the registry went idle
        /// with no `Stop` and no interruption marker), or the session ended
        /// with the task uncertain. Nothing is recorded; the detector just
        /// stops watching that turn.
        case unresolved

        var eventKind: AgentMeterEventKind? {
            switch self {
            case .completed: .taskCompleted
            case .failed: .taskFailed
            case .waiting: .taskWaiting
            case .interrupted: .taskInterrupted
            case .uncertain: .taskUnknown
            case .unresolved: nil
            }
        }
    }

    enum Confidence: String, Sendable, Equatable {
        /// Confirmed by a second, independent signal.
        case high
        /// One signal and a timeout.
        case medium
    }

    var kind: Kind
    var confidence: Confidence
    var sessionID: String
    var taskKey: String
    var segment: Int
    var origin: TaskLedgerTask.Origin
    /// When it happened: the `Stop`, the failure, the registry's turn to
    /// idle; for a wait, and for an uncertain end, the moment it became
    /// worth announcing.
    var occurredAt: Date
    /// Start of what the duration measures: the task's prompt, or the
    /// reopening report's for a later segment; for a wait, its start.
    var startedAt: Date
    /// End of what the duration measures: the last `Stop` (even when the
    /// announcement waited), the failure, the interruption; for a wait,
    /// `occurredAt`.
    var endedAt: Date
    var cwd: String?
    /// Background shells still running when it was called finished.
    var shellsStillRunning: Int = 0
    var cronsArmed: Bool = false
    /// `StopFailure`'s error kind.
    var error: String?
    var waitingReason: ActiveAgentWaitingReason?
    /// Names the occurrence; also the event id (`AgentMeterEvent.id`).
    var id: String

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var isReopened: Bool { segment > 0 }
}

struct TaskOutcomeEvaluation: Sendable, Equatable {
    var outcomes: [TaskOutcome] = []
    /// The earliest time at which the answer could change with no file
    /// changing; nil when only a file change can change it.
    var nextCheck: Date?

    mutating func check(at date: Date) {
        nextCheck = min(nextCheck ?? date, date)
    }
}

enum TaskOutcomeDetector {
    struct Timing: Sendable, Equatable {
        /// Clock skew allowed between the helper's timestamps and the
        /// registry's (both this Mac's clock; the registry writes after the
        /// hook returns, so the slack only covers rounding).
        var registrySkew: TimeInterval = 1
        /// How long the registry must stay idle after a `Stop` before the
        /// task counts as finished.
        var confirmDelay: TimeInterval = 2
        /// Without a registry entry: quiet time after a `Stop`.
        var quietWindowWithoutRegistry: TimeInterval = 5
        /// A registry that never moved after the `Stop` is treated as absent
        /// after this long.
        var staleRegistryGrace: TimeInterval = 10
        /// How long an uncertain end is held open for a report.
        var uncertainWindow: TimeInterval = 10 * 60
        var interruptGrace: TimeInterval = 2
        var failureConfirmWithoutRegistry: TimeInterval = 10
        var failureBusyCap: TimeInterval = 30
        var waitingDelay: TimeInterval = 60
        var waitingDelayWithoutRegistry: TimeInterval = 120
        /// How often to look at the registry while a turn runs (for Esc and
        /// waits) or while an end awaits confirmation.
        var runningPoll: TimeInterval = 2
        var confirmPoll: TimeInterval = 0.5

        static let standard = Timing()
    }

    static let producerVersion = "task-outcome/1"

    /// - Parameters:
    ///   - registry: the live process's registry entry for this session, or
    ///     nil when there is none (no registry, or the process is gone).
    ///   - payload: the session's status payload, for activity after a `Stop`.
    ///   - transcript: reads the transcript tail; called only for a turn that
    ///     looks interrupted.
    static func evaluate(
        _ ledger: TaskLedger,
        registry: TaskOutcomeRegistryReading?,
        payload: AgentStatusPayload?,
        now: Date,
        timing: Timing = .standard,
        transcript: () -> TaskTranscriptVerdict
    ) -> TaskOutcomeEvaluation {
        var evaluation = TaskOutcomeEvaluation()
        guard let task = ledger.task else { return evaluation }
        let base = TaskOutcome(
            kind: .completed, confidence: .high, sessionID: ledger.sessionID, taskKey: task.key,
            segment: task.segment, origin: task.origin, occurredAt: now,
            startedAt: task.segment == 0 ? task.startedAt : task.segmentStartedAt,
            endedAt: now, cwd: ledger.cwd, id: "")

        if !task.hasEnded {
            waiting(task, base: base, registry: registry, payload: payload, now: now, timing: timing, into: &evaluation)
        }

        if let failure = task.failure {
            failed(failure, base: base, registry: registry, now: now, timing: timing, into: &evaluation)
        } else if let stop = task.stop {
            if stop.isPaused {
                // Background agents report back as a prompt; the registry
                // is consulted only for a wait.
            } else if stop.isUncertain {
                uncertain(stop, base: base, endedAt: ledger.endedAt, registry: registry, payload: payload,
                          now: now, timing: timing, into: &evaluation)
            } else {
                stopped(stop, base: base, registry: registry, payload: payload, now: now, timing: timing, into: &evaluation)
            }
        } else {
            running(task, base: base, registry: registry, now: now, timing: timing, transcript: transcript, into: &evaluation)
        }
        return evaluation
    }

    // MARK: - Turn ended with Stop

    private static func stopped(
        _ stop: TaskLedgerStop, base: TaskOutcome, registry: TaskOutcomeRegistryReading?,
        payload: AgentStatusPayload?, now: Date, timing: Timing, into evaluation: inout TaskOutcomeEvaluation
    ) {
        var outcome = base
        outcome.occurredAt = stop.at
        outcome.endedAt = stop.at
        outcome.shellsStillRunning = stop.settledShells
        outcome.cronsArmed = stop.cronsArmed
        outcome.id = eventID(.completed, base, suffix: nil)

        if let registry, registry.isActive {
            // Busy or waiting, whatever its stamp: Claude Code keeps a busy
            // stamp from the turn's start for as long as it stays busy (C2),
            // so an old stamp is not a stale entry. A Stop hook continued the
            // turn, background work the Stop did not list still runs, or the
            // registry has not caught up yet. The next ledger event or the
            // registry's turn to idle decides.
            let catchingUp = now < stop.at.addingTimeInterval(timing.staleRegistryGrace)
            evaluation.check(at: now.addingTimeInterval(catchingUp ? timing.confirmPoll : timing.runningPoll))
            return
        }
        if let registry, let updated = registry.statusUpdatedAt,
           updated >= stop.at.addingTimeInterval(-timing.registrySkew) {
            let due = max(stop.at, updated).addingTimeInterval(timing.confirmDelay)
            if now >= due {
                outcome.confidence = .high
                evaluation.outcomes.append(outcome)
            } else {
                evaluation.check(at: due)
            }
            return
        }
        // No registry entry, or an idle one that has not moved since before
        // the Stop: a quiet window, restarted by any tool call after the Stop.
        let quiet = registry == nil ? timing.quietWindowWithoutRegistry : timing.staleRegistryGrace
        let due = (activity(after: stop.at, payload: payload) ?? stop.at).addingTimeInterval(quiet)
        if now >= due {
            outcome.confidence = .medium
            evaluation.outcomes.append(outcome)
        } else {
            evaluation.check(at: registry == nil ? due : min(due, now.addingTimeInterval(timing.confirmPoll)))
        }
    }

    private static func uncertain(
        _ stop: TaskLedgerStop, base: TaskOutcome, endedAt sessionEnd: Date?, registry: TaskOutcomeRegistryReading?,
        payload: AgentStatusPayload?, now: Date, timing: Timing, into evaluation: inout TaskOutcomeEvaluation
    ) {
        var outcome = base
        outcome.endedAt = stop.at
        outcome.confidence = .medium
        outcome.cronsArmed = stop.cronsArmed
        let stopMs = HistoryTime.ms(stop.at)
        if let sessionEnd, sessionEnd >= stop.at {
            // The session ended: nothing it started can report any more, and
            // nothing says the work was done.
            outcome.kind = .unresolved
            outcome.occurredAt = sessionEnd
            outcome.id = "task_unresolved|\(base.sessionID)|\(base.taskKey)|\(base.segment)|e\(stopMs)"
            evaluation.outcomes.append(outcome)
            return
        }
        if let registry, registry.isActive {
            // Something runs again (a revived subagent reaching the main
            // agent, a new turn): its report or Stop will move the ledger.
            evaluation.check(at: now.addingTimeInterval(timing.runningPoll))
            return
        }
        let lastActivity = activity(after: stop.at, payload: payload) ?? stop.at
        let due = lastActivity.addingTimeInterval(timing.uncertainWindow)
        guard now >= due else {
            evaluation.check(at: min(due, now.addingTimeInterval(timing.runningPoll)))
            return
        }
        outcome.kind = .uncertain
        outcome.occurredAt = due
        outcome.shellsStillRunning = stop.settledShells + stop.uncertainShells
        // A report after the window joins the same segment, and the task's
        // real end is then announced as Completed under the plain id.
        outcome.id = eventID(.uncertain, base, suffix: "w\(stopMs)")
        evaluation.outcomes.append(outcome)
    }

    // MARK: - Turn ended with StopFailure

    private static func failed(
        _ failure: TaskLedgerFailure, base: TaskOutcome, registry: TaskOutcomeRegistryReading?,
        now: Date, timing: Timing, into evaluation: inout TaskOutcomeEvaluation
    ) {
        var outcome = base
        outcome.kind = .failed
        outcome.occurredAt = failure.at
        outcome.endedAt = failure.at
        outcome.error = failure.error
        outcome.id = eventID(.failed, base, suffix: nil)

        let due: Date
        if let registry, registry.isActive {
            // Busy after a failure, whatever its stamp: background agents
            // keep it busy, or it has not caught up yet.
            due = failure.at.addingTimeInterval(timing.failureBusyCap)
            outcome.confidence = .medium
        } else if let registry, let updated = registry.statusUpdatedAt,
                  updated >= failure.at.addingTimeInterval(-timing.registrySkew) {
            due = max(failure.at, updated).addingTimeInterval(timing.confirmDelay)
            outcome.confidence = .high
        } else {
            due = failure.at.addingTimeInterval(timing.failureConfirmWithoutRegistry)
            outcome.confidence = .medium
        }
        if now >= due {
            evaluation.outcomes.append(outcome)
        } else {
            evaluation.check(at: min(due, now.addingTimeInterval(timing.runningPoll)))
        }
    }

    // MARK: - Turn running

    private static func running(
        _ task: TaskLedgerTask, base: TaskOutcome, registry: TaskOutcomeRegistryReading?, now: Date,
        timing: Timing, transcript: () -> TaskTranscriptVerdict, into evaluation: inout TaskOutcomeEvaluation
    ) {
        guard let registry else { return }
        guard registry.isIdle, let updated = registry.statusUpdatedAt else {
            evaluation.check(at: now.addingTimeInterval(timing.runningPoll))
            return
        }
        let promptMs = HistoryTime.ms(task.lastPromptAt)
        guard updated > task.lastPromptAt.addingTimeInterval(timing.registrySkew) else {
            // Idle and unmoved since the prompt (Claude Code marks a turn
            // busy before the prompt hook runs): no turn the registry saw, or
            // one cut off within a second. Stop watching it after a while
            // rather than polling until the next prompt.
            let due = task.lastPromptAt.addingTimeInterval(timing.staleRegistryGrace)
            guard now >= due else {
                evaluation.check(at: due)
                return
            }
            var outcome = base
            outcome.kind = .unresolved
            outcome.confidence = .medium
            outcome.id = "task_unresolved|\(base.sessionID)|\(base.taskKey)|\(base.segment)|\(promptMs)"
            evaluation.outcomes.append(outcome)
            return
        }
        // Idle since after the prompt, and no Stop or StopFailure: Esc (C3),
        // or a turn that ended without its hook landing.
        let due = updated.addingTimeInterval(timing.interruptGrace)
        guard now >= due else {
            evaluation.check(at: due)
            return
        }
        var outcome = base
        outcome.occurredAt = updated
        outcome.endedAt = updated
        switch transcript() {
        case .interrupted:
            outcome.kind = .interrupted
            outcome.confidence = .high
            outcome.id = eventID(.interrupted, base, suffix: String(promptMs))
        case .other, .unavailable:
            outcome.kind = .unresolved
            outcome.confidence = .medium
            outcome.id = "task_unresolved|\(base.sessionID)|\(base.taskKey)|\(base.segment)|\(promptMs)"
        }
        evaluation.outcomes.append(outcome)
    }

    // MARK: - Waiting

    private static func waiting(
        _ task: TaskLedgerTask, base: TaskOutcome, registry: TaskOutcomeRegistryReading?,
        payload: AgentStatusPayload?, now: Date, timing: Timing, into evaluation: inout TaskOutcomeEvaluation
    ) {
        let since: Date
        let due: Date
        var outcome = base
        outcome.kind = .waiting
        if let registry {
            guard registry.status == .waiting, let updated = registry.statusUpdatedAt else { return }
            let reason = ActiveAgentWaitingReason(registryValue: registry.waitingFor)
            // `dialog open` between turns is a command UI the user opened
            // (`/config`, a picker): not the work waiting on them. Mid-turn it
            // is Claude Code's own decision dialog.
            guard reason != .dialog || task.isRunning else { return }
            since = updated
            due = since.addingTimeInterval(timing.waitingDelay)
            outcome.confidence = .high
            outcome.waitingReason = reason
        } else {
            // The permission notice is still the payload's last word: no
            // tool call has run since (any would have rewritten it).
            guard task.isRunning, let notice = task.waitingNoticeAt,
                  let payload, payload.state == .waiting,
                  payload.updatedAt >= notice.addingTimeInterval(-1) else { return }
            since = notice
            due = since.addingTimeInterval(timing.waitingDelayWithoutRegistry)
            outcome.confidence = .medium
            outcome.waitingReason = .permission
        }
        guard now >= due else {
            evaluation.check(at: due)
            return
        }
        outcome.occurredAt = due
        outcome.startedAt = since
        outcome.endedAt = due
        // One per turn: Claude Code can re-stamp an unchanged status (C1a),
        // and a stamp-keyed id would announce the same prompt again.
        outcome.id = eventID(.waiting, base, suffix: String(HistoryTime.ms(task.lastPromptAt)))
        evaluation.outcomes.append(outcome)
    }

    // MARK: - Helpers

    /// A tool call after `date`: the payload was rewritten to `working` later
    /// than the hook that wrote `date` (the helper stamps both files with one
    /// clock reading; the payload keeps whole seconds).
    private static func activity(after date: Date, payload: AgentStatusPayload?) -> Date? {
        guard let payload, payload.state == .working,
              payload.updatedAt >= date.addingTimeInterval(1) else { return nil }
        return payload.updatedAt
    }

    /// `task_completed|<session>|<task>|<segment>` and so on: the dedup key.
    static func eventID(_ kind: TaskOutcome.Kind, _ base: TaskOutcome, suffix: String?) -> String {
        let name = kind.eventKind?.rawValue ?? "task_\(kind.rawValue)"
        var id = "\(name)|\(base.sessionID)|\(base.taskKey)|\(base.segment)"
        if let suffix { id += "|\(suffix)" }
        return id
    }
}
