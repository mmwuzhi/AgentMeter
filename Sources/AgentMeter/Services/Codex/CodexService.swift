import Foundation

/// Orchestrates Codex data: live quota via app-server (preferred), rollout-file fallback,
/// and local usage/spend from rollout logs.
struct CodexService: Sendable {
    private let appServerBinaryURL = AppServerSession.resolveBinary()

    func fetch(
        refreshQuota: Bool = true,
        refreshUsage: Bool = true,
        previous: ProviderState? = nil
    ) async -> ProviderState {
        if refreshQuota && refreshUsage {
            async let quotaTask = fetchQuota()
            async let usageTask = CodexRolloutReader.usageReport()
            let (quota, usage) = await (quotaTask, usageTask)
            return ProviderState(provider: .codex, quota: quota, usage: usage)
        }

        let quota: QuotaSnapshot
        if refreshQuota {
            quota = await fetchQuota()
        } else {
            quota = previous?.quota ?? .unavailable(.codex, note: "Codex CLI not found or never logged in")
        }

        let usage: UsageReport
        if refreshUsage {
            usage = await CodexRolloutReader.usageReport()
        } else {
            usage = previous?.usage ?? .empty(.codex)
        }
        return ProviderState(provider: .codex, quota: quota, usage: usage)
    }

    private func fetchQuota() async -> QuotaSnapshot {
        // Primary: app-server (live). Network-free local subprocess.
        if let appServerBinaryURL {
            let session = AppServerSession(binaryURL: appServerBinaryURL)
            if let snap = try? await session.fetchQuota() { return snap }
        }
        // Fallback: newest rollout log.
        if let snap = CodexRolloutReader.latestQuota() { return snap }
        return .unavailable(.codex, note: "Codex CLI not found or never logged in")
    }
}
