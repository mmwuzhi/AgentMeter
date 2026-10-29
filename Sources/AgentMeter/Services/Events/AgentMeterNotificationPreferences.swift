import Foundation

/// Which event kinds become a system notification. Every event is recorded
/// either way (Dashboard history, unread marks); a kind turned off only skips
/// the banner, with `disabledByUser` as the reason.
///
/// The keys are `UserDefaults` booleans, read on every delivery, so a change
/// applies to the next event without a relaunch. They are a compatibility
/// contract like every `@AppStorage` key (docs/agent/ui-state.md). All three
/// default on (product decision at Phase 1a acceptance, 2026-10-20; the
/// waiting banner's 60-120 s delay belongs to its producer). Interrupted,
/// unknown, and kinds this build does not know are recorded only, with no
/// switch.
///
/// `showsSessionTitle` decides what a task banner calls the session, its
/// title (as the session list shows it) or its project and short id. On by
/// default since 2026-10-29, the user's choice: a short id named no session
/// they could find, and a click cannot jump into an editor's session, so the
/// text has to say which one it was. That supersedes the 2026-10-20 short-id
/// default (without a custom title the title is Claude's summary of the
/// first prompt, and banners can show on the lock screen); a stored false
/// still wins. It is read when the event is built, so it applies from the
/// next one; events already recorded keep their text.
///
/// `notifiesHeadlessRuns` decides whether a headless run's outcomes are
/// announced like a person's session's (banner by the switches above, listed
/// and counted in the menu) or kept for the history only
/// (`TaskOutcomeAnnouncement.Reason.headlessRun`). Off by default
/// (2026-10-29): one session's batch script ran a `claude -p` per case and
/// each one's end posted a banner. Read when an outcome is submitted, so it
/// applies from the next one; recorded events keep their delivery.
struct AgentMeterNotificationPreferences: Equatable, Sendable {
    static let taskCompletedKey = "taskCompletedNotificationsEnabled"
    static let taskFailedKey = "taskFailedNotificationsEnabled"
    static let taskWaitingKey = "taskWaitingNotificationsEnabled"
    static let showsSessionTitleKey = "taskNotificationsShowSessionTitle"
    static let notifiesHeadlessRunsKey = "taskNotificationsIncludeHeadlessRuns"

    var taskCompleted: Bool
    var taskFailed: Bool
    var taskWaiting: Bool
    var showsSessionTitle: Bool
    var notifiesHeadlessRuns: Bool

    /// The defaults live here and nowhere else.
    init(taskCompleted: Bool = true, taskFailed: Bool = true, taskWaiting: Bool = true,
         showsSessionTitle: Bool = true, notifiesHeadlessRuns: Bool = false) {
        self.taskCompleted = taskCompleted
        self.taskFailed = taskFailed
        self.taskWaiting = taskWaiting
        self.showsSessionTitle = showsSessionTitle
        self.notifiesHeadlessRuns = notifiesHeadlessRuns
    }

    init(defaults: UserDefaults) {
        self.init(stored: defaults.object(forKey:))
    }

    /// A missing value, or one of the wrong type, keeps the default.
    init(stored value: (String) -> Any?) {
        self.init()
        taskCompleted = value(Self.taskCompletedKey) as? Bool ?? taskCompleted
        taskFailed = value(Self.taskFailedKey) as? Bool ?? taskFailed
        taskWaiting = value(Self.taskWaitingKey) as? Bool ?? taskWaiting
        showsSessionTitle = value(Self.showsSessionTitleKey) as? Bool ?? showsSessionTitle
        notifiesHeadlessRuns = value(Self.notifiesHeadlessRunsKey) as? Bool ?? notifiesHeadlessRuns
    }

    func notifies(_ kind: AgentMeterEventKind) -> Bool {
        switch kind {
        case .taskCompleted: taskCompleted
        case .taskFailed: taskFailed
        case .taskWaiting: taskWaiting
        default: false
        }
    }
}
