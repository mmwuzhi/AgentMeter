import Foundation

// What the menu shows of the task events (`TaskOutcomeAnnouncement` records
// them through `NotificationManager.submit`): one item per task, its latest
// status, and whether the user still has to look at it. Pure; the feed
// (`TaskEventFeed`) reads the store and the view only draws.
//
// Three things stay apart:
//  * the status, which is what the event says happened and never changes
//    (an unconfirmed task stays unconfirmed when the user marks it read);
//  * unread, which only an explicit act clears: a tap on the notification,
//    a click on the item (whether or not anything could be brought forward:
//    the click is the user looking), Mark as read (`markEventsRead`).
//    Closing a banner, opening the popover and time passing never do;
//  * whether the event is for the user at all. An event its producer only
//    recorded for the history (before launch, under a minute, a report's
//    own turn, crons, interruptions) asks nobody to read it: it stays unread
//    in the log, is never listed or counted, and the log keeps and drops it
//    like a read event (`AgentMeterEventStore.Limits.historyOnlyReasons`).

/// A task outcome as the menu names it.
enum TaskEventStatus: String, CaseIterable, Sendable, Equatable {
    case completed, failed, waiting
    /// `task_unknown`: the main agent stopped while background work the task
    /// started was still running, and nothing has said since whether it
    /// finished. Never shown as finished, and never turned into finished by
    /// marking it read.
    case unconfirmed

    init?(kind: AgentMeterEventKind) {
        switch kind {
        case .taskCompleted: self = .completed
        case .taskFailed: self = .failed
        case .taskWaiting: self = .waiting
        case .taskUnknown: self = .unconfirmed
        default: return nil
        }
    }

    var kind: AgentMeterEventKind {
        switch self {
        case .completed: .taskCompleted
        case .failed: .taskFailed
        case .waiting: .taskWaiting
        case .unconfirmed: .taskUnknown
        }
    }

    static let kinds = Set(allCases.map(\.kind))

    var label: String {
        switch self {
        case .completed: "Finished"
        case .failed: "Failed"
        case .waiting: "Needs input"
        case .unconfirmed: "Task status unconfirmed"
        }
    }

    /// The 1b event text for this state ("stopped, background work running")
    /// claimed the shell was still running; it may have ended since with no
    /// hook to say so. The menu says only what was seen, when.
    static let unconfirmedExplanation =
        "Background tasks were still running at the last check, so completion can't be confirmed."

    var symbolName: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .waiting: "hourglass.circle.fill"
        case .unconfirmed: "questionmark.circle"
        }
    }
}

enum TaskEventAttention {
    /// Whether the user is meant to see this event in the menu: a status the
    /// menu shows, settled, and not held back by its producer for the history
    /// only. A kind switched off in Settings still is (the switch is about the
    /// banner), and so is an unconfirmed task, whose producer never posts it.
    static func needsAttention(_ event: AgentMeterEvent) -> Bool {
        guard TaskEventStatus(kind: event.kind) != nil else { return false }
        switch event.delivery.state {
        case .pending:
            // Settled within the same submit; counting it first would make
            // the menu bar flicker for every history-only event.
            return false
        case .suppressed:
            return !AgentMeterEventLogState.isHistoryOnly(event, reasons: TaskOutcomeAnnouncement.historyOnlyReasons)
        case .posted, .failed, .interrupted:
            return true
        }
    }
}

/// Every event of one task (`<session>|<task>`): a wait, the end, a
/// follow-up's end. The menu shows the latest status; reading the item
/// (a click, its banner, the check mark) marks all of them read.
struct TaskEventItem: Identifiable, Sendable, Equatable {
    let id: String
    let status: TaskEventStatus
    let latest: AgentMeterEvent
    /// The task's events the menu knows, newest first.
    let eventIDs: [String]
    let unreadEventIDs: [String]
    /// The title the newest of its events recorded for the session
    /// (`AgentMeterEventSubject.sessionTitle`), sanitized; nil for events
    /// from before format 2 or a session without one. A live row's title
    /// comes first (`TaskEventsSection`).
    var storedSessionTitle: String? = nil

    var isUnread: Bool { !unreadEventIDs.isEmpty }
    /// A run a script started, as the registry said when it was recorded.
    var isHeadless: Bool { latest.subject.sessionKind == TaskSessionLaunch.headless.rawValue }
    var sessionID: String? { latest.subject.sessionID }
    var occurredAt: Date { latest.occurredAt }

    /// The producer's second line: run time, the error kind, what the session
    /// waits for. None for an unconfirmed task, whose stored line may say a
    /// shell "still" runs.
    var detail: String? {
        guard status != .unconfirmed else { return nil }
        let body = latest.content.body
        let line = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first
            .map(String.init) ?? body
        return SessionLabel.title(line)
    }

    /// The folder the task ran in, else what the producer called it.
    var projectName: String {
        latest.subject.projectPath.flatMap { SessionLabel.title(URL(fileURLWithPath: $0).lastPathComponent) }
            ?? "Claude"
    }

    var shortSessionID: String? { sessionID.map { "Session \($0.prefix(8))" } }

    /// The same task with its events read, for a row the menu keeps in place
    /// after the click that read it.
    var markedRead: TaskEventItem {
        TaskEventItem(id: id, status: status, latest: latest, eventIDs: eventIDs, unreadEventIDs: [],
                      storedSessionTitle: storedSessionTitle)
    }

    /// What became of the banner, for the tooltip.
    var deliveryText: String {
        let delivery = latest.delivery
        typealias Suppression = AgentMeterEventDelivery.Suppression
        switch delivery.state {
        case .posted: return "Notification shown"
        case .pending: return "Notification being sent"
        case .interrupted: return "Notification may not have been shown (AgentMeter quit while sending it)"
        case .failed: return "Notification could not be shown"
        case .suppressed:
            switch delivery.reason {
            case Suppression.disabledByUser: return "No macOS notification (turned off in Settings); still listed here"
            case Suppression.permissionDenied: return "No notification: not allowed in System Settings"
            case Suppression.notAuthorized: return "No notification: permission not granted"
            case Suppression.stale: return "No notification: found too late to announce"
            case Suppression.noAppBundle: return "No notification: development build"
            case TaskOutcomeAnnouncement.Reason.backgroundShellRunning: return "Listed here only, never sent as a notification"
            default: return "Recorded only"
            }
        }
    }

    static func key(_ event: AgentMeterEvent) -> String {
        "\(event.subject.sessionID ?? "")|\(event.subject.taskKey ?? event.id)"
    }

    /// The events the user is meant to see, one item per task, newest first.
    static func items(from events: [AgentMeterEvent]) -> [TaskEventItem] {
        var byTask: [String: [AgentMeterEvent]] = [:]
        var seen = Set<String>()
        for event in events where seen.insert(event.id).inserted && TaskEventAttention.needsAttention(event) {
            byTask[key(event), default: []].append(event)
        }
        return byTask.compactMap { key, events -> TaskEventItem? in
            let sorted = events.sorted(by: newestFirst)
            guard let latest = sorted.first, let status = TaskEventStatus(kind: latest.kind) else { return nil }
            return TaskEventItem(id: key, status: status, latest: latest, eventIDs: sorted.map(\.id),
                                 unreadEventIDs: sorted.filter(\.isUnread).map(\.id),
                                 storedSessionTitle: sorted.lazy.compactMap { SessionLabel.title($0.subject.sessionTitle) }.first)
        }
        .sorted { newestFirst($0.latest, $1.latest) }
    }

    static func newestFirst(_ a: AgentMeterEvent, _ b: AgentMeterEvent) -> Bool {
        if a.occurredAt != b.occurredAt { return a.occurredAt > b.occurredAt }
        if a.discoveredAt != b.discoveredAt { return a.discoveredAt > b.discoveredAt }
        return a.id > b.id
    }
}

/// Unread events the event log dropped at its cap (`unreadOverflow()`)
/// since the user last acknowledged it.
struct TaskEventOverflowNotice: Sendable, Equatable {
    var dropped: Int
    /// An unread event discovered at or before this may be among them.
    var throughDiscoveredAt: Date
    var total: Int
    var lastDroppedAt: Date
}

/// Which overflow total the user has seen, kept in `UserDefaults` (the log
/// keeps only the running total, and its format stays as it is).
struct TaskEventOverflowAcknowledgement: Sendable, Equatable {
    static let countKey = "taskEventsOverflowAcknowledgedCount"
    static let droppedAtKey = "taskEventsOverflowAcknowledgedDroppedAt"

    var count: Int
    /// The acknowledged total's `lastDroppedAt`, in whole milliseconds.
    var droppedAtMs: Int64?

    init(count: Int = 0, droppedAtMs: Int64? = nil) {
        self.count = count
        self.droppedAtMs = droppedAtMs
    }

    init(defaults: UserDefaults) {
        self.init(count: (defaults.object(forKey: Self.countKey) as? NSNumber)?.intValue ?? 0,
                  droppedAtMs: (defaults.object(forKey: Self.droppedAtKey) as? NSNumber)?.int64Value)
    }

    init(_ overflow: AgentMeterUnreadOverflow) {
        self.init(count: overflow.count, droppedAtMs: HistoryTime.ms(overflow.lastDroppedAt))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(count, forKey: Self.countKey)
        if let droppedAtMs { defaults.set(NSNumber(value: droppedAtMs), forKey: Self.droppedAtKey) }
    }

    /// Nil once this exact total was acknowledged. A total below the
    /// acknowledged one means the log started over: all of it is new.
    func notice(for overflow: AgentMeterUnreadOverflow?) -> TaskEventOverflowNotice? {
        guard let overflow, overflow.count > 0 else { return nil }
        if overflow.count == count, HistoryTime.ms(overflow.lastDroppedAt) == droppedAtMs { return nil }
        let dropped = overflow.count > count ? overflow.count - count : overflow.count
        return TaskEventOverflowNotice(dropped: dropped, throughDiscoveredAt: overflow.throughDiscoveredAt,
                                       total: overflow.count, lastDroppedAt: overflow.lastDroppedAt)
    }
}

/// What the menu lists. `unread` is every task the user has not read,
/// `handled` the latest few that were read ("Read" in the menu).
struct TaskEventsSnapshot: Sendable, Equatable {
    static let handledLimit = 10

    var unread: [TaskEventItem]
    var handled: [TaskEventItem]
    var overflow: TaskEventOverflowNotice?

    /// What the menu bar counts: tasks, not events.
    var unreadCount: Int { unread.count }
    var isEmpty: Bool { unread.isEmpty && handled.isEmpty }

    static let empty = TaskEventsSnapshot(unread: [], handled: [], overflow: nil)

    /// From every unread event of the shown kinds and the newest events of
    /// those kinds whatever their read state (which brings in the later,
    /// already read, events of an unread task).
    static func make(unreadEvents: [AgentMeterEvent], recentEvents: [AgentMeterEvent],
                     overflow: TaskEventOverflowNotice?) -> TaskEventsSnapshot {
        let items = TaskEventItem.items(from: unreadEvents + recentEvents)
        return TaskEventsSnapshot(unread: items.filter(\.isUnread),
                                  handled: Array(items.filter { !$0.isUnread }.prefix(handledLimit)),
                                  overflow: overflow)
    }
}

/// Settings › Alerts › "Show task list in the menu": whether the popover
/// lists the tasks and the menu bar counts them. Default on. Off hides those
/// two and nothing else: banners, the event log and read state carry on, so
/// turning it back on shows everything as it stands.
enum TaskEventListVisibility {
    static let key = "taskNotificationsShowListInMenu"
    static let defaultValue = true

    /// A missing value, or one of the wrong type, keeps the default.
    static func isShown(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Before the event log is read, the menu says so instead of "nothing yet".
enum TaskEventsState: Sendable, Equatable {
    case loading
    case loaded(TaskEventsSnapshot)

    var snapshot: TaskEventsSnapshot? {
        if case let .loaded(snapshot) = self { return snapshot }
        return nil
    }

    var unreadCount: Int { snapshot?.unreadCount ?? 0 }
}
