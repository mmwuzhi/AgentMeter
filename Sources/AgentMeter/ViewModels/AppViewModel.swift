import Foundation
import Observation

/// Observable state the UI renders. Updated on the main actor by RefreshCoordinator.
@MainActor
@Observable
final class AppViewModel {
    var codex: ProviderState = ProviderState(provider: .codex,
        quota: .unavailable(.codex, note: "Loading…"), usage: .empty(.codex))
    var claude: ProviderState = ProviderState(provider: .claude,
        quota: .unavailable(.claude, note: "Loading…"), usage: .empty(.claude))
    var copilot: ProviderState = ProviderState(provider: .copilot,
        quota: .unavailable(.copilot, note: "Loading…"), usage: .empty(.copilot))

    var isRefreshing = false
    var lastRefresh: Date?
    var quotaObservations: [QuotaObservation] = []
    var codexResetCreditState = CodexResetCreditState()
    var claudeResetState = ClaudeResetState()
    var activeAgents: [ActiveAgent] = []
    var lifetimeSpend: [LifetimeDayRecord] = []
    /// The price table every dollar figure on screen is computed with, so the
    /// all-time footer, the day/7-day/30-day grid, the by-model rows and the
    /// menu-bar spend readout can never disagree with one another. Starts from
    /// the local table so restored state is priced at once; `RefreshCoordinator`
    /// replaces it once the network table has arrived.
    var priceTable: PriceTable = PricingService.localTable()
    /// Not persisted (like `activeAgents`) — a stale "outage" shown from a launch
    /// days ago would be misleading, so this starts empty and fills in on first refresh.
    var providerStatus: [Provider: ProviderStatusResult] = [:]
    /// Providers whose quota fetch failed at least `staleQuotaFailureThreshold`
    /// consecutive times while older live data is still being shown
    /// (`preservingLiveQuota`). Not persisted — refreshes after launch settle it.
    var staleQuotaProviders: Set<Provider> = []
    /// Explicit user choices for session-group and subagent disclosures this
    /// run, keyed by `ActiveAgentGroup.id` / `ActiveAgentNode.disclosureKey`.
    /// An absent key means automatic: expanded only while attention is needed.
    /// Not persisted — groups come and go with the processes behind them — and
    /// pruned as groups disappear, so a stale toggle can't override a
    /// recreated group's automatic behavior.
    var sessionDisclosure: [String: Bool] = [:]
    /// visibleFrame height of the screen hosting the open popover, set by the
    /// status item controller each time a popover opens; nil until the first
    /// open, when views fall back to the main screen.
    var popoverScreenVisibleHeight: CGFloat?
    /// True until Claude's OAuth read has succeeded once on this machine.
    /// Drives the popover primer shown before macOS's first Keychain prompt,
    /// so "choose Always Allow" guidance no longer lives only in the README.
    var claudeKeychainPrimerNeeded = !UserDefaults.standard.bool(forKey: "claudeOAuthSucceededOnce")
    /// Task notifications as the menu lists them, from the event log
    /// (`TaskEventFeed`). `.loading` until the log has been read once, so
    /// "not read yet" never shows as "nothing happened".
    var taskEvents: TaskEventsState = .loading
    /// Whether the task list is open under its header. Not persisted:
    /// collapsed at first and again whenever the popover closes, so the list
    /// pushes the quotas and sessions down only while the user wants it; a
    /// banner tap that opens the popover to show the list opens it expanded.
    var taskEventsExpanded = false
    /// What the last click on a task could not do, as a line under its row.
    /// Not persisted; cleared by the next click and when the popover closes.
    var taskEventNotice: TaskEventNotice?
    /// Where a click on a task would go, by session id, for the rows'
    /// tooltips (`TaskEventFeed.preview`). Not persisted; forgotten when the
    /// popover closes, since sessions come and go.
    var taskEventRoutes: [String: TaskSessionRoute] = [:]

    /// The app restores the last cached state and the spend ledger; a test
    /// passes what it wants restored (nil and `[]` for a model with nothing
    /// behind it) so nothing on disk leaks into it.
    init(
        snapshot: StateCache.Snapshot? = StateCache.load(),
        storedLifetimeSpend: [LifetimeDayRecord]? = LifetimeSpendStore.load()
    ) {
        let storedLifetimeSpend = storedLifetimeSpend ?? []
        // Show the last values we saw immediately; the first refresh replaces them.
        if let snap = snapshot {
            codex = snap.codex
            claude = snap.claude
            copilot = snap.copilot
            // Installs that predate the flag: any cached live Claude snapshot
            // proves quota already flows (OAuth answered, or CLI scraping —
            // which never needs the Keychain prompt).
            if claude.quota.source != .unavailable {
                claudeKeychainPrimerNeeded = false
            }
            quotaObservations = snap.quotaObservations
            codexResetCreditState = snap.codexResetCreditState
            claudeResetState = snap.claudeResetState
            lifetimeSpend = storedLifetimeSpend.isEmpty ? snap.lifetimeSpend : storedLifetimeSpend
            if lifetimeSpend.isEmpty {
                lifetimeSpend = LifetimeSpendTracker.bootstrapFromLegacyReports(
                    [codex.usage, claude.usage], table: priceTable)
            }
            if !lifetimeSpend.isEmpty {
                LifetimeSpendStore.save(lifetimeSpend)
            }
        } else {
            lifetimeSpend = storedLifetimeSpend
        }
    }

    /// All-time observed spend for one provider: the ledger's counts priced
    /// under `priceTable`, like every other dollar figure.
    func lifetimeSpendUSD(for provider: Provider) -> Double {
        LifetimeSpendTracker.totalCostUSD(lifetimeSpend, provider: provider, table: priceTable)
    }

    /// The provider chosen for the menu bar (default Codex).
    var menuBarProviderState: ProviderState {
        switch UserDefaults.standard.string(forKey: "menuBarProvider") {
        case "claude": return claude
        case "copilot": return copilot
        default: return codex
        }
    }

    /// Quota windows of the provider chosen for the menu bar, in order.
    var headlineWindows: [QuotaWindow] { menuBarProviderState.quota.windows }

    /// Today's (local-day) spend for a provider, used by the optional menu-bar spend readout.
    func todaySpendUSD(for state: ProviderState) -> Double {
        state.usage.costUSD(on: Calendar.current.startOfDay(for: Date()), table: priceTable)
    }

    func runway(for provider: Provider, window: QuotaWindow, now: Date = Date()) -> QuotaRunway {
        let peerWindows: [QuotaWindow] = {
            switch provider {
            case .codex: return codex.quota.windows
            case .claude: return claude.quota.windows
            case .copilot: return copilot.quota.windows
            }
        }()
        return QuotaTrendTracker.runway(
            provider: provider,
            window: window,
            observations: quotaObservations,
            now: now,
            peerWindows: peerWindows
        )
    }

    func pruneSessionDisclosure(keeping valid: Set<String>) {
        sessionDisclosure = sessionDisclosure.filter { valid.contains($0.key) }
    }

    /// The popover that lists the tasks closed: the list collapses, and the
    /// last click's line and the looked-up routes go with it.
    func resetTaskEventsPresentation() {
        taskEventsExpanded = false
        taskEventNotice = nil
        taskEventRoutes = [:]
    }

}
