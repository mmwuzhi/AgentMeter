import Foundation

/// Fetches Claude live quota from Anthropic's OAuth usage endpoint using the
/// Claude Code login token. Returns 5-hour / weekly windows with reset times.
enum ClaudeOAuthFetcher {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.0"

    static func fetch(token: ClaudeCredentials.Token) async throws -> QuotaSnapshot {
        var req = URLRequest(url: usageURL)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var windows: [QuotaWindow] = []
        func add(_ key: String, _ label: String) {
            guard let w = obj[key] as? [String: Any] else { return }
            let util = (w["utilization"] as? Double) ?? 0
            let resets = (w["resets_at"] as? String).flatMap(CodexRolloutReader.parseISO)
            windows.append(QuotaWindow(id: key, label: label, usedPercent: util, resetsAt: resets))
        }
        add("five_hour", "5-hour")
        add("seven_day", "Weekly")
        add("seven_day_opus", "Weekly (Opus)")
        add("seven_day_sonnet", "Weekly (Sonnet)")

        guard !windows.isEmpty else { throw URLError(.cannotParseResponse) }
        return QuotaSnapshot(provider: .claude, windows: windows, source: .oauth,
                             planType: planType(in: obj, windows: windows), fetchedAt: Date(), note: nil)
    }

    static func planType(in obj: [String: Any], windows: [QuotaWindow]) -> String? {
        let directKeys = ["plan_type", "planType", "plan", "subscription_type", "subscriptionType"]
        if let explicit = firstString(in: obj, keys: directKeys) {
            return explicit
        }

        for key in ["subscription", "account", "organization", "user"] {
            guard let nested = obj[key] as? [String: Any],
                  let explicit = firstString(in: nested, keys: directKeys + ["tier"]) else {
                continue
            }
            return explicit
        }

        return inferredPlanType(from: windows)
    }

    private static func firstString(in obj: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = obj[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func inferredPlanType(from windows: [QuotaWindow]) -> String? {
        let ids = Set(windows.map(\.id))
        if ids.contains("seven_day_opus") || ids.contains("seven_day_sonnet") {
            return "max"
        }
        if ids.contains("seven_day") {
            return "pro"
        }
        return nil
    }
}
