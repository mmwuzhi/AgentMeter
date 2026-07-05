import AppKit
import Foundation

/// Drives periodic + manual refresh of all providers and publishes into the view model.
@MainActor
final class RefreshCoordinator {
    private let viewModel: AppViewModel
    private let codex = CodexService()
    private let claude = ClaudeService()
    private let copilot = CopilotService()
    private let backgroundMinimumRefreshInterval: TimeInterval = 15 * 60
    private let backgroundMinimumActiveAgentsRefreshInterval: TimeInterval = 5 * 60
    private var timer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?
    private var refreshStartedAt: Date?
    private var lastQuotaRefresh: [Provider: Date] = [:]
    private var lastUsageRefresh: [Provider: Date] = [:]
    private var lastActiveAgentsRefresh: Date?
    private var activeAgentsVisibleCount = 0

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
        seedBackgroundRefreshDates(at: Date())
        refresh(forceVisibleQuota: true)
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

    func refresh(
        forceAll: Bool = false,
        forceVisibleQuota: Bool = false,
        forceActiveAgents: Bool = false
    ) {
        // Coalesce concurrent refreshes, but never let a wedged fetch (e.g. a hung
        // network call) suppress refreshes forever — opening the popover must win.
        if viewModel.isRefreshing {
            guard let started = refreshStartedAt, Date().timeIntervalSince(started) > 30 else { return }
        }
        viewModel.isRefreshing = true
        let startedAt = Date()
        refreshStartedAt = startedAt
        let plan = refreshPlan(
            forceAll: forceAll,
            forceVisibleQuota: forceVisibleQuota,
            forceActiveAgents: forceActiveAgents,
            now: startedAt
        )
        let previousCodex = viewModel.codex
        let previousClaude = viewModel.claude
        let previousCopilot = viewModel.copilot
        let previousActiveAgents = viewModel.activeAgents
        let previousCodexQuota = viewModel.codex.quota
        let previousClaudeQuota = viewModel.claude.quota
        let previousCopilotQuota = viewModel.copilot.quota
        Task {
            async let codexState = fetchCodex(plan: plan, previous: previousCodex)
            async let claudeState = fetchClaude(plan: plan, previous: previousClaude)
            async let copilotState = fetchCopilot(plan: plan, previous: previousCopilot)
            async let activeAgents = fetchActiveAgents(plan: plan, previous: previousActiveAgents)
            let (c, cl, cp, agents) = await (codexState, claudeState, copilotState, activeAgents)
            let now = Date()
            var nextCodex = c
            if plan.refreshQuota.contains(.codex) {
                nextCodex = c.preservingLiveQuota(from: previousCodexQuota, at: now)
                viewModel.codexResetCreditState = CodexResetCreditTracker.reconcile(
                    existing: viewModel.codexResetCreditState,
                    quota: nextCodex.quota,
                    at: now
                )
                if nextCodex.quota.resetCreditsExpiresAt == nil,
                   let nearestExpiry = viewModel.codexResetCreditState.nearestExpiry {
                    nextCodex.quota = nextCodex.quota.withResetCreditsExpiresAt(nearestExpiry)
                }
            }
            viewModel.codex = nextCodex
            viewModel.claude = plan.refreshQuota.contains(.claude)
                ? cl.preservingLiveQuota(from: previousClaudeQuota, at: now)
                : cl
            viewModel.copilot = plan.refreshQuota.contains(.copilot)
                ? cp.preservingLiveQuota(from: previousCopilotQuota, at: now)
                : cp
            viewModel.activeAgents = agents
            markRefresh(plan: plan, at: startedAt)
            let quotaStates = [
                plan.refreshQuota.contains(.codex) ? viewModel.codex : nil,
                plan.refreshQuota.contains(.claude) ? viewModel.claude : nil,
                plan.refreshQuota.contains(.copilot) ? viewModel.copilot : nil,
            ].compactMap { $0 }
            viewModel.quotaObservations = QuotaTrendTracker.record(
                existing: viewModel.quotaObservations,
                states: quotaStates,
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
        refresh(forceVisibleQuota: true)
    }

    func setActiveAgentsVisible(_ visible: Bool) {
        if visible {
            activeAgentsVisibleCount += 1
        } else {
            activeAgentsVisibleCount = max(0, activeAgentsVisibleCount - 1)
        }
    }

    private func refreshPlan(
        forceAll: Bool,
        forceVisibleQuota: Bool,
        forceActiveAgents: Bool,
        now: Date
    ) -> ProviderRefreshPlan {
        if forceAll {
            return ProviderRefreshPlan(
                refreshQuota: Set(Provider.allCases),
                refreshUsage: [.codex, .claude],
                refreshActiveAgents: true
            )
        }

        let foregroundKinds = MenuBarLayout.activeRefreshKinds(viewModel)
        var quota = Set<Provider>()
        var usage = Set<Provider>()
        if forceVisibleQuota {
            for slot in MenuBarLayout.visibleSlots(viewModel) {
                quota.insert(slot.provider)
            }
        }
        for provider in Provider.allCases {
            let kinds = foregroundKinds[provider] ?? []
            if kinds.contains(.quota) || backgroundRefreshDue(provider: provider, lastRefreshes: lastQuotaRefresh, now: now) {
                quota.insert(provider)
            }
            guard provider != .copilot else { continue }
            if kinds.contains(.usage) || backgroundRefreshDue(provider: provider, lastRefreshes: lastUsageRefresh, now: now) {
                usage.insert(provider)
            }
        }
        let activeAgents = ActiveAgentRefreshPolicy.shouldRefresh(
            forceActiveAgents: forceActiveAgents,
            activeAgentsVisible: activeAgentsVisibleCount > 0,
            lastRefresh: lastActiveAgentsRefresh,
            refreshInterval: refreshInterval,
            backgroundMinimumRefreshInterval: backgroundMinimumActiveAgentsRefreshInterval,
            now: now
        )
        return ProviderRefreshPlan(
            refreshQuota: quota,
            refreshUsage: usage,
            refreshActiveAgents: activeAgents
        )
    }

    private func backgroundRefreshDue(
        provider: Provider,
        lastRefreshes: [Provider: Date],
        now: Date
    ) -> Bool {
        guard let last = lastRefreshes[provider] else { return true }
        let interval = max(refreshInterval, backgroundMinimumRefreshInterval)
        return now.timeIntervalSince(last) >= interval
    }

    private func seedBackgroundRefreshDates(at date: Date) {
        for provider in Provider.allCases {
            lastQuotaRefresh[provider] = date
            if provider != .copilot {
                lastUsageRefresh[provider] = date
            }
        }
        lastActiveAgentsRefresh = date
    }

    private func markRefresh(plan: ProviderRefreshPlan, at date: Date) {
        for provider in plan.refreshQuota {
            lastQuotaRefresh[provider] = date
        }
        for provider in plan.refreshUsage {
            lastUsageRefresh[provider] = date
        }
        if plan.refreshActiveAgents {
            lastActiveAgentsRefresh = date
        }
    }

    private func fetchCodex(plan: ProviderRefreshPlan, previous: ProviderState) async -> ProviderState {
        guard plan.refreshQuota.contains(.codex) || plan.refreshUsage.contains(.codex) else { return previous }
        return await codex.fetch(
            refreshQuota: plan.refreshQuota.contains(.codex),
            refreshUsage: plan.refreshUsage.contains(.codex),
            previous: previous
        )
    }

    private func fetchClaude(plan: ProviderRefreshPlan, previous: ProviderState) async -> ProviderState {
        guard plan.refreshQuota.contains(.claude) || plan.refreshUsage.contains(.claude) else { return previous }
        return await claude.fetch(
            refreshQuota: plan.refreshQuota.contains(.claude),
            refreshUsage: plan.refreshUsage.contains(.claude),
            previous: previous
        )
    }

    private func fetchCopilot(plan: ProviderRefreshPlan, previous: ProviderState) async -> ProviderState {
        guard plan.refreshQuota.contains(.copilot) else { return previous }
        return await copilot.fetch(refreshQuota: true, previous: previous)
    }

    private func fetchActiveAgents(plan: ProviderRefreshPlan, previous: [ActiveAgent]) async -> [ActiveAgent] {
        guard plan.refreshActiveAgents else { return previous }
        return await ActiveAgentService.fetch()
    }
}

struct ProviderRefreshPlan: Sendable {
    let refreshQuota: Set<Provider>
    let refreshUsage: Set<Provider>
    let refreshActiveAgents: Bool
}

enum ActiveAgentRefreshPolicy {
    static func shouldRefresh(
        forceActiveAgents: Bool,
        activeAgentsVisible: Bool,
        lastRefresh: Date?,
        refreshInterval: TimeInterval,
        backgroundMinimumRefreshInterval: TimeInterval,
        now: Date
    ) -> Bool {
        if forceActiveAgents || activeAgentsVisible { return true }
        guard let lastRefresh else { return true }
        let interval = max(refreshInterval, backgroundMinimumRefreshInterval)
        return now.timeIntervalSince(lastRefresh) >= interval
    }
}

extension ProviderState {
    func preservingLiveQuota(from previousQuota: QuotaSnapshot, at date: Date) -> ProviderState {
        guard shouldPreserve(previousQuota: previousQuota, at: date) else { return self }
        var state = self
        state.quota = previousQuota
        return state
    }

    private func shouldPreserve(previousQuota: QuotaSnapshot, at date: Date) -> Bool {
        guard previousQuota.hasUsableWindow(at: date) else { return false }
        if quota.source == .unavailable { return true }

        return provider == .codex
            && previousQuota.source == .appServer
            && quota.source == .rolloutFile
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
