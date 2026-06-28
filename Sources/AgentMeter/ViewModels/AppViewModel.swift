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

    var isRefreshing = false
    var lastRefresh: Date?

    var totalSpendUSD: Double { codex.usage.totalCostUSD + claude.usage.totalCostUSD }

    /// Quota windows of the provider chosen for the menu bar (default Codex), in order.
    var headlineWindows: [QuotaWindow] {
        let useClaude = UserDefaults.standard.string(forKey: "menuBarProvider") == "claude"
        return useClaude ? claude.quota.windows : codex.quota.windows
    }
}
