import Foundation

/// Fetches Codex's primary/weekly rate-limit windows straight from ChatGPT's
/// backend-api instead of spawning a `codex app-server` subprocess. Sibling
/// endpoint to `CodexResetCreditFetcher` under the same `/backend-api/wham/`
/// namespace, same `CodexCredentials` OAuth login, same undocumented-endpoint
/// caveat — except this one's exact response shape is not third-party-reverse-
/// engineered: it was read directly out of CodexBar's (MIT-licensed) open-source
/// `CodexOAuthUsageFetcher.swift`, so field names below are known-correct, not
/// guessed aliases.
///
/// `CodexService.fetchQuota()` tries this first because it replaces a subprocess
/// spawn + JSON-RPC handshake with a single HTTPS GET on every refresh tick —
/// `AppServerSession` remains the fallback for setups without a ChatGPT OAuth
/// session (e.g. API-key-only Codex installs).
enum CodexOAuthUsageFetcher {
    static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// Same spoofed identifier `CodexResetCreditFetcher` already uses for the
    /// sibling endpoint — keeps one consistent, already-proven header set across
    /// both Codex HTTPS fetchers rather than introducing a second style.
    static let originator = "codex_cli_rs"

    enum FetchError: Error { case noCredentials, unauthorized, badResponse }

    static func fetch() async throws -> QuotaSnapshot {
        guard let token = await CodexCredentials.load() else { throw FetchError.noCredentials }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = token.accountID {
            req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        req.setValue(originator, forHTTPHeaderField: "originator")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
        if http.statusCode == 401 {
            await CodexCredentials.invalidate()
            throw FetchError.unauthorized
        }
        guard http.statusCode == 200 else { throw FetchError.badResponse }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = parseQuota(obj) else {
            throw FetchError.badResponse
        }
        return snapshot
    }

    /// Shape (confirmed from CodexBar source, not guessed):
    /// `{ plan_type, rate_limit: { primary_window: {used_percent, reset_at, limit_window_seconds},
    /// secondary_window: {...} } }`. `reset_at` is epoch seconds; `used_percent` is 0...100.
    /// Returns nil (rather than an empty-windows snapshot) when neither window parses, so the
    /// caller falls through to the app-server subprocess instead of showing a hollow "live" panel.
    static func parseQuota(_ obj: [String: Any]) -> QuotaSnapshot? {
        guard let rateLimit = obj["rate_limit"] as? [String: Any] else { return nil }

        var windows: [QuotaWindow] = []
        func add(_ id: String, _ d: [String: Any]?) {
            guard let d else { return }
            let used = (d["used_percent"] as? Double) ?? (d["used_percent"] as? Int).map(Double.init) ?? 0
            let minutes = ((d["limit_window_seconds"] as? Double) ?? (d["limit_window_seconds"] as? Int).map(Double.init) ?? 0) / 60
            let resets = ((d["reset_at"] as? Double) ?? (d["reset_at"] as? Int).map(Double.init))
                .map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(id: id, label: CodexRolloutReader.label(forMinutes: minutes),
                                       usedPercent: used, resetsAt: resets))
        }
        add("primary", rateLimit["primary_window"] as? [String: Any])
        add("secondary", rateLimit["secondary_window"] as? [String: Any])
        guard !windows.isEmpty else { return nil }

        return QuotaSnapshot(provider: .codex, windows: windows, source: .oauth,
                             planType: obj["plan_type"] as? String,
                             fetchedAt: Date(), note: nil)
    }
}
