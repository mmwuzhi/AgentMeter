import Foundation

/// Orchestrates GitHub Copilot data. Copilot is flat-rate (not token-billed), so
/// there's no spend/usage history — only the monthly quota (e.g. premium requests),
/// read via the GitHub CLI.
struct CopilotService: Sendable {
    func fetch() async -> ProviderState {
        ProviderState(provider: .copilot, quota: await fetchQuota(), usage: .empty(.copilot))
    }

    private func fetchQuota() async -> QuotaSnapshot {
        guard CopilotGitHubClient.isAvailable else {
            return .unavailable(.copilot, note: "Install the GitHub CLI (gh) and run `gh auth login` to show Copilot quota")
        }
        if let snap = try? await CopilotGitHubClient.fetch() { return snap }
        return .unavailable(.copilot, note: "Couldn't read Copilot quota — check `gh auth status`")
    }
}
