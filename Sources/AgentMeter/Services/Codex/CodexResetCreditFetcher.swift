import Foundation

/// Fetches Codex's real "banked rate-limit reset credit" grant/expiry dates from
/// ChatGPT's backend-api. This is not part of the public Codex/OpenAI API surface —
/// it is the same undocumented endpoint ChatGPT's web app and Codex clients use
/// internally (comparable in spirit to `CopilotGitHubClient`'s use of
/// `gh api /copilot_internal/user`). Reuses the Codex CLI's own OAuth login via
/// `CodexCredentials` — no separate account or API key.
///
/// `codex app-server`'s `account/rateLimits/read` JSON-RPC call does not carry
/// per-credit grant/expiry timestamps, only (sometimes) a bare count — that gap is
/// why this hits ChatGPT's backend directly instead of extending that call. Field
/// names below are inferred from third-party reverse engineering, not an official
/// spec, so parsing is defensive (multiple key aliases) and an unparsable body is
/// captured to disk for diagnosing drift, mirroring `ClaudeOAuthFetcher`.
enum CodexResetCreditFetcher {
    static let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    /// Mimics the Codex CLI's own outbound requests so this doesn't stand out as a
    /// third-party client hitting an endpoint meant only for first-party surfaces.
    static let originator = "codex_cli_rs"

    enum FetchError: Error { case noCredentials, unauthorized, badResponse }

    static func fetch() async throws -> [CodexResetCreditExpiry] {
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

        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let credits = parseCredits(obj) else {
            captureRawResponseForDebugging(data)
            throw FetchError.badResponse
        }
        return credits
    }

    /// Tolerant parse: the body may be a bare array, or wrapped under a
    /// "credits"/"data"/"items"/"resets" key. Entries without a recognizable expiry
    /// are dropped rather than failing the whole batch; a wrapper whose known keys
    /// are all absent returns nil so the caller falls back and captures the body.
    /// Bounded the same as `CodexResetCreditTracker`'s local-inference path: an
    /// unexpectedly large array from this undocumented, untrusted endpoint shouldn't
    /// grow `AppViewModel`/`StateCache`/the popover list without limit.
    static func parseCredits(_ obj: Any) -> [CodexResetCreditExpiry]? {
        let array: [[String: Any]]
        if let a = obj as? [[String: Any]] {
            array = a
        } else if let dict = obj as? [String: Any] {
            let candidateKeys = ["credits", "data", "items", "resets"]
            guard let key = candidateKeys.first(where: { dict[$0] is [[String: Any]] }),
                  let a = dict[key] as? [[String: Any]] else { return nil }
            array = a
        } else {
            return nil
        }

        let now = Date()
        var result: [CodexResetCreditExpiry] = []
        for (index, entry) in array.enumerated() {
            if let status = entry["status"] as? String {
                let lowered = status.lowercased()
                if lowered.contains("used") || lowered.contains("redeemed") || lowered.contains("expired") {
                    continue
                }
            }
            guard let expiresAt = date(in: entry, keys: ["expires_at", "expiresAt", "expiration_date"]),
                  expiresAt > now else { continue }
            let grantedAt = date(in: entry, keys: ["granted_at", "grantedAt", "created_at"]) ?? expiresAt
            let id = (entry["id"] as? String) ?? "\(Int(grantedAt.timeIntervalSince1970))-\(index)"
            result.append(CodexResetCreditExpiry(id: id, grantedAt: grantedAt, expiresAt: expiresAt))
        }
        if array.isEmpty { return [] }
        if result.isEmpty { return nil }
        return Array(result.sorted { $0.expiresAt < $1.expiresAt }.prefix(CodexResetCreditTracker.maxStoredCredits))
    }

    private static func date(in obj: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let seconds = obj[key] as? Double { return Date(timeIntervalSince1970: seconds) }
            if let seconds = obj[key] as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
            if let s = obj[key] as? String, let d = CodexRolloutReader.parseISO(s) { return d }
        }
        return nil
    }

    /// Best-effort capture of an unparsable response body, so the real field names
    /// can be confirmed later instead of guessed. Same Application Support
    /// convention as `ClaudeOAuthFetcher`/`StateCache`; write failures are ignored.
    private static let maxDebugCaptureBytes = 256 * 1024
    private static func captureRawResponseForDebugging(_ data: Data) {
        guard data.count <= maxDebugCaptureBytes else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug-codex-reset-credits.json")
        try? data.write(to: url)
    }
}
