import AppKit
import Foundation

/// Drives periodic + manual refresh of both providers and publishes into the view model.
@MainActor
final class RefreshCoordinator {
    private let viewModel: AppViewModel
    private let codex = CodexService()
    private let claude = ClaudeService()
    private var timer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        Task { await PricingService.shared.refresh() }
        refresh()
        installWakeObservers()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach { center.removeObserver($0) }
        wakeObservers.removeAll()
    }

    func refresh() {
        guard !viewModel.isRefreshing else { return }
        viewModel.isRefreshing = true
        let previousCodexQuota = viewModel.codex.quota
        let previousClaudeQuota = viewModel.claude.quota
        Task {
            async let codexState = codex.fetch()
            async let claudeState = claude.fetch()
            let (c, cl) = await (codexState, claudeState)
            let now = Date()
            viewModel.codex = c.preservingLiveQuota(from: previousCodexQuota, at: now)
            viewModel.claude = cl.preservingLiveQuota(from: previousClaudeQuota, at: now)
            viewModel.lastRefresh = Date()
            viewModel.isRefreshing = false
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
