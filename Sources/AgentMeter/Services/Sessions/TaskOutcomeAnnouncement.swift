import Foundation

/// How a session is named in its notification: what the popover row shows.
struct TaskSessionLabel: Sendable, Equatable {
    var project: String?
    /// Custom or generated session title; untrusted, sanitized here.
    var title: String?
}

extension TaskSessionLabel {
    /// Names the outcome's session the way the session list does, when its
    /// event is recorded: the live row's title (`ActiveAgentSession
    /// .displayTitle`, what the row shows), else the title in the session's
    /// own transcript read by the rows' parser, else none. Matched by session
    /// id only and never invented; the transcript is read off the main actor.
    @MainActor
    static func resolve(
        for outcome: TaskOutcome, rows: [ActiveAgent],
        transcriptTitle: @Sendable (_ path: String, _ sessionID: String) async -> String? = TaskSessionLabel.transcriptTitle
    ) async -> TaskSessionLabel {
        let session = rows.lazy.compactMap(\.session).first { $0.id == outcome.sessionID }
        var title = session?.displayTitle
        if title == nil, let path = outcome.transcriptPath {
            title = SessionLabel.title(await transcriptTitle(path, outcome.sessionID))
        }
        return TaskSessionLabel(project: session?.displayProject, title: title)
    }

    /// The title in the transcript at `path`, only when the file is that
    /// session's own (`<session id>.jsonl`, a regular file): a subagent's
    /// transcript (`agent-<id>.jsonl`) or another session's never names it.
    nonisolated static func transcriptTitle(path: String, sessionID: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.pathExtension == "jsonl", !sessionID.isEmpty,
              url.deletingPathExtension().lastPathComponent == sessionID,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return await ActiveAgentService.claudeTranscriptTitle(at: url)
    }
}

/// Hands the monitor's outcomes to the event path one at a time, in the
/// order the monitor found them. Naming a session can wait on a transcript
/// read (`TaskSessionLabel.resolve`); with a task per pass, a wait found
/// first could be submitted after the same task's end, and its "Needs input"
/// banner would replace "Finished" under the identifier they share.
@MainActor
final class TaskOutcomeQueue {
    private let continuation: AsyncStream<[TaskOutcome]>.Continuation
    private let consumer: Task<Void, Never>

    init(handle: @escaping @MainActor (TaskOutcome) async -> Void) {
        let (stream, continuation) = AsyncStream<[TaskOutcome]>.makeStream()
        self.continuation = continuation
        consumer = Task { @MainActor in
            for await outcomes in stream {
                for outcome in outcomes { await handle(outcome) }
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// From any thread: the monitor calls it on its own queue.
    nonisolated func enqueue(_ outcomes: [TaskOutcome]) {
        continuation.yield(outcomes)
    }
}

/// Turns a `TaskOutcome` into the event `NotificationManager.submit` records,
/// and decides whether it is announced or only recorded. The text names the
/// project, the session and how long the task ran; never a prompt, an
/// assistant message or error details (design 5.9 F).
enum TaskOutcomeAnnouncement {
    /// Shorter tasks are recorded, not announced: slash commands and quick
    /// answers, which the user is still watching.
    static let minimumDuration: TimeInterval = 60
    /// An outcome older than launch by more than this happened while
    /// AgentMeter was not running: recorded, not announced.
    static let beforeLaunchSlack: TimeInterval = 120

    enum Reason {
        static let beforeLaunch = "beforeLaunch"
        /// The task was opened by a background report, not a person.
        static let reportOrigin = "reportOrigin"
        /// The session has scheduled prompts, whose turns look like a person's.
        static let cronsArmed = "cronsArmed"
        static let belowMinimumDuration = "belowMinimumDuration"
        /// Interruptions are the user's own doing; recorded only.
        static let notAnnounced = "notAnnounced"
        /// Stopped with a background shell of its own still running: not
        /// known to be finished, so not announced as such.
        static let backgroundShellRunning = "backgroundShellRunning"
        /// A headless run (`TaskSessionLaunch.headless`: `claude -p`, the
        /// Agent SDK, a Claude Code another session or a script started),
        /// with headless runs switched off: whoever started it reads its
        /// result, nobody waits on a banner (2026-10-29: a batch of such runs
        /// from one session's script posted a banner each).
        static let headlessRun = "headlessRun"
    }

    /// The reasons an outcome is recorded for the history only: nothing asks
    /// the user to look at it, so the menu neither lists nor counts it, and
    /// the log keeps and drops it like a read event without marking it read
    /// (`TaskEventAttention`). `backgroundShellRunning` is not one of them:
    /// an unconfirmed task is listed, just never posted.
    static let historyOnlyReasons: Set<String> = [
        Reason.beforeLaunch, Reason.reportOrigin, Reason.cronsArmed,
        Reason.belowMinimumDuration, Reason.notAnnounced, Reason.headlessRun,
    ]

    /// - Parameter notifiesHeadlessRuns: the user's switch
    ///   (`AgentMeterNotificationPreferences.notifiesHeadlessRuns`). Off, a
    ///   headless run's every outcome, a failure or a wait included, is
    ///   history only; on, it follows the same rules as a person's session.
    ///   A session Claude Code does not describe (an older build, no hook
    ///   value and no registry entry) is taken for a person's.
    static func intent(for outcome: TaskOutcome, launchedAt: Date,
                       notifiesHeadlessRuns: Bool = false) -> AgentMeterDeliveryIntent {
        if outcome.occurredAt < launchedAt.addingTimeInterval(-beforeLaunchSlack) {
            return .recordOnly(reason: Reason.beforeLaunch)
        }
        if outcome.launch == .headless, !notifiesHeadlessRuns, outcome.kind != .unresolved {
            return .recordOnly(reason: Reason.headlessRun)
        }
        switch outcome.kind {
        case .completed:
            if outcome.origin == .report { return .recordOnly(reason: Reason.reportOrigin) }
            if outcome.cronsArmed { return .recordOnly(reason: Reason.cronsArmed) }
            if outcome.duration < minimumDuration { return .recordOnly(reason: Reason.belowMinimumDuration) }
            return .notify
        case .failed, .waiting:
            return .notify
        case .uncertain:
            return .recordOnly(reason: Reason.backgroundShellRunning)
        case .interrupted, .unresolved:
            return .recordOnly(reason: Reason.notAnnounced)
        }
    }

    /// Nil for an outcome that is not an event (`unresolved`).
    ///
    /// The status leads the banner's title, so truncation keeps it:
    /// "Finished · <session title>" over "<project> · Claude Code ·
    /// <short id>", or without a title "Finished · <project>" over "Session
    /// <short id>"; the second body line is the run time or what it waits
    /// for. A run a script started says "Headless run" (`TaskSessionLaunch`).
    /// The resolved title is kept on the subject either way, for the menu.
    ///
    /// - Parameter showsSessionTitle: name the session by its title in the
    ///   banner. On by default since 2026-10-29 (the user's choice: a short id
    ///   names no session they know). Without a custom title it is Claude's
    ///   summary of the first prompt, and banners can show on the lock
    ///   screen; the switch is `AgentMeterNotificationPreferences.showsSessionTitle`.
    static func event(for outcome: TaskOutcome, label: TaskSessionLabel?, discoveredAt: Date,
                      showsSessionTitle: Bool = true) -> AgentMeterEvent? {
        guard let kind = outcome.kind.eventKind else { return nil }
        let project = SessionLabel.title(label?.project)
            ?? outcome.cwd.flatMap { SessionLabel.title(URL(fileURLWithPath: $0).lastPathComponent) }
            ?? "Claude"
        let shortID = String(outcome.sessionID.prefix(8))
        let sessionTitle = SessionLabel.title(label?.title)
        let headless = outcome.launch == .headless
        let status: String
        let detail: String
        switch outcome.kind {
        case .completed:
            status = "Finished"
            var parts = [outcome.isReopened ? "Follow-up · \(format(outcome.duration)) run" : "\(format(outcome.duration)) run"]
            if outcome.shellsStillRunning > 0 {
                let count = outcome.shellsStillRunning
                parts.append("\(count) background \(count == 1 ? "shell" : "shells") still running")
            }
            detail = parts.joined(separator: " · ")
        case .failed:
            status = "Failed"
            detail = "\(errorText(outcome.error)) · after \(format(outcome.duration))"
        case .waiting:
            status = "Needs input"
            let lead = switch outcome.waitingReason {
            case .input: "Waiting for your answer"
            case .dialog: "Waiting for your decision"
            case .permission, nil: "Waiting for permission"
            }
            detail = "\(lead) · \(format(outcome.duration))"
        case .uncertain:
            // What was seen, when: the shell may have ended since without a
            // hook to say so (docs/agent/ui-state.md, known limit).
            status = "Status unconfirmed"
            let count = outcome.shellsStillRunning
            detail = "\(count) background \(count == 1 ? "task" : "tasks") running at the last check · after \(format(outcome.duration))"
        case .interrupted:
            status = "Interrupted"
            detail = "Stopped after \(format(outcome.duration))"
        case .unresolved:
            return nil
        }
        let title: String
        let identity: String
        if showsSessionTitle, let sessionTitle {
            title = "\(status) · \(sessionTitle)"
            identity = "\(project) · \(headless ? "Headless run" : "Claude Code") · \(shortID)"
        } else {
            title = "\(status) · \(project)"
            identity = "Session \(shortID)" + (headless ? " · Headless run" : "")
        }
        return AgentMeterEvent(
            id: outcome.id,
            kind: kind,
            occurredAt: outcome.occurredAt,
            discoveredAt: discoveredAt,
            subject: AgentMeterEventSubject(
                provider: Provider.claude.rawValue, sessionID: outcome.sessionID,
                taskKey: outcome.taskKey, projectPath: outcome.cwd,
                sessionTitle: sessionTitle, sessionKind: outcome.launch?.rawValue),
            content: AgentMeterEventContent(
                title: title,
                body: "\(identity)\n\(detail)",
                // One banner per task: a wait, then the end, replace each other.
                notificationIdentifier: "agentmeter.task.\(outcome.sessionID).\(outcome.taskKey)"),
            producerVersion: TaskOutcomeDetector.producerVersion)
    }

    /// What the app does with each outcome, in `TaskOutcomeQueue` order:
    /// names the session, builds the event with the title switch read now,
    /// and submits it.
    @MainActor
    static func announce(
        _ outcome: TaskOutcome, rows: [ActiveAgent], manager: NotificationManager, launchedAt: Date,
        defaults: UserDefaults = .standard, now: () -> Date = Date.init,
        transcriptTitle: @Sendable (_ path: String, _ sessionID: String) async -> String? = TaskSessionLabel.transcriptTitle
    ) async {
        let label = await TaskSessionLabel.resolve(for: outcome, rows: rows, transcriptTitle: transcriptTitle)
        let preferences = AgentMeterNotificationPreferences(defaults: defaults)
        guard let event = event(for: outcome, label: label, discoveredAt: now(),
                                showsSessionTitle: preferences.showsSessionTitle) else { return }
        await manager.submit(event, intent: intent(for: outcome, launchedAt: launchedAt,
                                                   notifiesHeadlessRuns: preferences.notifiesHeadlessRuns))
    }

    /// Claude Code's `StopFailure` error kinds, in words. Unknown kinds read
    /// as a plain API error rather than showing an unvetted token.
    static func errorText(_ error: String?) -> String {
        switch error {
        case "rate_limit": "Rate limit"
        case "overloaded": "API overloaded"
        case "billing_error": "Billing error"
        case "authentication_failed": "Authentication failed"
        case "invalid_request": "Invalid request"
        case "server_error": "Server error"
        case "max_output_tokens": "Output limit reached"
        default: "API error"
        }
    }

    /// "45s", "12m", "1h 5m".
    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
