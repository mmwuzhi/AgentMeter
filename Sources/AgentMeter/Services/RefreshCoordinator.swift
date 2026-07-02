import AppKit
import Foundation

/// Drives periodic + manual refresh of all providers and publishes into the view model.
@MainActor
final class RefreshCoordinator {
    private let viewModel: AppViewModel
    private let codex = CodexService()
    private let claude = ClaudeService()
    private let copilot = CopilotService()
    private var timer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?
    private var refreshStartedAt: Date?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    /// Refresh cadence in seconds, from Settings (clamped to 15…3600). Default 60.
    private var refreshInterval: TimeInterval {
        let v = UserDefaults.standard.object(forKey: "refreshIntervalSeconds") as? Double ?? 60
        return max(15, min(3600, v))
    }

    func start() {
        Task { await PricingService.shared.refresh() }
        NotificationManager.shared.requestAuthorizationIfNeeded()
        refresh()
        installWakeObservers()
        scheduleTimer()
        // Rebuild the timer when the interval setting changes.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rescheduleIfIntervalChanged() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func rescheduleIfIntervalChanged() {
        if let timer, abs(timer.timeInterval - refreshInterval) > 0.5 { scheduleTimer() }
        // Re-check alerts against current data so lowering the threshold (or toggling
        // alerts on) notifies right away instead of waiting for the next fetch.
        NotificationManager.shared.evaluate(provider: .codex, windows: viewModel.codex.quota.windows)
        NotificationManager.shared.evaluate(provider: .claude, windows: viewModel.claude.quota.windows)
        NotificationManager.shared.evaluate(provider: .copilot, windows: viewModel.copilot.quota.windows)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach { center.removeObserver($0) }
        wakeObservers.removeAll()
    }

    func refresh() {
        // Coalesce concurrent refreshes, but never let a wedged fetch (e.g. a hung
        // network call) suppress refreshes forever — opening the popover must win.
        if viewModel.isRefreshing {
            guard let started = refreshStartedAt, Date().timeIntervalSince(started) > 30 else { return }
        }
        viewModel.isRefreshing = true
        refreshStartedAt = Date()
        let previousCodexQuota = viewModel.codex.quota
        let previousClaudeQuota = viewModel.claude.quota
        let previousCopilotQuota = viewModel.copilot.quota
        Task {
            async let codexState = codex.fetch()
            async let claudeState = claude.fetch()
            async let copilotState = copilot.fetch()
            let (c, cl, cp) = await (codexState, claudeState, copilotState)
            let now = Date()
            var nextCodex = c.preservingLiveQuota(from: previousCodexQuota, at: now)
            viewModel.codexResetCreditState = CodexResetCreditTracker.reconcile(
                existing: viewModel.codexResetCreditState,
                quota: nextCodex.quota,
                at: now
            )
            if nextCodex.quota.resetCreditsExpiresAt == nil,
               let nearestExpiry = viewModel.codexResetCreditState.nearestExpiry {
                nextCodex.quota = nextCodex.quota.withResetCreditsExpiresAt(nearestExpiry)
            }
            viewModel.codex = nextCodex
            viewModel.claude = cl.preservingLiveQuota(from: previousClaudeQuota, at: now)
            viewModel.copilot = cp.preservingLiveQuota(from: previousCopilotQuota, at: now)
            viewModel.quotaObservations = QuotaTrendTracker.record(
                existing: viewModel.quotaObservations,
                states: [c, cl, cp],
                at: now
            )
            viewModel.lastRefresh = Date()
            viewModel.isRefreshing = false
            refreshStartedAt = nil
            // Cache for the next launch so the menu bar shows last values instantly.
            StateCache.save(
                codex: viewModel.codex,
                claude: viewModel.claude,
                copilot: viewModel.copilot,
                quotaObservations: viewModel.quotaObservations,
                codexResetCreditState: viewModel.codexResetCreditState
            )
            NotificationManager.shared.evaluate(provider: .codex, windows: viewModel.codex.quota.windows)
            NotificationManager.shared.evaluate(provider: .claude, windows: viewModel.claude.quota.windows)
            NotificationManager.shared.evaluate(provider: .copilot, windows: viewModel.copilot.quota.windows)
        }
    }

    private func installWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        wakeObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshAfterWake() }
            }
        }
    }

    private func refreshAfterWake() {
        refresh()
    }
}

extension ProviderState {
    func preservingLiveQuota(from previousQuota: QuotaSnapshot, at date: Date) -> ProviderState {
        guard quota.source == .unavailable, previousQuota.hasUsableWindow(at: date) else { return self }
        var state = self
        state.quota = previousQuota
        return state
    }
}

extension QuotaSnapshot {
    func hasUsableWindow(at date: Date) -> Bool {
        windows.contains { window in
            guard let resetsAt = window.resetsAt else { return true }
            return resetsAt > date
        }
    }
}
