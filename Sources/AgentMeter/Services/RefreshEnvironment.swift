import Foundation

/// Everything `RefreshCoordinator` reaches out to on a refresh, as closures,
/// so a test can stand in slow or failing providers and decide the order in
/// which they answer. `live()` is the app's wiring; nothing else in the app
/// builds one, and the coordination itself stays in the coordinator.
struct RefreshEnvironment: Sendable {
    var now: @Sendable () -> Date
    var fetchCodex: @Sendable (_ refreshQuota: Bool, _ refreshUsage: Bool, _ previous: ProviderState) async -> ProviderState
    /// Claude's live quota only; the returned state carries `previous.usage`.
    var fetchClaudeQuota: @Sendable (_ previous: ProviderState) async -> ProviderState
    /// Claude's limit-reset grants, read with the token the quota read cached.
    /// `attempted` is false when no request went out (no cached token, or the
    /// endpoint is rate-limiting), so the planner's reset clock is not held
    /// back by a cycle that sent nothing.
    var fetchClaudeResets: @Sendable () async -> (state: ClaudeResetState?, attempted: Bool)
    /// Claude's local usage scan: every log file when `completeHistory`, else
    /// the recent-file window.
    var fetchClaudeUsage: @Sendable (_ completeHistory: Bool) async -> UsageReport
    var fetchCopilot: @Sendable (_ previous: ProviderState) async -> ProviderState
    var fetchActiveAgents: @Sendable () async -> [ActiveAgent]
    var fetchCodexResetCredits: @Sendable () async -> [CodexResetCreditExpiry]?
    var fetchProviderStatus: @Sendable () async -> [Provider: ProviderStatusResult]
    var visibleSlots: @MainActor @Sendable (AppViewModel) -> [MenuBarSlot]
    var foregroundRefreshKinds: @MainActor @Sendable (AppViewModel) -> [Provider: Set<MenuBarRefreshKind>]
    var saveState: @MainActor @Sendable (StateCache.Snapshot) -> Void
    var saveLedger: @MainActor @Sendable ([LifetimeDayRecord]) -> Void
    var evaluateNotifications: @MainActor @Sendable (Provider, [QuotaWindow]) -> Void

    static func live() -> RefreshEnvironment {
        let codex = CodexService()
        let claude = ClaudeService()
        let copilot = CopilotService()
        return RefreshEnvironment(
            now: { Date() },
            fetchCodex: { refreshQuota, refreshUsage, previous in
                await codex.fetch(refreshQuota: refreshQuota, refreshUsage: refreshUsage, previous: previous)
            },
            fetchClaudeQuota: { previous in
                await claude.fetch(refreshQuota: true, refreshUsage: false, previous: previous)
            },
            fetchClaudeResets: {
                // The token the quota read left in the cache: no Keychain read
                // of its own. Joins a read another refresh has in flight, or
                // reuses one that succeeded within the last minute, rather
                // than sending a second.
                guard let token = await ClaudeCredentials.cachedToken(),
                      await ClaudeUsageGate.shared.blockedUntil() == nil else { return (nil, false) }
                let resets = await ClaudeUsageGate.shared.readResets {
                    try? await ClaudeResetGrantFetcher.fetch(token: token)
                }
                return (resets, true)
            },
            fetchClaudeUsage: { completeHistory in
                await ClaudeJSONLScanner.usageReport(completeHistory: completeHistory)
            },
            fetchCopilot: { previous in
                await copilot.fetch(refreshQuota: true, previous: previous)
            },
            fetchActiveAgents: { await ActiveAgentService.fetch() },
            fetchCodexResetCredits: { try? await CodexResetCreditFetcher.fetch() },
            fetchProviderStatus: { await ProviderStatusService.fetchAll() },
            visibleSlots: { MenuBarLayout.visibleSlots($0) },
            foregroundRefreshKinds: { MenuBarLayout.activeRefreshKinds($0) },
            saveState: { StateCache.save($0) },
            saveLedger: { LifetimeSpendStore.save($0) },
            evaluateNotifications: { NotificationManager.shared.evaluate(provider: $0, windows: $1) }
        )
    }
}
