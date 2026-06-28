import Foundation

/// Orchestrates Claude data: local usage/spend from JSONL, and a 3-tier quota
/// strategy oauth → cli → spend-only (mirrors steipete's app order).
struct ClaudeService: Sendable {
    func fetch() async -> ProviderState {
        async let quotaTask = fetchQuota()
        async let usageTask = ClaudeJSONLScanner.usageReport()
        let (quota, usage) = await (quotaTask, usageTask)
        return ProviderState(provider: .claude, quota: quota, usage: usage)
    }

    private func fetchQuota() async -> QuotaSnapshot {
        // 1. OAuth (preferred): file token first, then Keychain.
        if let token = ClaudeCredentials.load() {
            if let snap = try? await ClaudeOAuthFetcher.fetch(token: token) { return snap }
        }
        // 2. CLI scrape fallback.
        if ClaudeCLIScraper.isAvailable {
            if let snap = try? await ClaudeCLIScraper.fetch() { return snap }
        }
        // 3. Spend-only degrade.
        return .unavailable(.claude, note: "Live quota unavailable — showing usage only")
    }
}
