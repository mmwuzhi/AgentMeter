import AppKit
import Foundation

/// Drives periodic + manual refresh of all providers and publishes into the view model.
@MainActor
final class RefreshCoordinator {
    private let viewModel: AppViewModel
    private let environment: RefreshEnvironment
    private let backgroundMinimumRefreshInterval: TimeInterval = 15 * 60
    private let backgroundMinimumActiveAgentsRefreshInterval: TimeInterval = 5 * 60
    /// Reset credits are granted/expire on the order of days, not minutes — throttled
    /// separately (and much lower) than quota so this undocumented endpoint isn't hit
    /// every refresh tick.
    private let resetCreditsMinimumRefreshInterval: TimeInterval = 20 * 60
    /// Provider incidents don't need near-real-time freshness, and this is three
    /// more outbound requests per tick if left unthrottled — deliberately generous
    /// so it doesn't erode the resource savings from the Codex HTTPS quota path.
    private let providerStatusMinimumRefreshInterval: TimeInterval = 30 * 60
    private var timer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?
    private var refreshStartedAt: Date?
    private var lastQuotaRefresh: [Provider: Date] = [:]
    private var lastUsageRefresh: [Provider: Date] = [:]
    private var lastActiveAgentsRefresh: Date?
    private var lastResetCreditsRefresh: Date?
    private var lastClaudeResetsRefresh: Date?
    private var lastProviderStatusRefresh: Date?
    private var activeAgentsVisibleCount = 0
    private var pendingRefreshRequest = ProviderRefreshRequest()
    private var quotaFailureStreaks: [Provider: Int] = [:]
    /// While a popover is open, Claude Code's session registry and the hook
    /// files are re-read on this cadence and re-attached to the rows the last
    /// full refresh built (`ActiveAgentService.refreshStatuses`): a dozen
    /// small files, no `ps`, `lsof`, quota request or transcript scan. The
    /// registry moves the moment a prompt is answered or a turn is
    /// interrupted; the timer-driven refresh would show that up to a minute
    /// later, and only together with everything else it fetches.
    private let localStatusRefreshInterval: TimeInterval = 2
    private var localStatusTimer: Timer?
    private var localStatusRefreshInFlight = false
    /// Claude's usage scan runs apart from the refresh that asked for it: the
    /// first one after launch reads every log file and used to hold quota,
    /// reset grants and other providers’ results until the scan finished. One scan at a time: a refresh that wants usage while one is in
    /// flight takes that scan's result instead of reading the same files
    /// beside it, and the result lands through `applyClaudeUsage` whenever
    /// it is ready, whether or not the refresh that started it was superseded.
    private var claudeUsageScan: Task<Void, Never>?
    private var claudeUsageScanGeneration = 0
    /// When a complete-history report last landed this process. Nil until one
    /// has, so the first scan after launch reads everything, and a complete
    /// scan whose result never applied does not push the next one out.
    private var lastClaudeCompleteScanLanded: Date?

    init(viewModel: AppViewModel, environment: RefreshEnvironment = .live()) {
        self.viewModel = viewModel
        self.environment = environment
    }

    /// Refresh cadence in seconds, from Settings (clamped to 15…3600). Default 60.
    private var refreshInterval: TimeInterval {
        let v = UserDefaults.standard.object(forKey: "refreshIntervalSeconds") as? Double ?? 60
        return max(15, min(3600, v))
    }

    func start() {
        Task {
            await PricingService.shared.refresh()
            // Every figure on screen is priced under the view model's table, so
            // the network table reaches the UI here, once, and not through any
            // stored dollar amount.
            viewModel.priceTable = await PricingService.shared.snapshot()
        }
        // Notification permission is requested lazily by NotificationManager
        // the first time an alert actually needs to fire, not at launch.
        seedBackgroundRefreshDates(at: environment.now())
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
        evaluateNotifications()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopLocalStatusTimer()
        // The process is ending: a scan still running lands nothing.
        claudeUsageScanGeneration += 1
        claudeUsageScan = nil
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
        forcedUsageProviders: Set<Provider> = [],
        forceActiveAgents: Bool = false
    ) {
        let request = ProviderRefreshRequest(
            forceAll: forceAll,
            forceVisibleQuota: forceVisibleQuota,
            forcedUsageProviders: forcedUsageProviders,
            forceActiveAgents: forceActiveAgents
        )
        // Coalesce concurrent refreshes, but never let a wedged fetch (e.g. a hung
        // network call) suppress refreshes forever — opening the popover must win.
        if viewModel.isRefreshing {
            guard let started = refreshStartedAt, environment.now().timeIntervalSince(started) > 30 else {
                pendingRefreshRequest.merge(request)
                return
            }
        }
        viewModel.isRefreshing = true
        let startedAt = environment.now()
        refreshStartedAt = startedAt
        let plan = refreshPlan(
            request: request,
            now: startedAt
        )
        // Not awaited below: the scan lands on its own, and this refresh is
        // over when the live reads are.
        if plan.refreshUsage.contains(.claude) {
            startClaudeUsageScan(at: startedAt)
        }
        let previousCodex = viewModel.codex
        let previousClaude = viewModel.claude
        let previousCopilot = viewModel.copilot
        let previousActiveAgents = viewModel.activeAgents
        let previousCodexQuota = viewModel.codex.quota
        let previousClaudeQuota = viewModel.claude.quota
        let previousCopilotQuota = viewModel.copilot.quota
        Task {
            async let codexState = fetchCodex(plan: plan, previous: previousCodex)
            async let claudeState = fetchClaudeWithResets(plan: plan, previous: previousClaude)
            async let copilotState = fetchCopilot(plan: plan, previous: previousCopilot)
            async let activeAgents = fetchActiveAgents(plan: plan, previous: previousActiveAgents)
            async let realResetCredits = fetchCodexResetCredits(plan: plan)
            async let statusResult = fetchProviderStatus(plan: plan)
            let (c, claudeResult, cp, agents, resetCredits, status) = await (
                codexState, claudeState, copilotState, activeAgents, realResetCredits, statusResult
            )
            let (cl, claudeResets, claudeResetsAttempted) = claudeResult
            // The 30 s escape above can start a second refresh beside a stalled
            // one. Only the latest-started refresh may land: a superseded one that
            // finishes later would replay older windows as a rise (the trend
            // tracker stamps samples at landing time), move the refresh markers
            // backwards and overwrite the cache with the older snapshots.
            guard refreshStartedAt == startedAt else { return }
            let now = environment.now()
            if let status {
                viewModel.providerStatus = Self.mergeProviderStatus(viewModel.providerStatus, with: status)
            }
            var nextCodex = c
            if plan.refreshQuota.contains(.codex) {
                nextCodex = c.preservingLiveQuota(from: previousCodexQuota, at: now)
                if let resetCredits {
                    // Real per-credit grant/expiry from ChatGPT's backend always wins
                    // over local inference.
                    viewModel.codexResetCreditState = CodexResetCreditState(
                        lastObservedCount: resetCredits.count,
                        credits: resetCredits
                    )
                } else {
                    viewModel.codexResetCreditState = CodexResetCreditTracker.reconcile(
                        existing: viewModel.codexResetCreditState,
                        quota: nextCodex.quota,
                        at: now
                    )
                }
                if nextCodex.quota.resetCreditsExpiresAt == nil,
                   let nearestExpiry = viewModel.codexResetCreditState.nearestExpiry {
                    nextCodex.quota = nextCodex.quota.withResetCreditsExpiresAt(nearestExpiry)
                }
            }
            viewModel.codex = nextCodex
            // nil means not read this cycle or the read failed: keep the last
            // answer. An empty state is a real answer and clears the line.
            if let claudeResets {
                viewModel.claudeResetState = claudeResets
            }
            var nextClaude = plan.refreshQuota.contains(.claude)
                ? cl.preservingLiveQuota(from: previousClaudeQuota, at: now)
                : cl
            // The usage scan lands on its own, possibly while this refresh
            // was waiting on the network: keep what is on screen now, not the
            // usage this refresh captured when it started.
            nextClaude.usage = viewModel.claude.usage
            viewModel.claude = nextClaude
            viewModel.copilot = plan.refreshQuota.contains(.copilot)
                ? cp.preservingLiveQuota(from: previousCopilotQuota, at: now)
                : cp
            viewModel.activeAgents = agents
            viewModel.pruneSessionDisclosure(
                keeping: ActiveAgentGrouping.disclosureKeys(for: ActiveAgentGrouping.group(agents)))
            updateQuotaStaleness(plan: plan, rawResults: [.codex: c, .claude: cl, .copilot: cp])
            // Any successful Claude quota source retires the Keychain primer:
            // OAuth means the prompt was answered, CLI never needs it.
            if viewModel.claudeKeychainPrimerNeeded, viewModel.claude.quota.source != .unavailable {
                viewModel.claudeKeychainPrimerNeeded = false
                UserDefaults.standard.set(true, forKey: "claudeOAuthSucceededOnce")
            }
            markRefresh(plan: plan, claudeResetsAttempted: claudeResetsAttempted, at: startedAt)
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
            mergeSpendLedger()
            viewModel.lastRefresh = environment.now()
            // Cache for the next launch so the menu bar shows last values instantly.
            persistState()
            evaluateNotifications()
            finishRefresh(startedAt: startedAt)
        }
    }

    /// Starts Claude's usage scan unless one is already running, in which
    /// case the refresh that asked takes that scan's result: the files would
    /// be the same, and two scans beside each other parsed every uncached
    /// file twice. Whether this one reads every file is decided here, not in
    /// the scanner, so the clock only moves once such a report has landed.
    private func startClaudeUsageScan(at now: Date) {
        guard claudeUsageScan == nil else { return }
        let completeHistory = Self.claudeCompleteHistoryDue(
            lastLanded: lastClaudeCompleteScanLanded,
            now: now,
            interval: ClaudeJSONLScanner.fullHistoryInterval
        )
        claudeUsageScanGeneration += 1
        let generation = claudeUsageScanGeneration
        let fetch = environment.fetchClaudeUsage
        claudeUsageScan = Task {
            let report = await fetch(completeHistory)
            // `stop()` retired this scan.
            guard generation == claudeUsageScanGeneration else { return }
            claudeUsageScan = nil
            applyClaudeUsage(report)
        }
    }

    /// The first scan after launch reads every file: a fresh process has no
    /// ledger-correcting read behind it. After that, one every
    /// `ClaudeJSONLScanner.fullHistoryInterval`, counted from the last one
    /// that landed.
    nonisolated static func claudeCompleteHistoryDue(
        lastLanded: Date?,
        now: Date,
        interval: TimeInterval
    ) -> Bool {
        guard let lastLanded else { return true }
        return now.timeIntervalSince(lastLanded) >= interval
    }

    /// Lands a usage report on whatever Claude quota is on screen now — a
    /// refresh that finished while the scan ran is not undone — and carries it
    /// into the spend ledger and the cache, as the refresh used to. Quota
    /// observations, staleness and notifications are the live reads' business
    /// and are not touched: nothing here changes a window.
    private func applyClaudeUsage(_ report: UsageReport) {
        var state = viewModel.claude
        state.usage = report
        viewModel.claude = state
        if report.isCompleteHistory {
            lastClaudeCompleteScanLanded = environment.now()
        }
        mergeSpendLedger()
        persistState()
    }

    private func mergeSpendLedger() {
        viewModel.lifetimeSpend = LifetimeSpendTracker.merge(
            existing: viewModel.lifetimeSpend,
            reports: [viewModel.codex.usage, viewModel.claude.usage],
            table: viewModel.priceTable
        )
        environment.saveLedger(viewModel.lifetimeSpend)
    }

    private func persistState() {
        environment.saveState(StateCache.Snapshot(
            codex: viewModel.codex,
            claude: viewModel.claude,
            copilot: viewModel.copilot,
            quotaObservations: viewModel.quotaObservations,
            codexResetCreditState: viewModel.codexResetCreditState,
            claudeResetState: viewModel.claudeResetState,
            lifetimeSpend: viewModel.lifetimeSpend
        ))
    }

    private func evaluateNotifications() {
        environment.evaluateNotifications(.codex, viewModel.codex.quota.windows)
        environment.evaluateNotifications(.claude, viewModel.claude.quota.windows)
        environment.evaluateNotifications(.copilot, viewModel.copilot.quota.windows)
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
        if activeAgentsVisibleCount > 0 {
            startLocalStatusTimer()
        } else {
            stopLocalStatusTimer()
        }
    }

    private func startLocalStatusTimer() {
        guard localStatusTimer == nil else { return }
        let timer = Timer(timeInterval: localStatusRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActiveAgentStatusesLocally() }
        }
        // Common modes, so the tick keeps coming while the popover tracks
        // the mouse.
        RunLoop.main.add(timer, forMode: .common)
        localStatusTimer = timer
    }

    private func stopLocalStatusTimer() {
        localStatusTimer?.invalidate()
        localStatusTimer = nil
    }

    private func refreshActiveAgentStatusesLocally() {
        guard activeAgentsVisibleCount > 0, !localStatusRefreshInFlight else { return }
        let snapshot = viewModel.activeAgents
        guard !snapshot.isEmpty else { return }
        localStatusRefreshInFlight = true
        Task {
            let updated = await ActiveAgentService.refreshStatuses(snapshot)
            localStatusRefreshInFlight = false
            // A full refresh that landed meanwhile built newer rows, and these
            // were derived from the old ones: drop them, the next tick starts
            // from the new list.
            guard activeAgentsVisibleCount > 0, viewModel.activeAgents == snapshot, updated != snapshot else { return }
            viewModel.activeAgents = updated
            viewModel.pruneSessionDisclosure(
                keeping: ActiveAgentGrouping.disclosureKeys(for: ActiveAgentGrouping.group(updated)))
        }
    }

    private func refreshPlan(
        request: ProviderRefreshRequest,
        now: Date
    ) -> ProviderRefreshPlan {
        ProviderRefreshPlan.make(
            forceAll: request.forceAll,
            forceVisibleQuota: request.forceVisibleQuota,
            forcedUsageProviders: request.forcedUsageProviders,
            forceActiveAgents: request.forceActiveAgents,
            now: now,
            visibleSlots: environment.visibleSlots(viewModel),
            foregroundKinds: environment.foregroundRefreshKinds(viewModel),
            lastQuotaRefresh: lastQuotaRefresh,
            lastLiveQuotaFetch: lastLiveQuotaFetch,
            lastUsageRefresh: lastUsageRefresh,
            lastActiveAgentsRefresh: lastActiveAgentsRefresh,
            activeAgentsVisible: activeAgentsVisibleCount > 0,
            refreshInterval: refreshInterval,
            backgroundMinimumRefreshInterval: backgroundMinimumRefreshInterval,
            backgroundMinimumActiveAgentsRefreshInterval: backgroundMinimumActiveAgentsRefreshInterval,
            lastResetCreditsRefresh: lastResetCreditsRefresh,
            resetCreditsMinimumRefreshInterval: resetCreditsMinimumRefreshInterval,
            lastClaudeResetsRefresh: lastClaudeResetsRefresh,
            lastProviderStatusRefresh: lastProviderStatusRefresh,
            providerStatusMinimumRefreshInterval: providerStatusMinimumRefreshInterval
        )
    }

    /// When each provider's on-screen quota was last read live, for
    /// `ProviderRefreshPlan.minimumForcedQuotaSpacing`. `.unavailable` carries
    /// no reading, and a snapshot `preservingLiveQuota` kept across a failed
    /// fetch keeps its old `fetchedAt`, so a failing provider is never held back.
    private var lastLiveQuotaFetch: [Provider: Date] {
        var fetches: [Provider: Date] = [:]
        for state in [viewModel.codex, viewModel.claude, viewModel.copilot]
        where state.quota.source != .unavailable {
            fetches[state.provider] = state.quota.fetchedAt
        }
        return fetches
    }

    private func finishRefresh(startedAt: Date) {
        guard refreshStartedAt == startedAt else { return }
        viewModel.isRefreshing = false
        refreshStartedAt = nil

        let request = pendingRefreshRequest
        pendingRefreshRequest = ProviderRefreshRequest()
        guard request.requiresRefresh else { return }
        refresh(
            forceAll: request.forceAll,
            forceVisibleQuota: request.forceVisibleQuota,
            forcedUsageProviders: request.forcedUsageProviders,
            forceActiveAgents: request.forceActiveAgents
        )
    }

    private func seedBackgroundRefreshDates(at date: Date) {
        for provider in Provider.allCases {
            lastQuotaRefresh[provider] = date
            if provider != .copilot {
                lastUsageRefresh[provider] = date
            }
        }
        lastActiveAgentsRefresh = date
        // Deliberately not seeded: leaving them nil makes the very first refresh (right
        // after launch) treat Codex reset credits and Claude reset grants as due, same
        // as a never-yet-fetched provider.
    }

    /// `claudeResetsAttempted` rather than the plan decides the Claude reset
    /// clock: a cycle whose quota read failed sent no reset request, and should
    /// not hold the next attempt back 20 minutes.
    private func markRefresh(plan: ProviderRefreshPlan, claudeResetsAttempted: Bool, at date: Date) {
        for provider in plan.refreshQuota {
            lastQuotaRefresh[provider] = date
        }
        for provider in plan.refreshUsage {
            lastUsageRefresh[provider] = date
        }
        if plan.refreshActiveAgents {
            lastActiveAgentsRefresh = date
        }
        if plan.refreshResetCredits {
            lastResetCreditsRefresh = date
        }
        if claudeResetsAttempted {
            lastClaudeResetsRefresh = date
        }
        if plan.refreshProviderStatus {
            lastProviderStatusRefresh = date
        }
    }

    private func fetchCodex(plan: ProviderRefreshPlan, previous: ProviderState) async -> ProviderState {
        guard plan.refreshQuota.contains(.codex) || plan.refreshUsage.contains(.codex) else { return previous }
        return await environment.fetchCodex(
            plan.refreshQuota.contains(.codex),
            plan.refreshUsage.contains(.codex),
            previous
        )
    }

    /// The live quota only. Usage is `startClaudeUsageScan`'s, whatever the
    /// plan says about it, so the state that comes back carries the usage it
    /// was handed.
    private func fetchClaude(plan: ProviderRefreshPlan, previous: ProviderState) async -> ProviderState {
        guard plan.refreshQuota.contains(.claude) else { return previous }
        return await environment.fetchClaudeQuota(previous)
    }

    /// Claude quota, then its limit-reset grants right behind it — not behind
    /// the usage scan. The flag says whether a reset request went out at all.
    private func fetchClaudeWithResets(
        plan: ProviderRefreshPlan,
        previous: ProviderState
    ) async -> (ProviderState, ClaudeResetState?, Bool) {
        let state = await fetchClaude(plan: plan, previous: previous)
        guard Self.shouldReadClaudeResets(plan: plan, quotaSource: state.quota.source) else {
            return (state, nil, false)
        }
        let resets = await environment.fetchClaudeResets()
        return (state, resets.state, resets.attempted)
    }

    /// Only after an OAuth quota read that succeeded this cycle: never on a
    /// token that just failed, and never right behind a 429 (`.unavailable`)
    /// or a CLI fallback, where a second `/api/oauth/usage` call would only
    /// deepen the rate limit.
    nonisolated static func shouldReadClaudeResets(
        plan: ProviderRefreshPlan,
        quotaSource: QuotaSnapshot.SourceKind
    ) -> Bool {
        plan.refreshClaudeResets && plan.refreshQuota.contains(.claude) && quotaSource == .oauth
    }

    private func fetchCopilot(plan: ProviderRefreshPlan, previous: ProviderState) async -> ProviderState {
        guard plan.refreshQuota.contains(.copilot) else { return previous }
        return await environment.fetchCopilot(previous)
    }

    private func fetchActiveAgents(plan: ProviderRefreshPlan, previous: [ActiveAgent]) async -> [ActiveAgent] {
        guard plan.refreshActiveAgents else { return previous }
        return await environment.fetchActiveAgents()
    }

    /// Best-effort: nil on any failure (no login, 401, unparsable body, offline) so
    /// the caller falls back to `CodexResetCreditTracker`'s local-inference reconcile.
    private func fetchCodexResetCredits(plan: ProviderRefreshPlan) async -> [CodexResetCreditExpiry]? {
        guard plan.refreshResetCredits else { return nil }
        return await environment.fetchCodexResetCredits()
    }

    /// Best-effort: nil when this cycle isn't due, in which case the caller leaves
    /// `viewModel.providerStatus` untouched rather than clearing it.
    private func fetchProviderStatus(plan: ProviderRefreshPlan) async -> [Provider: ProviderStatusResult]? {
        guard plan.refreshProviderStatus else { return nil }
        return await environment.fetchProviderStatus()
    }

    /// Marks providers whose fetch failed this cycle while the UI kept showing
    /// the previously fetched live quota, and clears the mark on success. Only
    /// providers whose quota was actually attempted this cycle change state.
    private func updateQuotaStaleness(plan: ProviderRefreshPlan, rawResults: [Provider: ProviderState]) {
        for (provider, raw) in rawResults where plan.refreshQuota.contains(provider) {
            let shown: ProviderState
            switch provider {
            case .codex: shown = viewModel.codex
            case .claude: shown = viewModel.claude
            case .copilot: shown = viewModel.copilot
            }
            let streak = Self.nextQuotaFailureStreak(
                previous: quotaFailureStreaks[provider] ?? 0,
                rawSource: raw.quota.source,
                shownSource: shown.quota.source
            )
            quotaFailureStreaks[provider] = streak
            if streak >= Self.staleQuotaFailureThreshold {
                viewModel.staleQuotaProviders.insert(provider)
            } else {
                viewModel.staleQuotaProviders.remove(provider)
            }
        }
    }

    /// A single failed cycle is usually a transient blip (proxy hiccup, timeout,
    /// rate limit); only consecutive failures warrant the stale warning.
    nonisolated static let staleQuotaFailureThreshold = 2

    nonisolated static func nextQuotaFailureStreak(
        previous: Int,
        rawSource: QuotaSnapshot.SourceKind,
        shownSource: QuotaSnapshot.SourceKind
    ) -> Int {
        isQuotaStale(rawSource: rawSource, shownSource: shownSource) ? previous + 1 : 0
    }

    /// Stale = the fresh fetch came back unavailable but the UI is showing a
    /// usable (older) snapshot preserved by `preservingLiveQuota`. A provider
    /// that is genuinely unavailable (nothing preserved) is not stale — the UI
    /// already says "unavailable" explicitly there.
    nonisolated static func isQuotaStale(
        rawSource: QuotaSnapshot.SourceKind,
        shownSource: QuotaSnapshot.SourceKind
    ) -> Bool {
        rawSource == .unavailable && shownSource != .unavailable
    }

    /// Merges this cycle's results into the existing map instead of replacing it
    /// wholesale — one provider's transient poll failure (a single timeout or
    /// non-200) must not erase the other two providers' just-fetched results, nor
    /// regress a provider that failed this cycle back to "unknown" when its last
    /// known status is still the best information available.
    nonisolated static func mergeProviderStatus(
        _ existing: [Provider: ProviderStatusResult],
        with update: [Provider: ProviderStatusResult]
    ) -> [Provider: ProviderStatusResult] {
        var result = existing
        for (provider, value) in update {
            result[provider] = value
        }
        return result
    }
}

struct ProviderRefreshRequest: Sendable {
    var forceAll = false
    var forceVisibleQuota = false
    var forcedUsageProviders: Set<Provider> = []
    var forceActiveAgents = false

    var requiresRefresh: Bool {
        forceAll || forceVisibleQuota || !forcedUsageProviders.isEmpty || forceActiveAgents
    }

    mutating func merge(_ other: ProviderRefreshRequest) {
        forceAll = forceAll || other.forceAll
        forceVisibleQuota = forceVisibleQuota || other.forceVisibleQuota
        forcedUsageProviders.formUnion(other.forcedUsageProviders)
        forceActiveAgents = forceActiveAgents || other.forceActiveAgents
    }
}

struct ProviderRefreshPlan: Sendable {
    let refreshQuota: Set<Provider>
    let refreshUsage: Set<Provider>
    let refreshActiveAgents: Bool
    let refreshResetCredits: Bool
    /// Claude limit-reset grants, on the same 20-minute cadence as Codex's
    /// reset credits and only when Claude quota is read this cycle.
    let refreshClaudeResets: Bool
    let refreshProviderStatus: Bool

    /// Forced quota reads skip recent successful fetches. Other refresh work
    /// still runs, and manual refresh applies the interval only to Claude.
    static let minimumForcedQuotaSpacing: TimeInterval = 20

    /// "Refresh now" still reads Claude's reset grants, but not twice within
    /// this long: each read is a second `/api/oauth/usage` request behind the
    /// quota one, and overlapping refreshes can trigger HTTP 429. Grants change
    /// on a scale of days, so a refresh that skips them loses nothing.
    static let minimumForcedClaudeResetsSpacing: TimeInterval = 60

    static func make(
        forceAll: Bool,
        forceVisibleQuota: Bool,
        forcedUsageProviders: Set<Provider>,
        forceActiveAgents: Bool,
        now: Date,
        visibleSlots: [MenuBarSlot],
        foregroundKinds: [Provider: Set<MenuBarRefreshKind>],
        lastQuotaRefresh: [Provider: Date],
        lastLiveQuotaFetch: [Provider: Date] = [:],
        lastUsageRefresh: [Provider: Date],
        lastActiveAgentsRefresh: Date?,
        activeAgentsVisible: Bool,
        refreshInterval: TimeInterval,
        backgroundMinimumRefreshInterval: TimeInterval,
        backgroundMinimumActiveAgentsRefreshInterval: TimeInterval,
        lastResetCreditsRefresh: Date?,
        resetCreditsMinimumRefreshInterval: TimeInterval,
        lastClaudeResetsRefresh: Date? = nil,
        lastProviderStatusRefresh: Date?,
        providerStatusMinimumRefreshInterval: TimeInterval
    ) -> ProviderRefreshPlan {
        if forceAll {
            var quota = Set(Provider.allCases)
            // "Refresh now" is not held back for Codex or Copilot, but a Claude
            // reading younger than the forced-refresh spacing is not read
            // again: a double click, or a click queued behind a running refresh
            // that then replays at once, sent two reads close together
            // before a rate-limit response.
            if let fetchedAt = lastLiveQuotaFetch[.claude],
               now.timeIntervalSince(fetchedAt) < minimumForcedQuotaSpacing {
                quota.remove(.claude)
            }
            return ProviderRefreshPlan(
                refreshQuota: quota,
                refreshUsage: [.codex, .claude],
                refreshActiveAgents: true,
                refreshResetCredits: true,
                refreshClaudeResets: quota.contains(.claude) && (lastClaudeResetsRefresh.map {
                    now.timeIntervalSince($0) >= minimumForcedClaudeResetsSpacing
                } ?? true),
                refreshProviderStatus: true
            )
        }

        var quota = Set<Provider>()
        var usage = Set<Provider>()
        if forceVisibleQuota {
            for slot in visibleSlots {
                quota.insert(slot.provider)
            }
        }
        for provider in forcedUsageProviders where provider != .copilot {
            usage.insert(provider)
        }
        for provider in Provider.allCases {
            let kinds = foregroundKinds[provider] ?? []
            if kinds.contains(.quota)
                || Self.backgroundRefreshDue(
                    provider: provider,
                    lastRefreshes: lastQuotaRefresh,
                    now: now,
                    refreshInterval: refreshInterval,
                    backgroundMinimumRefreshInterval: backgroundMinimumRefreshInterval
                ) {
                quota.insert(provider)
            }
            guard provider != .copilot else { continue }
            if kinds.contains(.usage)
                || Self.backgroundRefreshDue(
                    provider: provider,
                    lastRefreshes: lastUsageRefresh,
                    now: now,
                    refreshInterval: refreshInterval,
                    backgroundMinimumRefreshInterval: backgroundMinimumRefreshInterval
                ) {
                usage.insert(provider)
            }
        }
        if forceVisibleQuota {
            for (provider, fetchedAt) in lastLiveQuotaFetch
            where now.timeIntervalSince(fetchedAt) < minimumForcedQuotaSpacing {
                quota.remove(provider)
            }
        }
        let activeAgents = ActiveAgentRefreshPolicy.shouldRefresh(
            forceActiveAgents: forceActiveAgents,
            activeAgentsVisible: activeAgentsVisible,
            lastRefresh: lastActiveAgentsRefresh,
            refreshInterval: refreshInterval,
            backgroundMinimumRefreshInterval: backgroundMinimumActiveAgentsRefreshInterval,
            now: now
        )
        // Only worth asking when Codex quota is already due this cycle — no point
        // hitting a second endpoint for a panel that isn't being refreshed anyway.
        let resetCredits = quota.contains(.codex) && (
            lastResetCreditsRefresh.map { now.timeIntervalSince($0) >= resetCreditsMinimumRefreshInterval } ?? true
        )
        let claudeResets = quota.contains(.claude) && (
            lastClaudeResetsRefresh.map { now.timeIntervalSince($0) >= resetCreditsMinimumRefreshInterval } ?? true
        )
        // Only worth asking when some quota refresh is due this cycle anyway — same
        // "don't fetch for a panel that isn't refreshing" rule as reset credits.
        let providerStatus = !quota.isEmpty && (
            lastProviderStatusRefresh.map { now.timeIntervalSince($0) >= providerStatusMinimumRefreshInterval } ?? true
        )
        return ProviderRefreshPlan(
            refreshQuota: quota,
            refreshUsage: usage,
            refreshActiveAgents: activeAgents,
            refreshResetCredits: resetCredits,
            refreshClaudeResets: claudeResets,
            refreshProviderStatus: providerStatus
        )
    }

    private static func backgroundRefreshDue(
        provider: Provider,
        lastRefreshes: [Provider: Date],
        now: Date,
        refreshInterval: TimeInterval,
        backgroundMinimumRefreshInterval: TimeInterval
    ) -> Bool {
        guard let last = lastRefreshes[provider] else { return true }
        let interval = max(refreshInterval, backgroundMinimumRefreshInterval)
        return now.timeIntervalSince(last) >= interval
    }
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
        var state = self
        if quota.source == .unavailable {
            guard previousQuota.hasUsableWindow(at: date) else { return self }
            state.quota = previousQuota
            return state
        }
        guard provider == .codex else { return self }
        if quota.source.hasHigherCodexAuthority(than: previousQuota.source) {
            return self
        }
        if quota.source.hasLowerCodexAuthority(than: previousQuota.source) {
            state.quota = quota.preservingHigherAuthoritySameEpochWindows(
                from: previousQuota,
                at: date
            )
            return state
        }
        state.quota = quota.preservingSameEpochRecoverySpikes(from: previousQuota, at: date)
        return state
    }
}

extension QuotaSnapshot.SourceKind {
    private var codexAuthority: Int? {
        switch self {
        case .oauth: return 3
        case .appServer: return 2
        case .rolloutFile: return 1
        case .cli, .unavailable: return nil
        }
    }

    func hasHigherCodexAuthority(than other: Self) -> Bool {
        guard let authority = codexAuthority, let otherAuthority = other.codexAuthority else { return false }
        return authority > otherAuthority
    }

    func hasLowerCodexAuthority(than other: Self) -> Bool {
        guard let authority = codexAuthority, let otherAuthority = other.codexAuthority else { return false }
        return authority < otherAuthority
    }
}

extension QuotaSnapshot {
    func hasUsableWindow(at date: Date) -> Bool {
        windows.contains { window in
            guard let resetsAt = window.resetsAt else { return true }
            return resetsAt > date
        }
    }

    func preservingSameEpochRecoverySpikes(from previous: QuotaSnapshot, at date: Date) -> QuotaSnapshot {
        guard provider == .codex, previous.provider == provider else { return self }
        if let previousCredits = previous.resetCreditsAvailable,
           let currentCredits = resetCreditsAvailable,
           currentCredits < previousCredits {
            return self
        }
        var changed = false
        let mergedWindows = windows.map { window in
            guard let previousWindow = previous.windows.first(where: { $0.id == window.id }),
                  window.isSameEpochRecoverySpike(from: previousWindow, at: date) else {
                return window
            }
            changed = true
            return previousWindow
        }
        guard changed else { return self }
        return QuotaSnapshot(
            provider: provider,
            windows: mergedWindows,
            source: source,
            planType: planType,
            rateLimitTier: rateLimitTier,
            resetCreditsAvailable: resetCreditsAvailable,
            resetCreditsExpiresAt: resetCreditsExpiresAt,
            extraUsageSpentUSD: extraUsageSpentUSD,
            fetchedAt: fetchedAt,
            note: note
        )
    }

    func preservingHigherAuthoritySameEpochWindows(
        from previous: QuotaSnapshot,
        at date: Date
    ) -> QuotaSnapshot {
        guard provider == .codex, previous.provider == provider else { return self }
        var changed = false
        let mergedWindows = windows.map { window in
            guard let previousWindow = previous.windows.first(where: { $0.id == window.id }),
                  window.hasSameUsableEpoch(as: previousWindow, at: date) else {
                return window
            }
            changed = true
            return previousWindow
        }
        guard changed else { return self }
        return QuotaSnapshot(
            provider: provider,
            windows: mergedWindows,
            source: source,
            planType: planType,
            rateLimitTier: rateLimitTier,
            resetCreditsAvailable: resetCreditsAvailable,
            resetCreditsExpiresAt: resetCreditsExpiresAt,
            extraUsageSpentUSD: extraUsageSpentUSD,
            fetchedAt: fetchedAt,
            note: note
        )
    }
}

extension QuotaWindow {
    /// How far two readings' `resetsAt` may drift apart and still describe
    /// one epoch. Shared with `QuotaNotificationPolicy`, so the display and
    /// the alerts agree on when a window has reset.
    static let sameEpochTolerance: TimeInterval = 5 * 60

    func hasSameUsableEpoch(as previous: QuotaWindow, at date: Date) -> Bool {
        guard id == previous.id,
              let previousReset = previous.resetsAt,
              let currentReset = resetsAt,
              previousReset > date,
              abs(currentReset.timeIntervalSince(previousReset)) <= Self.sameEpochTolerance else {
            return false
        }
        return true
    }

    func isSameEpochRecoverySpike(from previous: QuotaWindow, at date: Date) -> Bool {
        let recoveryJitterTolerance = 2.0
        guard hasSameUsableEpoch(as: previous, at: date) else { return false }
        return remainingPercent > previous.remainingPercent + recoveryJitterTolerance
    }
}
