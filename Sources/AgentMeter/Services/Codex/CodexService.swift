import Foundation

/// Orchestrates Codex data: live quota via app-server (preferred), rollout-file fallback,
/// and local usage/spend from rollout logs.
struct CodexService: Sendable {
    func fetch() async -> ProviderState {
        async let quotaTask = fetchQuota()
        async let usageTask = CodexRolloutReader.usageReport()
        let (quota, usage) = await (quotaTask, usageTask)
        return ProviderState(provider: .codex, quota: quota, usage: usage)
    }

    private func fetchQuota() async -> QuotaSnapshot {
        // Primary: app-server (live). Network-free local subprocess.
        if AppServerSession.resolveBinary() != nil {
            let session = AppServerSession()
            if let snap = try? await session.fetchQuota() { return snap }
        }
        // Fallback: newest rollout log.
        if let snap = CodexRolloutReader.latestQuota() { return snap }
        return .unavailable(.codex, note: "Codex CLI not found or never logged in")
    }
}
