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
    /// Hands the history one provider's raw quota reading as it landed, with
    /// the landing time. Called from the landing block, synchronously and
    /// without suspending, only for a reading this cycle really fetched (not
    /// `.unavailable`, not a plan-skipped provider, not a stale cache echo, not
    /// a superseded refresh); the store applies the provider allowlist. The
    /// default records nothing, so a test that builds the environment by hand
    /// stays off any database.
    var recordQuotaReading: @Sendable (QuotaSnapshot, Date) -> Void = { _, _ in }
    /// Hands the history the `quotaObservations` an earlier build restored from
    /// `last-state.json`, once, at start. The store imports them once per
    /// database. Default: nothing.
    var importLegacyQuota: @Sendable ([QuotaObservation]) -> Void = { _ in }
    /// Hands the history Claude's current limit-reset grant set as of the
    /// landing time (`ResetGrantObservation.observations(from:)` maps it). Called
    /// from the landing block, synchronously, after the supersede guard, and
    /// only when this cycle read the grants (a nil state means not read, or the
    /// read failed). An empty set is a real answer and is passed; the store
    /// keeps a set only when it differs from the last one. Default: nothing.
    var recordResetGrants: @Sendable ([ResetGrantObservation], Date) -> Void = { _, _ in }

    static func live() -> RefreshEnvironment {
        let codex = CodexService()
        let claude = ClaudeService()
        let copilot = CopilotService()
        // Captured once: the closures below only enqueue into its inbox
        // (non-isolated, O(1)); nothing on the landing path or in the scan
        // awaits the store. Only `live()` touches the real database: a test
        // builds its environment by hand, and the defaults record nothing.
        let store = HistoryStore.shared
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
                await ClaudeJSONLScanner.usageReport(completeHistory: completeHistory, history: store)
            },
            fetchCopilot: { previous in
                await copilot.fetch(refreshQuota: true, previous: previous)
            },
            // Session rows read their transcripts through the usage scan's
            // cache and hand what they parse to the same history.
            fetchActiveAgents: { await ActiveAgentService.fetch(claudeCache: .shared, history: store) },
            fetchCodexResetCredits: { try? await CodexResetCreditFetcher.fetch() },
            fetchProviderStatus: { await ProviderStatusService.fetchAll() },
            visibleSlots: { MenuBarLayout.visibleSlots($0) },
            foregroundRefreshKinds: { MenuBarLayout.activeRefreshKinds($0) },
            saveState: { StateCache.save($0) },
            saveLedger: { LifetimeSpendStore.save($0) },
            evaluateNotifications: { NotificationManager.shared.evaluate(provider: $0, windows: $1) },
            recordQuotaReading: { snapshot, at in
                // Empty for a provider or source the history does not record.
                let rows = QuotaSampleRow.rows(from: snapshot, recordedAt: at)
                if !rows.isEmpty { store.submit(quota: rows) }
            },
            importLegacyQuota: { store.submit(legacyQuota: QuotaSampleRow.legacyRows(from: $0)) },
            recordResetGrants: { grants, at in store.submit(resetGrants: grants, recordedMs: HistoryTime.ms(at)) }
        )
    }
}
