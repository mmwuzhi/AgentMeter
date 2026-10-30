import AgentStatusCore
import AppKit
import Dispatch
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppViewModel()
    private var coordinator: RefreshCoordinator!
    private var statusController: StatusItemController!
    private var taskOutcomes: TaskOutcomeMonitor?
    private var taskOutcomeQueue: TaskOutcomeQueue?
    private var taskEvents: TaskEventFeed?
    private var quit: QuitSequence?

    /// AppKit's own per-app keys, in the registration domain, so a value set
    /// with `defaults write` still wins. Called from `AgentMeterApp.init`,
    /// before any view exists: AppKit's tooltip manager reads
    /// `NSInitialToolTipDelay` once, when the first tooltip creates it, and
    /// SwiftUI builds the Settings scene, whose layout-editor chips carry
    /// tooltips, before `applicationDidFinishLaunching` runs. Registered there,
    /// the delay never applied and every hover took AppKit's 1.5 s.
    static func registerAppKitDefaults() {
        UserDefaults.standard.register(defaults: [
            // Keep status-item gaps tight through AppKit's own per-app spacing keys.
            // Drawing outside the declared length is clipped on non-active displays.
            "NSStatusItemSpacing": 6,
            "NSStatusItemSelectionPadding": 6,
            // Sparkline/heatmap cells and session rows rely on hover tooltips
            // for their numbers; the 1.5 s system default feels broken there.
            // Milliseconds.
            "NSInitialToolTipDelay": 250,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsOpener.withdrawLaunchPresentation()
        // Task outcomes that happened before this (while AgentMeter was not
        // running) are recorded, not announced.
        let launchedAt = Date()
        // Menubar-only app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Repair launch-at-login if an update (ad-hoc signature change) silently dropped it.
        LoginItem.reconcile()

        // The same age after which a hook-reported error stops being red.
        AgentStatusStore.sweepStale(olderThan: ActiveAgent.errorAttentionWindow)
        if UserDefaults.standard.bool(forKey: "statusHooksEnabled") {
            _ = ClaudeHookInstaller.installManagedCLI()
            _ = try? ClaudeHookInstaller.install()
        }

        // Start Sparkle's background update checks (relocated to Settings → manual check).
        _ = UpdaterController.shared
        coordinator = RefreshCoordinator(viewModel: model)
        let feed = TaskEventFeed(manager: NotificationManager.shared, model: model)
        taskEvents = feed
        statusController = StatusItemController(model: model, coordinator: coordinator, taskEvents: feed)
        feed.showSessions = { [weak self] in self?.statusController.showClaudeSessions() }
        NotificationManager.shared.activate()
        NotificationManager.shared.onOpenProvider = { [weak self] provider in
            self?.statusController.showPopover(for: provider)
        }
        NotificationManager.shared.onEventsChanged = { [weak feed] in feed?.scheduleReload() }
        NotificationManager.shared.onEventResponse = { [weak feed] event, _ in
            await feed?.handleNotificationResponse(event) ?? true
        }
        feed.scheduleReload()
        coordinator.start()
        startTaskOutcomes(launchedAt: launchedAt, feed: feed)
    }

    /// Session task outcomes (Completed / Failed / Waiting / Interrupted)
    /// from the hook helper's turn ledgers, through the shared event path.
    /// Off the main thread except for naming the session from the latest
    /// rows and handing the event to `NotificationManager`, one outcome at a
    /// time in the order they were found (`TaskOutcomeQueue`). The sessions'
    /// latest prompts go to the feed, which hides a result the next turn
    /// superseded.
    private func startTaskOutcomes(launchedAt: Date, feed: TaskEventFeed) {
        let model = model
        let queue = TaskOutcomeQueue { outcome in
            await TaskOutcomeAnnouncement.announce(outcome, rows: model.activeAgents, manager: .shared,
                                                   launchedAt: launchedAt)
        }
        let monitor = TaskOutcomeMonitor(turnStarts: { [weak feed] starts in
            // In order: the main queue keeps the monitor's sequence.
            DispatchQueue.main.async { MainActor.assumeIsolated { feed?.turnStartsChanged(starts) } }
        }, deliver: { queue.enqueue($0) })
        monitor.start()
        taskOutcomeQueue = queue
        taskOutcomes = monitor
    }

    /// Quit (the menu, a Sparkle relaunch, logout) first closes the history
    /// store, within `QuitSequence.historyDeadline`, then lets AppKit finish.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sequence = quit ?? QuitSequence(
            deadline: QuitSequence.historyDeadline,
            stopRefreshing: { [weak self] in
                self?.coordinator?.stop()
                self?.taskOutcomes?.stop()
            },
            closeHistory: Self.closeHistory)
        quit = sequence
        return sequence.begin { sender.reply(toApplicationShouldTerminate: true) }
    }

    private nonisolated static func closeHistory() async {
        await HistoryStore.shared.shutdown()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Already stopped by the quit sequence when AppKit asked first; stop()
        // is idempotent and covers a termination that skipped the question.
        coordinator?.stop()
        taskOutcomes?.stop()
    }
}

/// What happens between a quit request and AppKit terminating, apart from
/// AppKit so a test can drive it: stop the refresh, give the history store a
/// bounded moment to apply the quota readings still queued and close its
/// database cleanly, then reply. Without the close, `exit()` leaves a
/// non-empty WAL behind on every quit and every next launch takes itself for
/// a crash and runs a full `integrity_check`.
///
/// Never blocks the MainActor (the store works on its own queue, the wait is
/// an `await`) and never holds the quit hostage: the reply comes exactly
/// once, when the store is closed or when the deadline passes, whichever is
/// first. Interrupting a cold backfill is fine: the next launch re-applies it.
///
/// Nothing here may wait for the main dispatch queue. AppKit waits for
/// `reply(toApplicationShouldTerminate:)` in a nested run loop
/// (`NSModalPanelRunLoopMode`) inside `terminate(_:)`; when that call came
/// from the main queue itself (a MainActor task, a `DispatchQueue.main`
/// block: a Sparkle relaunch, any `Task { NSApp.terminate(nil) }`), the queue
/// cannot run anything else until it returns, so a `Task { @MainActor in }`
/// or `DispatchQueue.main.async` reply never comes and the quit hangs
/// (verified with a SwiftUI app on this delegate adaptor; a quit from a menu
/// item happens not to hit it). The work starts detached and the reply comes
/// through the run loop's own queue (`onMainRunLoop`), which works in both cases.
@MainActor
final class QuitSequence {
    /// The longest a quit waits for the store. A clean close normally takes
    /// one scan transaction (`inChunks`: ~50-85 ms at p90 behind a backfill)
    /// plus the queued quota commands and the closing checkpoint (milliseconds
    /// to tens of milliseconds); 1.5 s also covers an fsync stall of a busy
    /// disk while staying short of what reads as a hung quit (and of logout's
    /// patience). Past it the process exits as it always did, and the next
    /// launch's unclean-shutdown check covers whatever was in flight. The
    /// timer keeps dispatch's default leeway, so it may fire up to a tenth
    /// late: the reply comes within about 1.65 s.
    nonisolated static let historyDeadline: Duration = .milliseconds(1_500)

    private let deadline: Duration
    private let stopRefreshing: @MainActor () -> Void
    private let closeHistory: @Sendable () async -> Void
    private var started = false

    init(deadline: Duration = QuitSequence.historyDeadline,
         stopRefreshing: @escaping @MainActor () -> Void,
         closeHistory: @escaping @Sendable () async -> Void) {
        self.deadline = deadline
        self.stopRefreshing = stopRefreshing
        self.closeHistory = closeHistory
    }

    /// For `applicationShouldTerminate`: always `.terminateLater`. `reply`
    /// runs once, on the main thread, after the store closed or the deadline
    /// passed. A second quit request while one is in progress starts nothing
    /// new; the first one's reply ends the process.
    func begin(reply: @escaping @MainActor @Sendable () -> Void) -> NSApplication.TerminateReply {
        stopRefreshing()
        guard !started else { return .terminateLater }
        started = true
        // Armed before this returns, and the reply goes straight from the
        // timer's queue (or the finished work) to the run loop: no step of the
        // deadline path waits for a cooperative-pool thread, which work that
        // never suspends can hold for seconds.
        Self.race(closeHistory, deadline: deadline) { _ in Self.onMainRunLoop(reply) }
        return .terminateLater
    }

    /// Runs `body` on the main thread through the main run loop's own block
    /// queue, in the common modes and explicitly in the modal mode AppKit
    /// waits in, instead of through the main dispatch queue.
    nonisolated static func onMainRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Runs `work` and returns true when it finished within `deadline`, false
    /// when the deadline came first; in that case `work` is left running and
    /// this returns anyway. For tests; `begin` uses `race` directly.
    nonisolated static func run(_ work: @escaping @Sendable () async -> Void, deadline: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            race(work, deadline: deadline) { continuation.resume(returning: $0) }
        }
    }

    /// The deadline timer's queue. Private and serial, so its thread comes
    /// from dispatch's overcommit pool: a global queue's thread can be held
    /// back while threads at its QoS or above keep every CPU busy, and tasks
    /// started from the MainActor (the Claude scan) run at this QoS.
    private nonisolated static let deadlineQueue = DispatchQueue(label: "quit.deadline", qos: .userInitiated)

    /// Starts `work` and calls `done` exactly once: with true when `work`
    /// finished first, with false when `deadline` came first (`work` is then
    /// left running). Unstructured on purpose: a task group would wait for a
    /// stuck child. The timer is a dispatch timer armed before this returns
    /// and `done(false)` runs on its own serial queue, so the deadline is
    /// kept even when every cooperative-pool thread is held by work that does
    /// not suspend (a long synchronous parse), at any QoS: neither arming the
    /// timer nor reporting it waits for one.
    nonisolated static func race(_ work: @escaping @Sendable () async -> Void, deadline: Duration,
                                 done: @escaping @Sendable (Bool) -> Void) {
        // Whoever comes first flips it; the other finds it already false.
        let pending = OSAllocatedUnfairLock(initialState: true)
        @Sendable func finish(_ inTime: Bool) {
            let first = pending.withLock { open -> Bool in
                defer { open = false }
                return open
            }
            if first { done(inTime) }
        }
        let (seconds, attoseconds) = deadline.components
        let nanoseconds = max(0, seconds) * 1_000_000_000 + max(0, attoseconds) / 1_000_000_000
        deadlineQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
            finish(false)
        }
        Task.detached {
            await work()
            finish(true)
        }
    }
}
