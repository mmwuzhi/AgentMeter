import Foundation

/// One Claude "limit reset" grant: a batch of resets the subscription can spend
/// to refill the windows named in `clears`, usable until `endsAt`.
struct ClaudeResetGrant: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let resetsLeft: Int
    /// Nil when the response states no deadline.
    let endsAt: Date?
    /// Window ids one reset refills (`five_hour`, `seven_day`, …), filtered to
    /// the ids Claude Code itself recognizes.
    let clears: [String]
}

/// Claude's limit-reset status as last read. Empty (no grants) when the
/// account has none, is ineligible, or has never been read.
struct ClaudeResetState: Codable, Sendable, Equatable {
    /// Nil when the response carried no status block at all (`cedar_ember: null`).
    var eligible: Bool?
    /// Diagnostic only, never displayed: why the server says the account is
    /// ineligible (`seat`, `tier`, `cli_version`, …).
    var ineligibleReason: String?
    var grants: [ClaudeResetGrant]

    init(eligible: Bool? = nil, ineligibleReason: String? = nil, grants: [ClaudeResetGrant] = []) {
        self.eligible = eligible
        self.ineligibleReason = ineligibleReason
        self.grants = grants
    }
}

/// Reads Claude's limit-reset grants (program codename `cedar_ember`) from the
/// same `/api/oauth/usage` endpoint `ClaudeOAuthFetcher` uses, through the query
/// variant Claude Code sends when it asks for reset status. Kept apart from the
/// quota read on purpose: what `skip_spend=1` drops is unverified, so a failure
/// here costs only the reset line, never the windows. Not a public API — the
/// schema below is Claude Code 2.1.292's own (`qn`/`Kn` in its bundle), and the
/// parse follows it rule for rule instead of guessing.
enum ClaudeResetGrantFetcher {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    /// Claude Code's own User-Agent shape, at the version the program was first
    /// seen in. The status block can come back ineligible for `cli_version`, so
    /// this stays on a real, recent version rather than `ClaudeOAuthFetcher`'s.
    static let userAgent = "claude-cli/2.1.292 (external, cli)"
    /// Shared with Codex reset credits: an untrusted response must not grow the
    /// cache or the popover without limit.
    static let maxStoredGrants = CodexResetCreditTracker.maxStoredCredits

    /// Limit keys Claude Code accepts in a grant's `clears`; anything else is
    /// dropped, as Claude Code does.
    static let knownLimitIDs: Set<String> = [
        "five_hour", "seven_day", "seven_day_overage_included", "seven_day_opus",
        "seven_day_sonnet", "seven_day_cowork", "seven_day_omelette", "seven_day_oauth_apps",
    ]
    static let ineligibleReasons: Set<String> = [
        "config_off", "tier", "seat", "mobile", "surface", "cli_version", "no_grant",
        "tenure", "other_experiment", "unavailable", "unknown",
    ]

    enum FetchError: Error { case badStatus(Int), badResponse, blocked }

    /// A 401 deliberately does not invalidate `ClaudeCredentials`: the quota
    /// read owns that, and two paths dropping the cache would mean two Keychain
    /// reads.
    static func fetch(token: ClaudeCredentials.Token) async throws -> ClaudeResetState {
        // The send is what the rate-limit wait forbids, so it is checked here
        // and not only by the caller.
        if await ClaudeUsageGate.shared.blockedUntil() != nil { throw FetchError.blocked }
        var req = URLRequest(url: url)
        // Shorter than the quota read's 15 s: this runs after it, inside the
        // same refresh, so its wait holds back every provider's landing.
        req.timeoutInterval = 8
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(ClaudeOAuthFetcher.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let sentAt = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
        await ClaudeUsageGate.shared.record(http, sentAt: sentAt)
        guard http.statusCode == 200 else { throw FetchError.badStatus(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !obj.isEmpty else { throw FetchError.badResponse }
        guard let state = parseState(from: obj) else {
            captureUnparsable(obj["cedar_ember"])
            throw FetchError.badResponse
        }
        return state
    }

    /// Nil only for a status block that is present but malformed (not an
    /// object, `eligible` not a boolean, or `grants` neither an array nor
    /// null); the caller then keeps what it had and the block is dumped.
    /// Claude Code reads a non-array `grants` as none, but here that would
    /// wipe the line on exactly the schema drift the dump exists to catch.
    /// A missing or null block is a real answer: no resets.
    static func parseState(from obj: [String: Any], at now: Date = Date()) -> ClaudeResetState? {
        guard let raw = obj["cedar_ember"], !(raw is NSNull) else { return ClaudeResetState() }
        guard let block = raw as? [String: Any],
              let eligibleValue = block["eligible"], isBool(eligibleValue),
              let eligible = eligibleValue as? Bool else { return nil }

        var reason: String?
        if let value = block["ineligible_reason"], !(value is NSNull) {
            let text = value as? String
            reason = text.flatMap { ineligibleReasons.contains($0) ? $0 : nil } ?? "unknown"
        }
        guard eligible else { return ClaudeResetState(eligible: false, ineligibleReason: reason) }

        let entries: [Any]
        switch block["grants"] {
        case nil, is NSNull: entries = []
        case let array as [Any]: entries = array
        default: return nil
        }
        let grants = entries.compactMap { ($0 as? [String: Any]).flatMap { grant(from: $0, at: now) } }
            .sorted { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
        return ClaudeResetState(eligible: true, ineligibleReason: reason,
                                grants: Array(grants.prefix(maxStoredGrants)))
    }

    /// One grant under Claude Code's rules (`id` pattern, non-negative integer
    /// `resets_left`, `clears` filtered to known ids), minus what there is
    /// nothing to show for: no resets left, or already past `ends_at`.
    static func grant(from entry: [String: Any], at now: Date) -> ClaudeResetGrant? {
        guard let id = entry["id"] as? String,
              id.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil,
              let leftValue = entry["resets_left"], !isBool(leftValue),
              let left = (leftValue as? NSNumber)?.doubleValue,
              left.isFinite, left.rounded() == left, left >= 1, left <= Double(Int32.max) else { return nil }
        let endsAt = (entry["ends_at"] as? String).flatMap(CodexRolloutReader.parseISO)
        if let endsAt, endsAt <= now { return nil }
        let clears = (entry["clears"] as? [Any] ?? []).compactMap { $0 as? String }
            .filter { knownLimitIDs.contains($0) }
        return ClaudeResetGrant(id: id, resetsLeft: Int(left), endsAt: endsAt, clears: clears)
    }

    /// The windows a reset refills, named as their quota rows are; nil when
    /// none of them has a row here.
    static func refillLabel(for clears: [String]) -> String? {
        let labels: [String: String] = [
            "five_hour": "5-hour",
            "seven_day": "Weekly",
            "seven_day_opus": "Weekly (Opus)",
            "seven_day_sonnet": "Weekly (Sonnet)",
        ]
        let named = clears.compactMap { labels[$0] }
        return named.isEmpty ? nil : named.joined(separator: " + ")
    }

    /// `JSONSerialization` hands booleans over as `NSNumber`, so `as? Int`
    /// would read `true` as 1 and `as? Bool` would read 1 as `true`.
    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Hands `DebugCapture` (off unless switched on) only the status block,
    /// never the rest of the body, so the field names can be confirmed instead
    /// of guessed.
    static func captureUnparsable(_ block: Any?, using capture: DebugCapture = .standard) {
        capture.record(["cedar_ember": block ?? NSNull()] as [String: Any], as: .claudeResetGrants)
    }
}
