import Foundation

/// Orchestrates Claude data: local usage/spend from JSONL, and a 3-tier quota
/// strategy oauth → cli → spend-only (mirrors steipete's app order).
struct ClaudeService: Sendable {
    /// What `fetchQuota` does once the OAuth read has failed for a reason other
    /// than a rejected token.
    enum OAuthFallback: Equatable, Sendable {
        /// Return `.unavailable` and let `preservingLiveQuota` keep the last live
        /// reading on screen; the stale banner takes over from the second
        /// consecutive failure.
        case keepLastLive
        /// Run `ClaudeCLIScraper`.
        case scrape
    }

    /// A live reading younger than this outranks a scrape. `hasUsableWindow`
    /// alone would keep a weekly-bearing snapshot for days, and the 15-minute
    /// background cadence is a single tick, so a lid-closed gap would spawn the
    /// CLI on the first wake. One hour is four background ticks and matches
    /// `QuotaTrendTracker.fullFidelitySpan`; past it the scrape may run even
    /// though it can be cache-stale too — by then the stale banner is showing.
    static let recentLiveQuotaMaxAge: TimeInterval = 60 * 60

    func fetch(
        refreshQuota: Bool = true,
        refreshUsage: Bool = true,
        previous: ProviderState? = nil
    ) async -> ProviderState {
        if refreshQuota && refreshUsage {
            async let quotaTask = fetchQuota(previous: previous?.quota)
            async let usageTask = ClaudeJSONLScanner.usageReport()
            let (quota, usage) = await (quotaTask, usageTask)
            return ProviderState(provider: .claude, quota: quota, usage: usage)
        }

        let quota: QuotaSnapshot
        if refreshQuota {
            quota = await fetchQuota(previous: previous?.quota)
        } else {
            quota = previous?.quota ?? .unavailable(.claude, note: "Live quota unavailable — showing usage only")
        }

        let usage: UsageReport
        if refreshUsage {
            usage = await ClaudeJSONLScanner.usageReport()
        } else {
            usage = previous?.usage ?? .empty(.claude)
        }
        return ProviderState(provider: .claude, quota: quota, usage: usage)
    }

    private func fetchQuota(previous: QuotaSnapshot?) async -> QuotaSnapshot {
        // 1. OAuth (preferred): file token first, then Keychain.
        if let token = await ClaudeCredentials.load() {
            do {
                return try await ClaudeOAuthFetcher.fetch(token: token)
            } catch {
                // Token rejected (vs. a network blip)? Drop the cache so the next
                // refresh re-reads a freshly rotated token instead of the stale one.
                if (error as? URLError)?.code == .userAuthenticationRequired {
                    await ClaudeCredentials.invalidate()
                }
                let now = Date()
                if Self.oauthFallback(after: error, previous: previous, at: now) == .keepLastLive {
                    return Self.lastLiveQuota(failedAt: now)
                }
            }
        }
        // 2. CLI scrape fallback.
        if ClaudeCLIScraper.isAvailable {
            if let snap = try? await ClaudeCLIScraper.fetch() { return snap }
        }
        // 3. Spend-only degrade.
        return .unavailable(.claude, note: "Live quota unavailable — showing usage only")
    }

    /// Decides the fallback after a failed OAuth read. `claude /usage` fetches
    /// the same endpoint with the same token and, when that fails, prints the
    /// `cachedUsageUtilization` it keeps in `~/.claude.json` — so under a 429, a
    /// 5xx or no network the scrape is never fresher than the live reading it
    /// would replace. The
    /// scrape earns its five-second Claude Code session start only when OAuth
    /// fails for a reason the CLI does not share — a rejected token, which the
    /// CLI can refresh — or when there is no recent live reading to keep.
    static func oauthFallback(after error: Error, previous: QuotaSnapshot?, at now: Date) -> OAuthFallback {
        if (error as? URLError)?.code == .userAuthenticationRequired { return .scrape }
        guard let previous,
              previous.source == .oauth,
              previous.hasUsableWindow(at: now),
              now.timeIntervalSince(previous.fetchedAt) <= recentLiveQuotaMaxAge else {
            return .scrape
        }
        return .keepLastLive
    }

    /// The `.unavailable` snapshot returned for `.keepLastLive`.
    /// `preservingLiveQuota` swaps the previous live snapshot back in, so this
    /// note is only rendered when nothing was there to keep.
    static func lastLiveQuota(failedAt: Date) -> QuotaSnapshot {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm"
        return .unavailable(
            .claude,
            note: "Live quota fetch failed at \(clock.string(from: failedAt)) — showing the last live reading"
        )
    }
}
