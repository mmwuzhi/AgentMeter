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
struct AgentMeterNotificationPreferences: Equatable, Sendable {
    static let taskCompletedKey = "taskCompletedNotificationsEnabled"
    static let taskFailedKey = "taskFailedNotificationsEnabled"
    static let taskWaitingKey = "taskWaitingNotificationsEnabled"

    var taskCompleted: Bool
    var taskFailed: Bool
    var taskWaiting: Bool

    /// The defaults live here and nowhere else.
    init(taskCompleted: Bool = true, taskFailed: Bool = true, taskWaiting: Bool = true) {
        self.taskCompleted = taskCompleted
        self.taskFailed = taskFailed
        self.taskWaiting = taskWaiting
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
