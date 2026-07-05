import Foundation

/// Orchestrates GitHub Copilot data. Copilot is flat-rate (not token-billed), so
/// there's no spend/usage history — only the monthly quota (e.g. premium requests),
/// read via the GitHub CLI.
struct CopilotService: Sendable {
    func fetch(
        refreshQuota: Bool = true,
        previous: ProviderState? = nil
    ) async -> ProviderState {
        let quota: QuotaSnapshot
        if refreshQuota {
            quota = await fetchQuota()
        } else {
            quota = previous?.quota ?? .unavailable(.copilot, note: "Install the GitHub CLI (gh) and run `gh auth login` to show Copilot quota")
        }
        return ProviderState(provider: .copilot, quota: quota, usage: previous?.usage ?? .empty(.copilot))
    }

    private func fetchQuota() async -> QuotaSnapshot {
        guard CopilotGitHubClient.isAvailable else {
            return .unavailable(.copilot, note: "Install the GitHub CLI (gh) and run `gh auth login` to show Copilot quota")
        }
        if let snap = try? await CopilotGitHubClient.fetch() { return snap }
        return .unavailable(.copilot, note: "Couldn't read Copilot quota — check `gh auth status`")
    }
}
