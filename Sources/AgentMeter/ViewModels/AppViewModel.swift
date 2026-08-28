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
    var activeAgents: [ActiveAgent] = []
    var lifetimeSpend: [LifetimeDayRecord] = []
    /// Not persisted (like `activeAgents`) — a stale "outage" shown from a launch
    /// days ago would be misleading, so this starts empty and fills in on first refresh.
    var providerStatus: [Provider: ProviderStatusResult] = [:]
    /// Providers whose last quota fetch failed while older live data is still
    /// being shown (`preservingLiveQuota`). Not persisted — the first refresh
    /// after launch settles it either way.
    var staleQuotaProviders: Set<Provider> = []
    /// True until Claude's OAuth read has succeeded once on this machine.
    /// Drives the popover primer shown before macOS's first Keychain prompt,
    /// so "choose Always Allow" guidance no longer lives only in the README.
    var claudeKeychainPrimerNeeded = !UserDefaults.standard.bool(forKey: "claudeOAuthSucceededOnce")

    init() {
        let storedLifetimeSpend = LifetimeSpendStore.load() ?? []
        // Show the last values we saw immediately; the first refresh replaces them.
        if let snap = StateCache.load() {
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
            lifetimeSpend = storedLifetimeSpend.isEmpty ? snap.lifetimeSpend : storedLifetimeSpend
            if lifetimeSpend.isEmpty {
                lifetimeSpend = LifetimeSpendTracker.bootstrapFromLegacyReports([codex.usage, claude.usage])
            }
            if !lifetimeSpend.isEmpty {
                LifetimeSpendStore.save(lifetimeSpend)
            }
        } else {
            lifetimeSpend = storedLifetimeSpend
        }
    }

    /// All-time observed spend for one provider, from the persisted ledger.
    func lifetimeSpendUSD(for provider: Provider) -> Double {
        LifetimeSpendTracker.totalCostUSD(lifetimeSpend, provider: provider)
    }

    var totalSpendUSD: Double {
        codex.usage.totalCostUSD + claude.usage.totalCostUSD + copilot.usage.totalCostUSD
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
        let start = Calendar.current.startOfDay(for: Date())
        return state.usage.buckets.first { $0.day == start }?.costUSD ?? 0
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

}
