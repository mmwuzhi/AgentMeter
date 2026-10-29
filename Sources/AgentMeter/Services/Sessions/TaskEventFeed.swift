import Foundation
import os

/// What a click on a task (its row or its banner) could not do, shown as one
/// short line under the task's row until the next click or until the popover
/// closes. The click read the task either way.
struct TaskEventNotice: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// No live process reports the session.
        case ended
        /// Unrelated live processes report it.
        case ambiguous
        /// Alive, but in nothing AgentMeter can bring forward.
        case unhosted
        /// The terminal tab was named, but selecting it failed.
        case focusFailed
        /// The app the session runs in did not come forward.
        case activationFailed
    }

    /// The task as clicked, read: reading moves it out of the unread list,
    /// and the menu keeps its row where it was while the line shows.
    var item: TaskEventItem
    var reason: Reason
    /// The app the click tried, when there was one.
    var hostName: String?

    var itemID: String { item.id }

    var message: String {
        switch reason {
        case .ended: "Session has ended"
        case .ambiguous: "More than one process has this session"
        case .unhosted: "Not in an app AgentMeter can bring forward"
        case .focusFailed: "Couldn't switch to the \(hostName ?? "terminal") tab"
        case .activationFailed: "Couldn't bring \(hostName ?? "its app") forward"
        }
    }
}

/// Keeps `AppViewModel.taskEvents` in step with the event log and carries out
/// what the user does with a task: open it, mark it read, mark them all,
/// acknowledge dropped events. "Read" is the event's read state (1a's
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
    /// could not bring anything forward.
    var showList: (@MainActor () -> Void)?

    private var reloadTask: Task<Void, Never>?
    private var reloadAgain = false
    private(set) var reloadCount = 0
    /// Sessions whose route `preview` is looking up.
    private var previewing: Set<String> = []

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

    /// The check mark: reads the task without leaving the menu.
    func markRead(_ item: TaskEventItem) async {
        model.taskEventNotice = nil
        await manager.markEventsRead(ids: item.unreadEventIDs)
    }

    /// The tasks the user was shown, not whatever arrived since.
    func markAllRead(_ items: [TaskEventItem]) async {
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

    /// A click on the task in the menu: brings forward what runs the session
    /// (its terminal tab, else its app) and reads the task whether or not
    /// anything came forward. The click is the user looking at it; manual
    /// marking for a session AgentMeter cannot reach only got in the way. A
    /// line under the row says what could not be done.
    func open(_ item: TaskEventItem) async {
        model.taskEventNotice = nil
        let failure = await route(sessionID: item.sessionID, origin: "menu")
        model.taskEventNotice = failure.map {
            TaskEventNotice(item: item.markedRead, reason: $0.reason, hostName: $0.hostName)
        }
        await manager.markEventsRead(ids: item.unreadEventIDs)
    }

    /// A tap on a task's notification (`NotificationManager.onEventResponse`):
    /// the same as a click on its row. The task's unread events (the wait
    /// before the end too) are read either way. When nothing came forward,
    /// the menu opens on the list to say why. Returns true, so the manager
    /// reads the tapped event too.
    func handleNotificationResponse(_ event: AgentMeterEvent) async -> Bool {
        guard TaskEventStatus(kind: event.kind) != nil else { return true }
        let key = TaskEventItem.key(event)
        let siblings = await manager.eventStore.events(matching: AgentMeterEventFilter(
            kinds: TaskEventStatus.kinds, sessionID: event.subject.sessionID, unreadOnly: true))
        // Only what the menu lists: a history-only event of the same task
        // keeps its unread state (it is never read on anyone's behalf).
        var ids = siblings.filter { TaskEventItem.key($0) == key && TaskEventAttention.needsAttention($0) }.map(\.id)
        if event.isUnread, !ids.contains(event.id) { ids.append(event.id) }
        let failure = await route(sessionID: event.subject.sessionID, origin: "notification")
        let listed = model.taskEvents.snapshot.flatMap { snapshot in
            (snapshot.unread + snapshot.handled).first { $0.id == key }
        }
        if let failure, let item = listed ?? TaskEventItem.items(from: [event]).first {
            model.taskEventNotice = TaskEventNotice(item: item.markedRead, reason: failure.reason,
                                                    hostName: failure.hostName)
            showList?()
        }
        if !ids.isEmpty { await manager.markEventsRead(ids: ids) }
        return true
    }

    /// Where a click on the task would go, for its row's tooltip: looked up
    /// when the pointer first reaches a row of the session, once per session
    /// while the popover is open. It only looks; the click looks again.
    func preview(_ item: TaskEventItem) async {
        guard let sessionID = item.sessionID, model.taskEventRoutes[sessionID] == nil,
              previewing.insert(sessionID).inserted else { return }
        defer { previewing.remove(sessionID) }
        let found = await lookup.processes(sessionID: sessionID, rows: model.activeAgents)
        model.taskEventRoutes[sessionID] = TaskSessionRouting.route(for: found)
    }

    /// Brings forward what runs the session: nil when it came forward, else
    /// why not. The app is activated only here, on the user's click.
    private func route(sessionID: String?, origin: String) async -> (reason: TaskEventNotice.Reason, hostName: String?)? {
        var found: [TaskSessionProcess] = []
        if let sessionID { found = await lookup.processes(sessionID: sessionID, rows: model.activeAgents) }
        let route = TaskSessionRouting.route(for: found)
        if let sessionID { model.taskEventRoutes[sessionID] = route }
        let failure: (reason: TaskEventNotice.Reason, hostName: String?)?
        switch route {
        case let .terminalTab(process):
            failure = lookup.focusTerminal(process) ? nil : (.focusFailed, process.host?.name)
        case let .appOnly(process):
            let activated = process.host.map { lookup.activate($0) } ?? false
            failure = activated ? nil : (.activationFailed, process.host?.name)
        case .unhosted:
            failure = (.unhosted, nil)
        case .ended:
            failure = (.ended, nil)
        case .ambiguous:
            failure = (.ambiguous, nil)
        }
        log("task click (\(origin)): \(Self.logName(route))" + (failure == nil ? "" : ", nothing came forward"))
        return failure
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
