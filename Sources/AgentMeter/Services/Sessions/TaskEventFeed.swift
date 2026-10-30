import Foundation
import os

/// Keeps `AppViewModel.sessionTurnResults` in step with the event log and the
/// turn ledgers, and carries out a tap on a task's notification. There is no
/// list to read or mark: macOS notifications tell the user something ended,
/// the session rows show how each session's latest turn ended, and the log
/// keeps the history (2026-10-30, replacing the menu's task list).
///
/// Reads the log only when something changed (the manager's
/// `onEventsChanged`, a popover opening), never on a timer; the ledgers'
/// turn starts come from `TaskOutcomeMonitor`, which reads them anyway.
@MainActor
final class TaskEventFeed {
    /// The newest task events read per reload. A result is shown for an
    /// hour (`ActiveAgent.turnResultWindow`); far more than an hour's worth.
    static let recentLimit = 500
    /// Changes come in bursts (record, then settle): one reload covers them.
    static let reloadDelay: Duration = .milliseconds(150)

    let manager: NotificationManager
    private let model: AppViewModel
    private let lookup: TaskSessionLookup
    private let log: @Sendable (String) -> Void
    /// Opens the menu with the sessions, for a notification tap that could
    /// not bring the session's app forward although the session still runs.
    var showSessions: (@MainActor () -> Void)?

    private var reloadTask: Task<Void, Never>?
    private var reloadAgain = false
    private(set) var reloadCount = 0
    /// Each session's newest finished or failed turn from the log; nil until
    /// the log has been read.
    private var candidates: [String: SessionTurnResult]?
    /// Each session's latest prompt from the turn ledgers; nil until the
    /// monitor's first pass. Results wait for both, so a result the next
    /// prompt already superseded never shows, not even at launch.
    private var turnStarts: [String: Date]?

    init(manager: NotificationManager, model: AppViewModel, lookup: TaskSessionLookup = .live,
         log: @escaping @Sendable (String) -> Void = TaskEventFeed.systemLog) {
        self.manager = manager
        self.model = model
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

    /// Reads the newest task events (on the log's own queue) and publishes
    /// the sessions' latest turn results.
    func reloadNow() async {
        let clock = ContinuousClock()
        let started = clock.now
        let events = await manager.eventStore.events(
            matching: AgentMeterEventFilter(kinds: SessionTurnResults.eventKinds), limit: Self.recentLimit)
        candidates = SessionTurnResults.newestBySession(events)
        publish()
        reloadCount += 1
        if reloadCount == 1 {
            let ms = Int((clock.now - started) / .milliseconds(1))
            log("turn results loaded: \(candidates?.count ?? 0) sessions, \(ms) ms")
        }
    }

    /// The sessions' latest prompts, from the monitor's pass over the turn
    /// ledgers (only when they changed).
    func turnStartsChanged(_ starts: [String: Date]) {
        turnStarts = starts
        publish()
    }

    private func publish() {
        guard let candidates, let turnStarts else { return }
        let results = SessionTurnResults.current(candidates, turnStarts: turnStarts)
        if model.sessionTurnResults != results { model.sessionTurnResults = results }
    }

    // MARK: - Acting

    /// A tap on a task's notification (`NotificationManager.onEventResponse`):
    /// brings forward what runs the session (its terminal tab, else its app),
    /// as a click on the session's row does. When that could not be done for
    /// a session that still runs, the menu opens on the sessions, where its
    /// row says what it is doing; an ended session has no row to show.
    /// Returns true: the tap is recorded as the event's read time, history
    /// only (nothing lists unread events any more).
    func handleNotificationResponse(_ event: AgentMeterEvent) async -> Bool {
        guard event.kind.family == .task else { return true }
        let failure = await route(sessionID: event.subject.sessionID)
        if let failure, failure != .ended { showSessions?() }
        return true
    }

    /// Brings forward what runs the session: nil when it came forward, else
    /// why not. The app is activated only here, on the user's tap.
    private func route(sessionID: String?) async -> TaskSessionRouteFailure? {
        var found: [TaskSessionProcess] = []
        if let sessionID { found = await lookup.processes(sessionID: sessionID, rows: model.activeAgents) }
        let route = TaskSessionRouting.route(for: found)
        let failure: TaskSessionRouteFailure?
        switch route {
        case let .terminalTab(process):
            failure = lookup.focusTerminal(process) ? nil : .focusFailed
        case let .appOnly(process):
            let activated = process.host.map { lookup.activate($0) } ?? false
            failure = activated ? nil : .activationFailed
        case .unhosted:
            failure = .unhosted
        case .ended:
            failure = .ended
        case .ambiguous:
            failure = .ambiguous
        }
        log("task tap: \(Self.logName(route))" + (failure == nil ? "" : ", nothing came forward"))
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

/// Why a notification tap brought nothing forward.
enum TaskSessionRouteFailure: Sendable, Equatable {
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
