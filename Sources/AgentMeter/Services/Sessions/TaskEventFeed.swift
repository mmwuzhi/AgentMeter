import Foundation
import os

/// Why a click on a task did not bring its session forward, shown in the
/// menu next to the task. The task stays unread: only reaching the session,
/// or Mark seen, reads it.
struct TaskEventNotice: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// No live process reports the session.
        case ended
        /// Unrelated live processes report it.
        case ambiguous
        /// Alive, but in nothing AgentMeter can bring forward.
        case unhosted
        /// Alive in `host` (an editor, or an app whose window it cannot name):
        /// AgentMeter does not switch its windows.
        case appOnly
        /// The terminal tab was named, but selecting it failed.
        case focusFailed
    }

    var itemID: String
    var projectName: String
    /// The session's short id ("Session ffafe0d9").
    var sessionLabel: String?
    var reason: Reason
    /// What "Bring forward" activates; nil when there is nothing to offer.
    var host: TaskSessionHost?
    /// The task's unread events, for Mark seen.
    var eventIDs: [String] = []

    var message: String {
        switch reason {
        case .ended:
            "This session has ended. AgentMeter doesn't reopen or resume sessions."
        case .ambiguous:
            "More than one Claude Code process reports this session, so AgentMeter didn't pick one."
        case .unhosted:
            "This session runs outside an app AgentMeter can bring forward."
        case .appOnly:
            "AgentMeter doesn't switch windows in \(host?.name ?? "this app"), so it can't take you to this session's window."
        case .focusFailed:
            "AgentMeter couldn't switch to this session's \(host?.name ?? "terminal") tab."
        }
    }

    static let staysUnread = "The task stays unread until you mark it seen."
}

/// Keeps `AppViewModel.taskEvents` in step with the event log and carries out
/// what the user does with a task: open it, mark it seen, mark them all,
/// acknowledge dropped events. "Seen" is the event's read state (1a's
/// `readAt`): it says the user looked, never that a wait is over or that an
/// unconfirmed task finished. Reads only when something changed (the
/// manager's `onEventsChanged`, a popover opening), never on a timer.
@MainActor
final class TaskEventFeed {
    /// The newest events read per reload whatever their read state, which
    /// covers the handled list and the later events of unread tasks.
    static let recentLimit = 200
    /// Changes come in bursts (record, then settle): one reload covers them.
    static let reloadDelay: Duration = .milliseconds(150)

    let manager: NotificationManager
    private let model: AppViewModel
    private let defaults: UserDefaults
    private let lookup: TaskSessionLookup
    private let log: @Sendable (String) -> Void
    /// Opens the menu that lists the tasks, for a notification click that
    /// could not go to its session.
    var showList: (@MainActor () -> Void)?

    private var reloadTask: Task<Void, Never>?
    private var reloadAgain = false
    private(set) var reloadCount = 0

    init(manager: NotificationManager, model: AppViewModel, defaults: UserDefaults = .standard,
         lookup: TaskSessionLookup = .live, log: @escaping @Sendable (String) -> Void = TaskEventFeed.systemLog) {
        self.manager = manager
        self.model = model
        self.defaults = defaults
        self.lookup = lookup
        self.log = log
    }

    // MARK: - Reading

    /// Reloads soon, once for a burst of changes.
    func scheduleReload() {
        guard reloadTask == nil else {
            reloadAgain = true
            return
        }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reloadDelay)
            guard let self else { return }
            await self.reloadNow()
            self.reloadTask = nil
            if self.reloadAgain {
                self.reloadAgain = false
                self.scheduleReload()
            }
        }
    }

    /// Reads the log (on its own queue) and publishes what the menu shows.
    /// History-only events stay unread in the log and are left out here
    /// (`TaskEventAttention`); the log keeps and drops them like read ones.
    func reloadNow() async {
        let store = manager.eventStore
        let clock = ContinuousClock()
        let started = clock.now
        let unread = await store.events(matching: AgentMeterEventFilter(kinds: TaskEventStatus.kinds, unreadOnly: true))
        let recent = await store.events(matching: AgentMeterEventFilter(kinds: TaskEventStatus.kinds), limit: Self.recentLimit)
        let overflow = TaskEventOverflowAcknowledgement(defaults: defaults).notice(for: await store.unreadOverflow())
        let snapshot = TaskEventsSnapshot.make(unreadEvents: unread, recentEvents: recent, overflow: overflow)
        let state = TaskEventsState.loaded(snapshot)
        if model.taskEvents != state { model.taskEvents = state }
        reloadCount += 1
        if reloadCount == 1 {
            let ms = Int((clock.now - started) / .milliseconds(1))
            log("task list loaded: \(snapshot.unreadCount) unread tasks, \(ms) ms")
        }
    }

    // MARK: - Acting

    func markSeen(_ item: TaskEventItem) async {
        if model.taskEventNotice?.itemID == item.id { model.taskEventNotice = nil }
        await manager.markEventsRead(ids: item.unreadEventIDs)
    }

    /// Mark seen on a notice: the task the click could not reach.
    func markSeen(_ notice: TaskEventNotice) async {
        if model.taskEventNotice == notice { model.taskEventNotice = nil }
        await manager.markEventsRead(ids: notice.eventIDs)
    }

    /// The tasks the user was shown, not whatever arrived since.
    func markAllSeen(_ items: [TaskEventItem]) async {
        model.taskEventNotice = nil
        await manager.markEventsRead(ids: items.flatMap(\.unreadEventIDs))
    }

    func acknowledgeOverflow() async {
        guard let overflow = await manager.eventStore.unreadOverflow() else { return }
        TaskEventOverflowAcknowledgement(overflow).save(to: defaults)
        if var snapshot = model.taskEvents.snapshot, snapshot.overflow != nil {
            snapshot.overflow = nil
            model.taskEvents = .loaded(snapshot)
        }
    }

    /// A click on the task in the menu. When its session comes forward the
    /// task is read; when it does not, the menu says why and the task stays
    /// unread.
    func open(_ item: TaskEventItem) async {
        let reached = await route(sessionID: item.sessionID, itemID: item.id, projectName: item.projectName,
                                  sessionLabel: item.shortSessionID, eventIDs: item.unreadEventIDs,
                                  fromNotification: false)
        if reached { await manager.markEventsRead(ids: item.unreadEventIDs) }
    }

    /// A tap on a task's notification (`NotificationManager.onEventResponse`).
    /// Returns whether the session came forward: then the task's unread
    /// events (the wait before the end too) are read, and the manager reads
    /// the tapped one. Otherwise nothing is read, and the menu opens to say
    /// why.
    func handleNotificationResponse(_ event: AgentMeterEvent) async -> Bool {
        guard TaskEventStatus(kind: event.kind) != nil else { return true }
        let key = TaskEventItem.key(event)
        let siblings = await manager.eventStore.events(matching: AgentMeterEventFilter(
            kinds: TaskEventStatus.kinds, sessionID: event.subject.sessionID, unreadOnly: true))
        // Only what the menu lists: a history-only event of the same task
        // keeps its unread state (it is never read on anyone's behalf).
        var ids = siblings.filter { TaskEventItem.key($0) == key && TaskEventAttention.needsAttention($0) }.map(\.id)
        if event.isUnread, !ids.contains(event.id) { ids.append(event.id) }
        let item = TaskEventItem.items(from: [event]).first
        let reached = await route(sessionID: event.subject.sessionID, itemID: key,
                                  projectName: item?.projectName ?? "Claude", sessionLabel: item?.shortSessionID,
                                  eventIDs: ids, fromNotification: true)
        if reached, !ids.isEmpty { await manager.markEventsRead(ids: ids) }
        return reached
    }

    /// "Bring forward" on a notice: the app only, which never creates a window.
    func bringForward(_ notice: TaskEventNotice) {
        guard let host = notice.host else { return }
        if lookup.activate(host) { model.taskEventNotice = nil }
    }

    func dismissNotice() {
        model.taskEventNotice = nil
    }

    /// Whether the session came forward.
    private func route(sessionID: String?, itemID: String, projectName: String, sessionLabel: String?,
                       eventIDs: [String], fromNotification: Bool) async -> Bool {
        var found: [TaskSessionProcess] = []
        if let sessionID { found = await lookup.processes(sessionID: sessionID, rows: model.activeAgents) }
        let route = TaskSessionRouting.route(for: found)
        let reason: TaskEventNotice.Reason?
        var host: TaskSessionHost?
        switch route {
        case let .terminalTab(process):
            host = process.host
            reason = lookup.focusTerminal(process) ? nil : .focusFailed
        case let .appOnly(process):
            host = process.host
            reason = .appOnly
        case .unhosted:
            reason = .unhosted
        case .ended:
            reason = .ended
        case .ambiguous:
            reason = .ambiguous
        }
        log("task click (\(fromNotification ? "notification" : "menu")): \(Self.logName(route))"
            + (reason == nil ? "" : ", menu explains"))
        guard let reason else {
            if model.taskEventNotice?.itemID == itemID { model.taskEventNotice = nil }
            return true
        }
        model.taskEventNotice = TaskEventNotice(itemID: itemID, projectName: projectName, sessionLabel: sessionLabel,
                                                reason: reason, host: host, eventIDs: eventIDs)
        if fromNotification { showList?() }
        return false
    }

    private static func logName(_ route: TaskSessionRoute) -> String {
        switch route {
        case .terminalTab: "terminal tab"
        case .appOnly: "app only"
        case .unhosted: "no app"
        case .ended: "ended"
        case let .ambiguous(count): "\(count) processes"
        }
    }

    /// Counts and route kinds only: never a path, a title or a session id.
    nonisolated static let systemLog: @Sendable (String) -> Void = {
        feedLogger.notice("AgentMeter: events \($0, privacy: .public)")
    }

    private nonisolated static let feedLogger = Logger(subsystem: "com.shu.agentmeter", category: "events")
}
