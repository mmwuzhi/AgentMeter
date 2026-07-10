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
        return try parseSnapshot(from: obj)
    }

    /// Builds a `QuotaSnapshot` from an already-decoded `/api/oauth/usage` body.
    /// Plans without session-based rate limits (e.g. Enterprise, which is spend-limited
    /// instead) legitimately have no `five_hour`/`seven_day*` keys — that is not a parse
    /// failure, so an empty `windows` result is still returned rather than thrown.
    static func parseSnapshot(
        from obj: [String: Any],
        captureDebugResponse: Bool = true
    ) throws -> QuotaSnapshot {
        guard !obj.isEmpty else { throw URLError(.cannotParseResponse) }

        var windows: [QuotaWindow] = []
        func add(_ key: String, _ label: String, isOneTimeCredit: Bool = false) {
            guard let w = obj[key] as? [String: Any] else { return }
            let util = (w["utilization"] as? Double) ?? 0
            let resets = (w["resets_at"] as? String).flatMap(CodexRolloutReader.parseISO)
            windows.append(QuotaWindow(id: key, label: label, usedPercent: util, resetsAt: resets,
                                        isOneTimeCredit: isOneTimeCredit))
        }
        add("five_hour", "5-hour")
        add("seven_day", "Weekly")
        add("seven_day_opus", "Weekly (Opus)")
        add("seven_day_sonnet", "Weekly (Sonnet)")
        // Spend-based plans (e.g. Enterprise) report a one-time Claude Code + Cowork
        // credit under an opaque, Anthropic-assigned codename instead of a fixed field
        // name — confirmed by inspecting a live response. Same {utilization, resets_at}
        // shape as the windows above, so it reuses `add` as-is. It's a one-time lapsing
        // credit, not a recurring reset (unlike the windows above): once used up or past
        // its date it just stays gone, so `isOneTimeCredit` flips the "expires" wording
        // in QuotaRow instead of the misleading "resets". If Anthropic rotates the
        // codename this simply stops matching (windows.isEmpty note reappears) rather
        // than parsing something wrong.
        add("cinder_cove", "Included credit", isOneTimeCredit: true)
        // Newer responses also carry a `limits` array. Its `session`/`weekly_all`
        // entries duplicate `five_hour`/`seven_day` above, but model-scoped weekly
        // limits (e.g. Fable) exist ONLY here — there is no named `seven_day_fable`
        // key (confirmed against a live response; the named model keys stay null).
        // Parse it as a supplement: map each known kind onto the equivalent named
        // window id and skip ids already added, so the named keys stay authoritative
        // when both are present and trend observations keep a stable window id
        // either way.
        addLimits(from: obj, into: &windows)

        let plan = planType(in: obj, windows: windows)

        var note: String?
        if windows.isEmpty {
            if captureDebugResponse {
                captureRawResponseForDebugging(obj)
            }
            note = "\(plan?.capitalized ?? "This") plan has no session-based quota windows — showing usage/spend below"
        }

        return QuotaSnapshot(provider: .claude, windows: windows, source: .oauth,
                             planType: plan, fetchedAt: Date(), note: note)
    }

    /// Folds `limits` array entries into `windows`, skipping kinds already covered
    /// by a named key. Unknown kinds are ignored rather than guessed at, matching
    /// how the named-key whitelist behaves.
    private static func addLimits(from obj: [String: Any], into windows: inout [QuotaWindow]) {
        guard let limits = obj["limits"] as? [[String: Any]] else { return }
        for limit in limits {
            guard let kind = limit["kind"] as? String else { continue }
            let id: String
            let label: String
            switch kind {
            case "session":
                id = "five_hour"
                label = "5-hour"
            case "weekly_all":
                id = "seven_day"
                label = "Weekly"
            case "weekly_scoped":
                // Scoped to one model; the display name is the only identity the
                // response carries (`scope.model.id` is null in live responses).
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = (model["display_name"] as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                id = "seven_day_" + name.lowercased().replacingOccurrences(of: " ", with: "_")
                label = "Weekly (\(name))"
            default:
                continue
            }
            // `percent` is a bare integer in live responses (62, not 62.0), so go
            // through NSNumber instead of an `as? Double` cast that only tolerates
            // one numeric shape.
            guard !windows.contains(where: { $0.id == id }),
                  let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
            let resets = (limit["resets_at"] as? String).flatMap(CodexRolloutReader.parseISO)
            windows.append(QuotaWindow(id: id, label: label, usedPercent: percent, resetsAt: resets))
        }
    }

    /// Best-effort capture of a window-less `/api/oauth/usage` body, so the real field
    /// names for spend-limit/credit-based plans (e.g. Enterprise) can be confirmed later
    /// instead of guessed. Follows the same Application Support/AgentMeter convention as
    /// `StateCache`/`PricingService`; write failures are silently ignored.
    private static func captureRawResponseForDebugging(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              data.count <= maxDebugCaptureBytes else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug-claude-oauth-usage.json")
        try? data.write(to: url)
    }

    /// A legitimate usage payload is a few KB. Refuses to write anything larger instead
    /// of persisting an oversized body verbatim (e.g. from a misbehaving proxy).
    private static let maxDebugCaptureBytes = 256 * 1024

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
