import Foundation

/// How a session is named in its notification: what the popover row shows.
struct TaskSessionLabel: Sendable, Equatable {
    var project: String?
    /// Custom or generated session title; untrusted, sanitized here.
    var title: String?
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
    }

    /// The reasons an outcome is recorded for the history only: nothing asks
    /// the user to look at it, so the menu neither lists nor counts it and it
    /// is recorded read (`TaskEventAttention`). `backgroundShellRunning` is
    /// not one of them: an unconfirmed task is listed, just never posted.
    static let historyOnlyReasons: Set<String> = [
        Reason.beforeLaunch, Reason.reportOrigin, Reason.cronsArmed,
        Reason.belowMinimumDuration, Reason.notAnnounced,
    ]

    static func intent(for outcome: TaskOutcome, launchedAt: Date) -> AgentMeterDeliveryIntent {
        if outcome.occurredAt < launchedAt.addingTimeInterval(-beforeLaunchSlack) {
            return .recordOnly(reason: Reason.beforeLaunch)
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
    /// - Parameter showsSessionTitle: name the session by its title instead
    ///   of its short id. Off by default: without a custom title it is
    ///   Claude's summary of the first prompt, and banners show on the lock
    ///   screen. The switch is `AgentMeterNotificationPreferences.showsSessionTitle`.
    static func event(for outcome: TaskOutcome, label: TaskSessionLabel?, discoveredAt: Date,
                      showsSessionTitle: Bool = false) -> AgentMeterEvent? {
        guard let kind = outcome.kind.eventKind else { return nil }
        let project = SessionLabel.title(label?.project)
            ?? outcome.cwd.flatMap { SessionLabel.title(URL(fileURLWithPath: $0).lastPathComponent) }
            ?? "Claude"
        let shortID = "Session \(outcome.sessionID.prefix(8))"
        let session = showsSessionTitle ? (SessionLabel.title(label?.title) ?? shortID) : shortID
        let title: String
        let detail: String
        switch outcome.kind {
        case .completed:
            title = "\(project) finished"
            var parts = [outcome.isReopened ? "Follow-up · \(format(outcome.duration)) run" : "\(format(outcome.duration)) run"]
            if outcome.shellsStillRunning > 0 {
                let count = outcome.shellsStillRunning
                parts.append("\(count) background \(count == 1 ? "shell" : "shells") still running")
            }
            detail = parts.joined(separator: " · ")
        case .failed:
            title = "\(project) failed"
            detail = "\(errorText(outcome.error)) · after \(format(outcome.duration))"
        case .waiting:
            title = "\(project) needs input"
            let lead = switch outcome.waitingReason {
            case .input: "Waiting for your answer"
            case .dialog: "Waiting for your decision"
            case .permission, nil: "Waiting for permission"
            }
            detail = "\(lead) · \(format(outcome.duration))"
        case .uncertain:
            // What was seen, when: the shell may have ended since without a
            // hook to say so (docs/agent/ui-state.md, known limit).
            title = "\(project) task status unconfirmed"
            let count = outcome.shellsStillRunning
            detail = "\(count) background \(count == 1 ? "task" : "tasks") running at the last check · after \(format(outcome.duration))"
        case .interrupted:
            title = "\(project) interrupted"
            detail = "Stopped after \(format(outcome.duration))"
        case .unresolved:
            return nil
        }
        return AgentMeterEvent(
            id: outcome.id,
            kind: kind,
            occurredAt: outcome.occurredAt,
            discoveredAt: discoveredAt,
            subject: AgentMeterEventSubject(
                provider: Provider.claude.rawValue, sessionID: outcome.sessionID,
                taskKey: outcome.taskKey, projectPath: outcome.cwd),
            content: AgentMeterEventContent(
                title: title,
                body: "\(session)\n\(detail)",
                // One banner per task: a wait, then the end, replace each other.
                notificationIdentifier: "agentmeter.task.\(outcome.sessionID).\(outcome.taskKey)",
                threadIdentifier: "agentmeter.task.\(outcome.cwd ?? outcome.sessionID)"),
            producerVersion: TaskOutcomeDetector.producerVersion)
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
