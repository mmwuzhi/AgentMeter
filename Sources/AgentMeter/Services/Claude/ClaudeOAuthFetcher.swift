import Foundation

/// Fetches Claude live quota from Anthropic's OAuth usage endpoint using the
/// Claude Code login token. Returns 5-hour / weekly windows with reset times.
enum ClaudeOAuthFetcher {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.0"

    static func fetch(token: ClaudeCredentials.Token) async throws -> QuotaSnapshot {
        // Checked here, at the send, because the caller's own check may predate
        // a wait on the Keychain during which another refresh was told 429.
        if let until = await ClaudeUsageGate.shared.blockedUntil() { throw ClaudeUsageGate.Blocked(until: until) }
        var req = URLRequest(url: usageURL)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let sentAt = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        await ClaudeUsageGate.shared.record(http, sentAt: sentAt)
        if let errorCode = responseError(forStatusCode: http.statusCode) {
            throw URLError(errorCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return try parseSnapshot(from: obj, credentialPlan: token.subscriptionType,
                                 credentialRateLimitTier: token.rateLimitTier)
    }

    static func responseError(forStatusCode statusCode: Int) -> URLError.Code? {
        switch statusCode {
        case 200:
            return nil
        case 401:
            return .userAuthenticationRequired
        default:
            return .badServerResponse
        }
    }

    /// Builds a `QuotaSnapshot` from an already-decoded `/api/oauth/usage` body.
    /// Plans without session-based rate limits (e.g. Enterprise, which is spend-limited
    /// instead) legitimately have no `five_hour`/`seven_day*` keys — that is not a parse
    /// failure, so an empty `windows` result is still returned rather than thrown.
    /// `credentialPlan` is the plan Claude Code recorded in the login credential
    /// (`ClaudeCredentials.Token.subscriptionType`); see `planType` for how it ranks.
    /// `credentialRateLimitTier` is the same credential's `rateLimitTier`
    /// (`ClaudeCredentials.Token.rateLimitTier`). The response never states it,
    /// so it is carried through as-is for `QuotaSnapshot.planBadge` to read; it
    /// plays no part in choosing `planType`.
    static func parseSnapshot(
        from obj: [String: Any],
        credentialPlan: String? = nil,
        credentialRateLimitTier: String? = nil,
        debugCapture: DebugCapture = .standard
    ) throws -> QuotaSnapshot {
        guard !obj.isEmpty else { throw URLError(.cannotParseResponse) }

        var windows: [QuotaWindow] = []
        func add(_ key: String, _ label: String, isOneTimeCredit: Bool = false) {
            guard let w = obj[key] as? [String: Any] else { return }
            let util = (w["utilization"] as? NSNumber)?.doubleValue ?? 0
            guard util.isFinite else { return }
            // A fully consumed one-time credit never refills, so a permanent
            // 0%-left row is noise. Recurring windows remain visible at 100%.
            if isOneTimeCredit && util >= 100 { return }
            let resets = (w["resets_at"] as? String).flatMap(CodexRolloutReader.parseISO)
            // The screen keeps the 0 a window without `utilization` has always
            // shown; the detail records that the number is not a reading.
            var detail = QuotaWindowDetail(utilizationStated: strictNumber(w["utilization"]) != nil)
            if lockedReasonWindowIDs.contains(key) {
                detail.lockedReason = boundedText(w["locked_reason"])
            }
            windows.append(QuotaWindow(id: key, label: label, usedPercent: util, resetsAt: resets,
                                        isOneTimeCredit: isOneTimeCredit, cycle: cycle(forWindowID: key),
                                        detail: detail))
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
        let limitWindowIDs = addLimits(from: obj, into: &windows)
        attachWeeklyScopedShares(from: obj, limitWindowIDs: limitWindowIDs, into: &windows)

        let plan = planType(in: obj, windows: windows, credentialPlan: credentialPlan)
        let extraUsage = extraUsageSpentUSD(in: obj)

        var note: String?
        if windows.isEmpty {
            debugCapture.record(obj, as: .claudeOAuthUsage)
            note = "\(plan?.capitalized ?? "This") plan has no session-based quota limits"
        }

        return QuotaSnapshot(provider: .claude, windows: windows, source: .oauth,
                             planType: plan, rateLimitTier: credentialRateLimitTier,
                             extraUsageSpentUSD: extraUsage,
                             fetchedAt: Date(), note: note)
    }

    /// Refill cycle a window key implies. `/api/oauth/usage` states no
    /// duration, so the key is the only place the cadence is written down; the
    /// prefix match also covers the model-scoped weeklies built from `limits`
    /// (`seven_day_fable`). The one-time credit names none.
    static func cycle(forWindowID id: String) -> TimeInterval? {
        if id == "five_hour" { return 5 * 3600 }
        if id.hasPrefix("seven_day") { return 7 * 24 * 3600 }
        return nil
    }

    /// Converts Claude's integer-style extra-usage credits into USD. Unknown
    /// currencies are deliberately not relabeled as dollars.
    static func extraUsageSpentUSD(in obj: [String: Any]) -> Double? {
        guard let extra = obj["extra_usage"] as? [String: Any] else { return nil }
        if let enabled = extra["is_enabled"] as? Bool, !enabled { return nil }
        guard let currency = (extra["currency"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              currency.uppercased() == "USD",
              !(extra["used_credits"] is Bool),
              let used = (extra["used_credits"] as? NSNumber)?.doubleValue,
              used.isFinite,
              used > 0 else { return nil }
        let places: Int
        if !(extra["decimal_places"] is Bool),
           let rawPlaces = (extra["decimal_places"] as? NSNumber)?.doubleValue {
            guard rawPlaces.isFinite,
                  rawPlaces.rounded() == rawPlaces,
                  (0.0...6.0).contains(rawPlaces) else { return nil }
            places = Int(rawPlaces)
        } else {
            places = 2
        }
        let dollars = used / pow(10, Double(places))
        return dollars.isFinite ? dollars : nil
    }

    /// Folds `limits` array entries into `windows`, skipping kinds already covered
    /// by a named key. Unknown kinds are ignored rather than guessed at, matching
    /// how the named-key whitelist behaves. What a limit says beyond its percentage
    /// (`is_active`, `severity`, the scope's display name) is merged into the
    /// window of the same id, the named one included, by the first limit that
    /// names it; the named window's own numbers are never replaced.
    ///
    /// Returns, for every limit that built or merged into a window, that limit's
    /// index in the ORIGINAL `limits` array and the window id: `limit_index` of
    /// `weekly_scoped_shares` counts entries the loop below skips as well.
    @discardableResult
    private static func addLimits(from obj: [String: Any], into windows: inout [QuotaWindow]) -> [Int: String] {
        guard let limits = obj["limits"] as? [[String: Any]] else { return [:] }
        var windowIDByLimitIndex: [Int: String] = [:]
        var claimedIDs = Set<String>()
        for (index, limit) in limits.enumerated() {
            guard let kind = limit["kind"] as? String else { continue }
            let id: String
            let label: String
            var modelScoped = false
            var scopeName: String?
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
                      let rawName = model["display_name"] as? String,
                      let scopedID = QuotaWindowID.scopedWeekly(displayName: rawName) else { continue }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                id = scopedID
                label = "Weekly (\(name))"
                modelScoped = true
                scopeName = boundedText(name)
            default:
                continue
            }
            let stated = QuotaWindowDetail(
                isActive: strictBool(limit["is_active"]),
                severity: boundedText(limit["severity"]),
                scopeName: scopeName
            )
            if let existing = windows.firstIndex(where: { $0.id == id }) {
                // A named key (or an earlier limit) built this window. Only the
                // first limit of an id adds its metadata, so a repeated kind
                // cannot overwrite it.
                guard claimedIDs.insert(id).inserted else { continue }
                var detail = windows[existing].detail ?? QuotaWindowDetail()
                detail.isActive = stated.isActive
                detail.severity = stated.severity
                detail.scopeName = stated.scopeName
                windows[existing].detail = detail
                windowIDByLimitIndex[index] = id
                continue
            }
            // `percent` is a bare integer in live responses, so go
            // through NSNumber instead of an `as? Double` cast that only tolerates
            // one numeric shape.
            guard let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
            let resets = (limit["resets_at"] as? String).flatMap(CodexRolloutReader.parseISO)
            var detail = stated
            detail.utilizationStated = true
            windows.append(QuotaWindow(id: id, label: label, usedPercent: percent, resetsAt: resets,
                                       isModelScoped: modelScoped, cycle: cycle(forWindowID: id),
                                       detail: detail))
            claimedIDs.insert(id)
            windowIDByLimitIndex[index] = id
        }
        return windowIDByLimitIndex
    }

    /// `weekly_scoped_shares[]`: how much of the all-model weekly one scoped
    /// limit has used and may use. `limit_index` counts into the ORIGINAL
    /// `limits` array, so a limit of an unknown kind earlier in the list shifts
    /// every index after it; the share goes to the window that limit produced,
    /// and a share whose index names no such window is dropped. Not a window
    /// of its own, so nothing a view shows changes. The first valid share of an
    /// index wins; at most `maxScopedShares` entries are read.
    private static func attachWeeklyScopedShares(
        from obj: [String: Any],
        limitWindowIDs: [Int: String],
        into windows: inout [QuotaWindow]
    ) {
        guard let shares = obj["weekly_scoped_shares"] as? [Any], !limitWindowIDs.isEmpty else { return }
        var attached = Set<Int>()
        for raw in shares.prefix(maxScopedShares) {
            guard let share = raw as? [String: Any],
                  let limitIndex = strictInteger(share["limit_index"]),
                  !attached.contains(limitIndex),
                  let id = limitWindowIDs[limitIndex],
                  let windowIndex = windows.firstIndex(where: { $0.id == id }) else { continue }
            let used = shareFigure(share["used_percent_of_weekly"])
            let allowance = shareFigure(share["allowance_percent_of_weekly"])
            guard used != nil || allowance != nil else { continue }
            var detail = windows[windowIndex].detail ?? QuotaWindowDetail()
            detail.shareUsedOfWeekly = used
            detail.shareAllowanceOfWeekly = allowance
            windows[windowIndex].detail = detail
            attached.insert(limitIndex)
        }
    }

    // MARK: - Defensive field readers (history detail only)
    //
    // Nothing below is trusted: each reader returns nil for a value of the wrong
    // type or outside a plausible range, and the window it describes is built
    // exactly as before.

    /// `locked_reason` is read from these named windows only: the two the
    /// response has been seen to carry it in.
    private static let lockedReasonWindowIDs: Set<String> = ["five_hour", "seven_day"]
    /// A reason, a severity or a model name is a short token or a short phrase.
    static let maxDetailTextLength = 64
    /// A response lists a handful of limits; this bounds the work on one that does not.
    private static let maxScopedShares = 64
    /// Shares are percentages of a weekly; a figure past this is not one.
    private static let maxShareFigure = 1000.0

    /// A real JSON boolean. `as? Bool` also accepts an integer 0 or 1, which a
    /// response that meant a count must not turn into a flag.
    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A finite JSON number; a boolean is not one.
    static func strictNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let double = strictNumber(value), double.rounded() == double,
              double >= 0, double < 1_000_000 else { return nil }
        return Int(double)
    }

    private static func shareFigure(_ value: Any?) -> Double? {
        guard let double = strictNumber(value), double >= 0, double <= maxShareFigure else { return nil }
        return double
    }

    /// The trimmed string when it is 1 to `maxDetailTextLength` printable scalars:
    /// no control, format (bidi overrides, zero-width), separator, private-use
    /// or unassigned scalar, no tab or newline. Anything else (a number, an
    /// over-long value, an odd one) is nil, not a truncated or cleaned copy.
    static func boundedText(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty,
              string.unicodeScalars.count <= maxDetailTextLength else { return nil }
        for scalar in string.unicodeScalars {
            if scalar == " " { continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned,
                 .lineSeparator, .paragraphSeparator, .spaceSeparator:
                return nil
            default:
                continue
            }
        }
        return string
    }

    /// Resolves the plan badge in this order:
    ///
    /// 1. An explicit plan field in the response, top-level or nested under
    ///    `subscription`/`account`/`organization`/`user`. When the server ever
    ///    states the plan, that is its current word and wins — provided it is
    ///    fit to display (`PlanLabel.normalized`); an unfit value is treated
    ///    as unstated, the same rule the credential gets.
    /// 2. `credentialPlan`: what Claude Code recorded at login as
    ///    `claudeAiOauth.subscriptionType`. `/api/oauth/usage` carries no plan
    ///    key today, so in practice this decides the badge.
    /// 3. `inferredPlanType`, a guess from the window shape, as a last resort.
    ///    It only tells max (a `seven_day_opus`/`seven_day_sonnet` window) from
    ///    pro (`seven_day` alone). A Team premium seat has `five_hour`,
    ///    `seven_day`, `seven_day_fable` and no opus/sonnet key, so the guess
    ///    reads it as pro, which is why the credential outranks it.
    static func planType(
        in obj: [String: Any],
        windows: [QuotaWindow],
        credentialPlan: String? = nil
    ) -> String? {
        let directKeys = ["plan_type", "planType", "plan", "subscription_type", "subscriptionType"]
        if let explicit = firstPlan(in: obj, keys: directKeys) {
            return explicit
        }

        for key in ["subscription", "account", "organization", "user"] {
            guard let nested = obj[key] as? [String: Any],
                  let explicit = firstPlan(in: nested, keys: directKeys + ["tier"]) else {
                continue
            }
            return explicit
        }

        if let credential = credentialPlan.flatMap(PlanLabel.normalized) {
            return credential
        }

        return inferredPlanType(from: windows)
    }

    /// The first of `keys` holding a plan fit to display (`PlanLabel`). A key
    /// that is present but unfit — blank, oversized, control characters — is
    /// skipped rather than shown.
    private static func firstPlan(in obj: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = obj[key] as? String, let plan = PlanLabel.normalized(value) {
                return plan
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
