import Foundation

// The turn ledger: one small file per Claude session
// (`agent-status/turns/<session>.json`), written by the hook helper on the
// main agent's turn events and read by AgentMeter's task outcome detector.
//
// The status payload beside it says what the row shows now and is rewritten
// by every agent's tool call. The ledger says which task the session is on
// and how its last turn ended, and only the main thread's events move it
// (plus one fact from any agent: which background shell it launched), so a
// subagent's or workflow agent's tool calls never touch it.
//
// What it is built on, measured on Claude Code 2.1.301 (POC C1–C3, C1d):
// - Every main event carries `prompt_id`, but each report from background
//   work arrives as a new `UserPromptSubmit` with a new `prompt_id` and a
//   prompt that opens with `<task-notification` or `<agent-message`. The
//   task is the human prompt's; reports join it.
// - `Stop` lists `background_tasks`. Subagents and workflows in that list
//   report back later (a pause). A background shell that ends wakes the agent
//   that started it: a subagent that backgrounded one is revived and reports
//   again (C1a), and the main agent gets a notification. Nothing in the
//   `Stop` input says when a shell started or whose it is. The launching
//   `Bash` call's `PostToolUse` does: its `tool_response` carries
//   `backgroundTaskId`, the same id the `Stop` list shows, and the input
//   carries the launching agent's `agent_id` (C1d).
//
// No prompt, message or tool content is kept: the prompt is only matched
// against a tag prefix, in memory.

/// What a user prompt looks like, decided from its first characters only.
public enum TaskLedgerPromptShape: String, Codable, Sendable, Equatable {
    /// A person's prompt.
    case human
    /// A report from background work: Claude Code's own wrappers.
    case report
    /// Opens with some other `<tag`: a report only while the task waits on
    /// background work (Claude Code treats every such prefix as non-human,
    /// but a person can paste markup too).
    case tagged

    /// Tags Claude Code wraps background reports in (2.1.301): a finished
    /// task's notification, a subagent's hand-back or another session's
    /// message.
    public static let reportTags: Set<String> = ["task-notification", "agent-message", "teammate-message"]

    public static func classify(_ prompt: String?) -> TaskLedgerPromptShape {
        guard let prompt else { return .human }
        let head = prompt.drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).prefix(64)
        guard head.first == "<" else { return .human }
        let name = head.dropFirst().prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        // `^<[a-z][\w-]*[\s>]`, the shape Claude Code itself calls non-human.
        guard let first = name.first, first.isLowercase,
              let after = head.dropFirst(1 + name.count).first,
              after == ">" || after.isWhitespace else { return .human }
        return reportTags.contains(String(name)) ? .report : .tagged
    }
}

/// One hook event as the ledger sees it.
public struct TaskLedgerEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The main agent's `UserPromptSubmit`.
        case prompt(promptID: String?, shape: TaskLedgerPromptShape)
        /// The main agent's `Stop`.
        case stop(backgroundTasks: [HookBackgroundTaskList.Entry], cronsArmed: Bool, stopHookActive: Bool)
        /// The main agent's `StopFailure`: the turn ended on an API error.
        /// `error` is Claude Code's error kind (`rate_limit`, …), reduced to
        /// a short token.
        case stopFailure(error: String?)
        /// A `Notification` that asks the user for something: a permission
        /// prompt or an MCP elicitation, from any agent.
        case waitingNotice
        case sessionEnd(reason: String?)
        /// A `Bash` call (any agent's) that left a shell running in the
        /// background; `agentID` nil is the main agent.
        case backgroundLaunch(taskID: String, agentID: String?)
    }

    public var kind: Kind
    public var at: Date
    public var cwd: String?
    public var transcriptPath: String?

    public init(kind: Kind, at: Date, cwd: String? = nil, transcriptPath: String? = nil) {
        self.kind = kind
        self.at = at
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }

    /// Notification types that mean the session waits on the user.
    public static let waitingNotificationTypes: Set<String> = ["permission_prompt", "elicitation_dialog"]

    /// The ledger event a hook input stands for, or nil when the ledger has
    /// no use for it: anything a subagent fires except a background launch,
    /// tool calls that launched nothing, events it does not know.
    public static func from(
        hookEventName: String?,
        agentID: String?,
        promptID: String?,
        prompt: String?,
        backgroundTasks: HookBackgroundTaskList?,
        sessionCronCount: Int?,
        stopHookActive: Bool?,
        error: String?,
        notificationType: String?,
        reason: String?,
        backgroundTaskID: String?,
        cwd: String?,
        transcriptPath: String?,
        at: Date
    ) -> TaskLedgerEvent? {
        let agentID = agentID.flatMap { $0.isEmpty ? nil : $0 }
        let isMain = agentID == nil
        let kind: Kind
        switch hookEventName {
        case "UserPromptSubmit" where isMain:
            kind = .prompt(promptID: token(promptID, limit: 128), shape: .classify(prompt))
        case "Stop" where isMain:
            kind = .stop(
                backgroundTasks: backgroundTasks?.entries ?? [],
                cronsArmed: (sessionCronCount ?? 0) > 0,
                stopHookActive: stopHookActive ?? false
            )
        case "StopFailure" where isMain:
            kind = .stopFailure(error: token(error, limit: 32))
        case "Notification" where waitingNotificationTypes.contains(notificationType ?? ""):
            kind = .waitingNotice
        case "SessionEnd":
            kind = .sessionEnd(reason: token(reason, limit: 32))
        case "PostToolUse":
            guard let taskID = token(backgroundTaskID, limit: 64) else { return nil }
            kind = .backgroundLaunch(taskID: taskID, agentID: token(agentID, limit: 64))
        default:
            return nil
        }
        return TaskLedgerEvent(kind: kind, at: at, cwd: cwd, transcriptPath: transcriptPath)
    }

    /// Ids and enum-like values only: `[A-Za-z0-9_.:-]`, bounded. Anything
    /// else is not one and is dropped rather than stored.
    static func token(_ value: String?, limit: Int) -> String? {
        guard let value, !value.isEmpty, value.count <= limit,
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0)) })
        else { return nil }
        return value
    }
}

/// How the main agent's last turn ended with `Stop`, reduced to counts.
public struct TaskLedgerStop: Codable, Sendable, Equatable {
    public var at: Date
    /// Subagents and workflows still in flight: they report back, so the
    /// task is paused, not over (C1, C2).
    public var blocking: Int
    /// Background shells and monitors an earlier task started (a dev server
    /// left running): they do not hold this task open.
    public var settledShells: Int
    /// Background shells and monitors that may still bring this task back:
    /// started during this task, by the main agent or a subagent, or with no
    /// launch on record and first listed during this task. When one ends,
    /// the agent that started it is woken and reports.
    public var uncertainShells: Int
    /// Background work of a kind the ledger does not know (teammate, cloud
    /// session, MCP task, …): treated like an uncertain shell.
    public var otherTasks: Int
    /// The session has scheduled prompts (`/loop`, crons), whose turns look
    /// like a person's.
    public var cronsArmed: Bool
    /// This `Stop` ended a turn a Stop hook had continued.
    public var stopHookActive: Bool

    public init(at: Date, blocking: Int = 0, settledShells: Int = 0, uncertainShells: Int = 0,
                otherTasks: Int = 0, cronsArmed: Bool = false, stopHookActive: Bool = false) {
        self.at = at
        self.blocking = blocking
        self.settledShells = settledShells
        self.uncertainShells = uncertainShells
        self.otherTasks = otherTasks
        self.cronsArmed = cronsArmed
        self.stopHookActive = stopHookActive
    }

    /// Background agents will report: paused.
    public var isPaused: Bool { blocking > 0 }
    /// Nothing known to report, but something that might.
    public var isUncertain: Bool { blocking == 0 && (uncertainShells > 0 || otherTasks > 0) }
    /// Still waiting on background work in some way.
    public var awaitsBackground: Bool { isPaused || isUncertain }
}

/// The main agent's turn ended on an API error.
public struct TaskLedgerFailure: Codable, Sendable, Equatable {
    public var at: Date
    public var error: String?

    public init(at: Date, error: String?) {
        self.at = at
        self.error = error
    }
}

/// The task a session is on, or last was.
public struct TaskLedgerTask: Codable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable {
        /// Opened by a person's prompt.
        case human
        /// Opened by a report with no task to join (the ledger was new or
        /// swept): no person asked for it.
        case report
    }

    /// The opening prompt's `prompt_id`; `<session>|<ms>` without one.
    public var key: String
    public var origin: Origin
    public var startedAt: Date
    /// 0 for the run the prompt started; +1 each time a report reopens the
    /// task after it had ended (an earlier task's shell finished and woke the
    /// main agent, a failed turn's background agent reported). A report after
    /// an uncertain end (a shell this task started) joins the same segment.
    public var segment: Int
    public var segmentStartedAt: Date
    /// The latest prompt of either kind: the current turn's start.
    public var lastPromptAt: Date
    public var reports: Int
    /// A `Stop` listed a subagent or workflow at some point.
    public var hadBackgroundAgents: Bool
    /// Set when the latest turn ended with `Stop`; cleared by the next prompt.
    public var stop: TaskLedgerStop?
    /// Set when the latest turn ended with `StopFailure`.
    public var failure: TaskLedgerFailure?
    /// The latest permission or elicitation notice in the current turn.
    public var waitingNoticeAt: Date?

    public init(key: String, origin: Origin, startedAt: Date) {
        self.key = key
        self.origin = origin
        self.startedAt = startedAt
        self.segment = 0
        self.segmentStartedAt = startedAt
        self.lastPromptAt = startedAt
        self.reports = 0
        self.hadBackgroundAgents = false
    }

    /// The current turn has not ended.
    public var isRunning: Bool { stop == nil && failure == nil }
    /// Ended, and nothing known or suspected will report back.
    public var hasEnded: Bool { failure != nil || (stop.map { !$0.awaitsBackground } ?? false) }
}

/// A background shell or monitor and the agent that started it.
public struct TaskLedgerBackgroundLaunch: Codable, Sendable, Equatable {
    public var taskID: String
    /// Nil: the main agent, or not known (`observedOnly`).
    public var agentID: String?
    /// The task the session was on when it started, or, for one only
    /// observed, the task whose `Stop` first listed it.
    public var taskKey: String?
    public var at: Date
    /// Never seen launching: first listed by a `Stop`. Nil reads as false.
    public var observedOnly: Bool?

    public init(taskID: String, agentID: String?, taskKey: String?, at: Date, observedOnly: Bool? = nil) {
        self.taskID = taskID
        self.agentID = agentID
        self.taskKey = taskKey
        self.at = at
        self.observedOnly = observedOnly
    }
}

public struct TaskLedger: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public var version: Int
    public var sessionID: String
    public var cwd: String?
    public var transcriptPath: String?
    /// Bumps with every recorded event, so a reader can tell "nothing
    /// happened" from "something happened and was undone".
    public var sequence: Int
    public var updatedAt: Date
    public var task: TaskLedgerTask?
    /// Newest last, at most `TaskLedgerReducer.maximumBackgroundLaunches`.
    public var backgroundLaunches: [TaskLedgerBackgroundLaunch]
    public var endedAt: Date?
    public var endReason: String?

    public init(sessionID: String, updatedAt: Date) {
        self.version = Self.formatVersion
        self.sessionID = sessionID
        self.sequence = 0
        self.updatedAt = updatedAt
        self.backgroundLaunches = []
    }
}

/// The ledger's state machine: pure, so the helper and the tests run the
/// same code.
public enum TaskLedgerReducer {
    public static let maximumBackgroundLaunches = 64
    public static let maximumPathLength = 4096
    /// How long after an uncertain end a prompt that merely opens with some
    /// `<tag` still counts as a report (Claude Code's own report tags always
    /// do). Matches the detector's observation window: past it the end has
    /// been announced, and such a prompt is a person's.
    public static let taggedJoinWindow: TimeInterval = 10 * 60

    /// The ledger after `event`, or nil when the event changes nothing (a
    /// `Stop` with no task to end, for one) and nothing should be written.
    public static func apply(_ event: TaskLedgerEvent, to existing: TaskLedger?, sessionID: String) -> TaskLedger? {
        var ledger = existing ?? TaskLedger(sessionID: sessionID, updatedAt: event.at)
        switch event.kind {
        case let .prompt(promptID, shape):
            let joinsTask: Bool
            switch shape {
            case .report: joinsTask = true
            case .human: joinsTask = false
            case .tagged:
                let stop = ledger.task?.stop
                joinsTask = (stop?.isPaused ?? false)
                    || (stop.map { $0.isUncertain && event.at.timeIntervalSince($0.at) <= taggedJoinWindow } ?? false)
            }
            if joinsTask, var task = ledger.task {
                if !task.isRunning {
                    // Back from a pause or an uncertain end: the same run. Back
                    // from a real end: the task reopens as a new segment.
                    if task.hasEnded {
                        task.segment += 1
                        task.segmentStartedAt = event.at
                    }
                    task.stop = nil
                    task.failure = nil
                }
                task.reports += 1
                task.lastPromptAt = event.at
                task.waitingNoticeAt = nil
                ledger.task = task
            } else {
                let key = promptID ?? "\(sessionID)|\(Int64((event.at.timeIntervalSince1970 * 1000).rounded()))"
                ledger.task = TaskLedgerTask(key: key, origin: joinsTask ? .report : .human, startedAt: event.at)
            }
        case let .stop(backgroundTasks, cronsArmed, stopHookActive):
            guard var task = ledger.task else { return nil }
            var stop = TaskLedgerStop(at: event.at, cronsArmed: cronsArmed, stopHookActive: stopHookActive)
            var unattributed: [TaskLedgerBackgroundLaunch] = []
            for entry in backgroundTasks {
                switch entry.type {
                case "subagent", "workflow":
                    stop.blocking += 1
                case "shell", "monitor":
                    if let launch = entry.id.flatMap({ id in ledger.backgroundLaunches.last { $0.taskID == id } }) {
                        // Whoever started it: a shell this task started wakes
                        // the task when it ends — its subagent is revived
                        // (C1a), or the main agent gets the notification (81%
                        // of main shells still running at a turn end did, in
                        // 45 days of local transcripts).
                        if launch.taskKey == task.key {
                            stop.uncertainShells += 1
                        } else {
                            stop.settledShells += 1
                        }
                    } else {
                        // No launch on record (started before the ledger,
                        // or by a tool whose response names no task):
                        // assume this task's. It is remembered as seen
                        // here, so a later task finds it settled.
                        stop.uncertainShells += 1
                        if let id = entry.id.flatMap({ TaskLedgerEvent.token($0, limit: 64) }) {
                            unattributed.append(TaskLedgerBackgroundLaunch(
                                taskID: id, agentID: nil, taskKey: task.key, at: event.at, observedOnly: true))
                        }
                    }
                default:
                    stop.otherTasks += 1
                }
            }
            if stop.blocking > 0 { task.hadBackgroundAgents = true }
            appendLaunches(unattributed, to: &ledger)
            task.stop = stop
            task.failure = nil
            ledger.task = task
        case let .stopFailure(error):
            guard var task = ledger.task else { return nil }
            task.failure = TaskLedgerFailure(at: event.at, error: error)
            task.stop = nil
            ledger.task = task
        case .waitingNotice:
            guard var task = ledger.task else { return nil }
            task.waitingNoticeAt = event.at
            ledger.task = task
        case let .sessionEnd(reason):
            guard existing != nil else { return nil }
            ledger.endedAt = event.at
            ledger.endReason = reason
        case let .backgroundLaunch(taskID, agentID):
            appendLaunches([TaskLedgerBackgroundLaunch(taskID: taskID, agentID: agentID, taskKey: ledger.task?.key, at: event.at)],
                           to: &ledger)
        }
        // Where the session is: from the main thread's own events only. A
        // subagent's notice or launch may come from a worktree of its own.
        switch event.kind {
        case .prompt, .stop, .stopFailure, .sessionEnd:
            if let cwd = event.cwd, !cwd.isEmpty { ledger.cwd = String(cwd.prefix(maximumPathLength)) }
            if let path = event.transcriptPath, !path.isEmpty {
                ledger.transcriptPath = String(path.prefix(maximumPathLength))
            }
        case .waitingNotice, .backgroundLaunch:
            break
        }
        ledger.version = TaskLedger.formatVersion
        ledger.sequence += 1
        ledger.updatedAt = event.at
        return ledger
    }

    /// Newest last, one entry per task id, at most `maximumBackgroundLaunches`.
    private static func appendLaunches(_ launches: [TaskLedgerBackgroundLaunch], to ledger: inout TaskLedger) {
        for launch in launches {
            ledger.backgroundLaunches.removeAll { $0.taskID == launch.taskID }
            ledger.backgroundLaunches.append(launch)
        }
        if ledger.backgroundLaunches.count > maximumBackgroundLaunches {
            ledger.backgroundLaunches.removeFirst(ledger.backgroundLaunches.count - maximumBackgroundLaunches)
        }
    }
}
