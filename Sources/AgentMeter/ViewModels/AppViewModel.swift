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
    /// Not persisted (like `activeAgents`) — a stale "outage" shown from a launch
    /// days ago would be misleading, so this starts empty and fills in on first refresh.
    var providerStatus: [Provider: ProviderStatusResult] = [:]

    init() {
        // Show the last values we saw immediately; the first refresh replaces them.
        if let snap = StateCache.load() {
            codex = snap.codex
            claude = snap.claude
            copilot = snap.copilot
            quotaObservations = snap.quotaObservations
            codexResetCreditState = snap.codexResetCreditState
        }
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
