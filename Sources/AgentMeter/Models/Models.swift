import AgentStatusCore
import Foundation

/// Which agent a snapshot belongs to.
enum Provider: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
    case copilot

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .copilot: return "Copilot"
        }
    }
}

/// A single quota window (e.g. Codex 7-day, Claude 5-hour / weekly).
struct QuotaWindow: Identifiable, Codable, Sendable, Equatable {
    let id: String          // stable key, e.g. "five_hour", "primary"
    let label: String       // human label, e.g. "5-hour", "Weekly"
    let usedPercent: Double  // 0...100
    let resetsAt: Date?      // nil if unknown
    /// True for one-time allowances that lapse rather than refill (e.g. an
    /// included credit that expires on a fixed date). Optional so older
    /// cached `QuotaWindow` JSON without this key still decodes; nil/false
    /// means `resetsAt` is a recurring reset like the 5-hour/weekly windows.
    var isOneTimeCredit: Bool? = nil
    /// True for a weekly the provider scoped to one model (`weekly_scoped` in
    /// Claude's `limits`). Such a window only drains while that one model runs,
    /// which makes its ticking bimodal — steady while in use, a hard stop
    /// otherwise — where a window shared by every kind of work is not. The
    /// trend tracker reads it to decide how long a silence has to be before it
    /// stops reporting a rate. Optional so cached JSON written before this key
    /// still decodes; nil means "not stated", read as not scoped.
    var isModelScoped: Bool? = nil
    /// Length of one refill cycle (five hours, seven days) when the provider
    /// states it or the window key implies it; nil for Copilot's allowances
    /// and anything else that names no cadence. `resetsAt` says when the
    /// window next refills, not how often, and the trend tracker needs the
    /// latter to know how much a shorter peer can hand a longer window per
    /// refill. The pace style is keyed on it too
    /// (`QuotaTrendTracker.paceStyle`): a credible long cycle reads pace-only
    /// however little of the current cycle is left; a window stating no cycle,
    /// or one whose stated cycle is not credible (a reset further away than
    /// one cycle), falls back to its time to reset. Optional so cached
    /// `QuotaWindow` JSON written before this key still decodes.
    var cycle: TimeInterval? = nil
    /// What Claude's `/api/oauth/usage` said about this window beyond its
    /// percentage and reset time, kept for the history store. Display never
    /// reads it. Optional so cached `QuotaWindow` JSON written before this key
    /// still decodes, and a build that does not know the key ignores it; nil
    /// for every provider and source that states none of it.
    var detail: QuotaWindowDetail? = nil

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// Compact code for the menu bar, e.g. "5h", "7d", "wk".
    var shortLabel: String {
        let lower = label.lowercased()
        let num = label.prefix { $0.isNumber }
        if lower.contains("hour") { return "\(num)h" }
        if lower.contains("day") { return "\(num)d" }
        if lower.contains("week") { return "7d" }
        if lower.contains("premium") { return "prem" }   // Copilot premium requests
        return String(label.prefix(3))
    }
}

/// The extra facts Claude's usage response carries about one window, exactly as
/// stated (a field the response did not state, or stated in a shape that is not
/// the documented one, stays nil). Every field is optional so a window of
/// another provider, an older cache or a response that names none of them
/// carries no detail at all. Text is bounded and printable; see
/// `ClaudeOAuthFetcher.boundedText`.
struct QuotaWindowDetail: Codable, Sendable, Equatable {
    /// `limits[].is_active`.
    var isActive: Bool? = nil
    /// `limits[].severity`.
    var severity: String? = nil
    /// `locked_reason` of a `five_hour` / `seven_day` object.
    var lockedReason: String? = nil
    /// The raw `scope.model.display_name` the window id was built from.
    var scopeName: String? = nil
    /// `weekly_scoped_shares[].used_percent_of_weekly`: how much of the
    /// all-model weekly this scoped limit's use has consumed.
    var shareUsedOfWeekly: Double? = nil
    /// `weekly_scoped_shares[].allowance_percent_of_weekly`.
    var shareAllowanceOfWeekly: Double? = nil
    /// False when the window object had no numeric `utilization`: the window's
    /// `usedPercent` is then the 0 placeholder the screen has always shown, not
    /// a reading. Nil means not recorded (not Claude's OAuth path).
    var utilizationStated: Bool? = nil
}

/// One observed quota point, captured after a successful provider refresh.
struct QuotaObservation: Identifiable, Codable, Sendable, Equatable {
    let provider: Provider
    let windowID: String
    let remainingPercent: Double
    /// When the reading was taken (`QuotaSnapshot.readingTime`), not when it
    /// landed.
    let observedAt: Date
    let resetsAt: Date?
    /// Where the reading came from. Nil in observations written before this
    /// key, whose source is unknown — anything that may only trust a live
    /// provider reading (Claude: `.oauth`) has to skip those.
    var source: QuotaSnapshot.SourceKind? = nil

    var id: String {
        "\(provider.rawValue):\(windowID):\(observedAt.timeIntervalSince1970)"
    }
}

enum QuotaRunwayStatus: String, Codable, Sendable, Equatable {
    case insufficientData
    case steady
    case safe
    case watch
    case atRisk
}

/// How the popover's pace line reads a window. Decided by
/// `QuotaTrendTracker` — the one owner of window-horizon semantics — so views
/// never re-derive it from reset dates.
enum QuotaPaceStyle: String, Codable, Sendable {
    /// No reset date: no even-spread budget exists, show no pace line.
    case hidden
    /// Short refill cycle (or, with no stated cycle, a reset inside a day):
    /// remaining% spread over the hours left is a real spending guide — show
    /// "now · avg · budget", orange when `now` (or `avg`, if the recent history
    /// is too sparse for a `now`) exceeds budget.
    case paceVersusBudget
    /// Long refill cycle (weekly), or no stated cycle and a reset more than a
    /// day out: the even-spread rate sits below any active use, so drop the
    /// budget segment and turn orange only on an at-risk runway.
    case paceOnly
}

/// Derived prediction for one quota window, based on observed percent drain.
/// Not persisted — rebuilt from `QuotaObservation` history on every read.
/// How the `now` anchor was chosen. Carried on the runway so the pace tooltip
/// can put the right words to `nowSpan` without re-deriving how it was read.
enum QuotaNowAnchor: String, Codable, Sendable {
    /// A burst crossed `nowTriggerPercent` inside the short slice.
    case burst
    /// The sample where the step before the latest
    /// whole-point step landed, so the span is that step's pace so far.
    case step
    /// Step-anchored window with fewer than two steps inside the lookback:
    /// the lookback floor, so the span reaches back across the hour.
    case lookback
    /// Nothing moved across the span at all, so no anchor picked it: the span
    /// is how long the window has been still. Always paired with
    /// `QuotaRunway.nowIsUpperBound`; the two are set in one place.
    case flat
    /// Still for longer than this window's own shape explains
    /// (`QuotaTrendTracker.flatThreshold(for:)`), so `now` stops reporting a
    /// rate at all and the view prints how long it has been still instead. Also
    /// an upper bound — the rate is not known to be zero, only to be under one
    /// point across that stretch.
    case dormant
}

struct QuotaRunway: Codable, Sendable, Equatable {
    let provider: Provider
    let windowID: String
    let status: QuotaRunwayStatus
    /// `avg`: drain averaged across `avgSpan`. The only rate behind
    /// `estimatedDepletionAt` and the `.atRisk` / `.watch` decision.
    let percentPerHour: Double?
    let estimatedDepletionAt: Date?
    let safePercentPerHour: Double?
    let paceStyle: QuotaPaceStyle
    let message: String
    /// `now`: drain across a short adaptive span (`nowSpan`). Nil when the recent
    /// history is too sparse to say anything about the present.
    var nowPercentPerHour: Double? = nil
    /// Actual spans the two rates were read over, for the pace line's hover text.
    var nowSpan: TimeInterval? = nil
    var avgSpan: TimeInterval? = nil
    /// How `nowSpan` was chosen; nil whenever `nowPercentPerHour` is.
    var nowAnchor: QuotaNowAnchor? = nil
    /// True when `nowPercentPerHour` is a ceiling rather than a measurement:
    /// the window did not drop a single reported point across `nowSpan`, so all
    /// that is known is that the rate is below one point per that span. The
    /// view renders it with a `<`. Providers report whole-percent utilization,
    /// so a flat span is the common reading at a light pace and "0" would claim
    /// an idleness the samples do not show.
    var nowIsUpperBound: Bool = false
    /// Label of the shorter peer window whose refill capacity set
    /// `estimatedDepletionAt` (or, for `.safe`, ruled depletion out before
    /// the reset) in place of the `avg` projection. Nil when the estimate is
    /// the plain average-pace projection. The view only puts words to it.
    var pacedBy: String? = nil

    var isAtRisk: Bool { status == .atRisk }
}

/// Compact display name for a provider-reported model id, for the session rows
/// ("claude-opus-4-1-20250805" → "opus 4.1"). The id is untrusted provider
/// input, so this only strips and reshapes — it never maps to a nicer name from
/// a hardcoded table, and an id it does not recognise is shown as-is minus the
/// release date. Nil for the placeholders that mean "no model was named", so a
/// row shows nothing rather than a name no provider actually reported.
enum ModelLabel {
    private static let placeholders: Set<String> = ["default", "<synthetic>", "unknown"]
    private static let maxLength = 40

    static func short(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        id = String(id.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        guard !id.isEmpty, !placeholders.contains(id.lowercased()) else { return nil }
        if id.count > maxLength { id = String(id.prefix(maxLength)) }
        // Release dates distinguish snapshots, not models; the row has no space.
        if let date = id.range(of: "-[0-9]{8}$", options: .regularExpression) {
            id.removeSubrange(date)
        }
        // "family-major-minor" is Anthropic's own shape, so reshaping it is
        // reading the id, not renaming it. Everything else (gpt-5-codex, o3,
        // a bare snapshot name) already reads fine.
        guard id.hasPrefix("claude-") else { return id }
        let body = String(id.dropFirst("claude-".count))
        let parts = body.split(separator: "-").map(String.init)
        guard let family = parts.first,
              parts.count > 1,
              family.allSatisfy(\.isLetter),
              parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return body.isEmpty ? nil : body }
        return family + " " + parts.dropFirst().joined(separator: ".")
    }
}

/// Single-line forms of the free text a session transcript carries. Like
/// `ModelLabel`, this only strips: control characters go, runs of whitespace
/// collapse to one space, and the length is capped so a crafted or runaway
/// value cannot spill past the row it sits on. The cap is applied to scalars
/// as well as to characters: one base letter under a hundred thousand
/// combining marks is a single `Character`, and a character-only cap would let
/// it through to paint over the neighbouring rows.
enum SessionLabel {
    private static let maxTitleLength = 80
    private static let maxEffortLength = 16
    /// Scalars allowed per character before the scalar cap bites. A ZWJ emoji
    /// sequence (family, profession) runs to seven; nothing legitimate needs
    /// more than a handful of combining marks per base.
    private static let maxScalarsPerCharacter = 4

    static func title(_ raw: String?) -> String? {
        singleLine(raw, maxLength: maxTitleLength)
    }

    static func effort(_ raw: String?) -> String? {
        singleLine(raw, maxLength: maxEffortLength)
    }

    private static func singleLine(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        var normalized = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                normalized.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
            }
        }
        let collapsed = normalized
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let scalarBounded = String(String.UnicodeScalarView(
            collapsed.unicodeScalars.prefix(maxLength * maxScalarsPerCharacter)
        ))
        return String(scalarBounded.prefix(maxLength))
    }
}

/// Compact token-count formatter: 1.2k / 3.4M / 1.1B / 2.0T (drops trailing .0).
enum TokenFormat {
    static func short(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1e12...: return trim(v / 1e12) + "T"
        case 1e9...: return trim(v / 1e9) + "B"
        case 1e6...: return trim(v / 1e6) + "M"
        case 1e3...: return trim(v / 1e3) + "k"
        default: return "\(n)"
        }
    }

    private static func trim(_ x: Double) -> String {
        let s = String(format: "%.1f", x)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    /// The row's usage cell, "1.2M · $3.45"; the dollar part is dropped when
    /// no cost is known or it would round to $0.00.
    static func usage(_ tokens: Int, costUSD: Double?) -> String {
        guard let costUSD, costUSD >= 0.005 else { return short(tokens) }
        return "\(short(tokens)) · $\(String(format: "%.2f", costUSD))"
    }
}

/// Live quota for one provider, plus how it was obtained.
struct QuotaSnapshot: Codable, Sendable, Equatable {
    enum SourceKind: String, Codable, Sendable {
        case appServer      // Codex JSON-RPC
        case rolloutFile    // Codex local log fallback
        case oauth          // Claude /api/oauth/usage
        case cli            // Claude `claude /usage` scrape
        case unavailable    // no live quota (spend-only)
    }

    let provider: Provider
    let windows: [QuotaWindow]
    let source: SourceKind
    let planType: String?       // e.g. "free", "pro"
    /// Claude-only: the login's rate-limit tier, e.g. `default_claude_max_5x`;
    /// nil for other providers and for caches written before this key.
    let rateLimitTier: String?
    let resetCreditsAvailable: Int? // Codex-only reset credits, when exposed
    let resetCreditsExpiresAt: Date? // Codex-only, nil when the protocol omits expiry
    /// Claude-only pay-as-you-go spend past plan limits, in USD.
    let extraUsageSpentUSD: Double?
    /// When AgentMeter obtained this snapshot. The forced-refresh spacing
    /// reads it, so it stays the time of the fetch even when the numbers are
    /// older — see `cachedAt` and `readingTime`.
    let fetchedAt: Date
    let note: String?           // user-facing hint when degraded
    /// `claude /usage` scrape only: when the panel only repeated the
    /// `cachedUsageUtilization` Claude Code keeps in `~/.claude.json` (what it
    /// prints when its own read fails), that cache's `fetchedAtMs` — the time
    /// the numbers were really measured, possibly days ago. Nil for every
    /// other reading and in caches written before this key.
    let cachedAt: Date?

    init(
        provider: Provider,
        windows: [QuotaWindow],
        source: SourceKind,
        planType: String?,
        rateLimitTier: String? = nil,
        resetCreditsAvailable: Int? = nil,
        resetCreditsExpiresAt: Date? = nil,
        extraUsageSpentUSD: Double? = nil,
        fetchedAt: Date,
        note: String?,
        cachedAt: Date? = nil
    ) {
        self.provider = provider
        self.windows = windows
        self.source = source
        self.planType = planType
        self.rateLimitTier = rateLimitTier
        self.resetCreditsAvailable = resetCreditsAvailable
        self.resetCreditsExpiresAt = resetCreditsExpiresAt
        self.extraUsageSpentUSD = extraUsageSpentUSD
        self.fetchedAt = fetchedAt
        self.note = note
        self.cachedAt = cachedAt
    }

    /// A repeated cache at most this much older than the scrape still counts
    /// as current: Claude Code itself rewrites the cache at most every five
    /// minutes, so a younger one is what it would show as live.
    static let staleCacheTolerance: TimeInterval = 5 * 60

    /// When the numbers were measured: the repeated cache's time for a
    /// scrape that only echoed it, else `fetchedAt`.
    var readingTime: Date {
        guard let cachedAt else { return fetchedAt }
        return min(cachedAt, fetchedAt)
    }

    /// A scrape that only repeated a cached reading older than
    /// `staleCacheTolerance`: shown as the fallback it is, but never recorded
    /// as an observation nor evaluated for alerts, and marked stale at once.
    var echoesStaleCache: Bool {
        fetchedAt.timeIntervalSince(readingTime) > Self.staleCacheTolerance
    }

    var resetCreditsCountText: String? {
        guard provider == .codex, let resetCreditsAvailable else { return nil }
        return resetCreditsAvailable == 1
            ? "1 reset available"
            : "\(resetCreditsAvailable) resets available"
    }

    func withResetCreditsExpiresAt(_ expiresAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            windows: windows,
            source: source,
            planType: planType,
            rateLimitTier: rateLimitTier,
            resetCreditsAvailable: resetCreditsAvailable,
            resetCreditsExpiresAt: expiresAt,
            extraUsageSpentUSD: extraUsageSpentUSD,
            fetchedAt: fetchedAt,
            note: note,
            cachedAt: cachedAt
        )
    }

    static func unavailable(_ provider: Provider, note: String) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, windows: [], source: .unavailable,
                      planType: nil, fetchedAt: Date(), note: note)
    }
}

/// The plan string as it may be shown: what `ClaudeCredentials` reads from
/// the login, what `ClaudeOAuthFetcher` accepts from a response, and what the
/// badge uppercases. One rule for every source, so a value is bounded before
/// it reaches `Text`, the plan note or `last-state.json`.
enum PlanLabel {
    /// Real values are "pro", "max", "team" and "enterprise"; a space or a
    /// dash leaves room for a compound name. Anchored, ASCII, at most 32
    /// characters — so a stack of combining marks, a newline, a NUL or a bidi
    /// override is not a plan.
    static let pattern = "^[a-z][a-z0-9_ -]{0,31}$"

    /// Trimmed and lowercased, or nil when the result does not match
    /// `pattern`.
    static func normalized(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return wholeMatch(value, pattern) ? value : nil
    }

    /// True when `pattern` matches all of `value`, not a prefix or a
    /// substring: `$` alone still matches before a final line terminator, so
    /// the range is checked as well as found.
    static func wholeMatch(_ value: String, _ pattern: String) -> Bool {
        guard let match = value.range(of: pattern, options: .regularExpression) else { return false }
        return match == value.startIndex..<value.endIndex
    }
}

/// What the popover's provider header shows next to the provider name.
struct PlanBadge: Equatable, Sendable {
    let text: String
    /// Tooltip; nil when there is nothing beyond `text` to say.
    let help: String?
}

extension QuotaSnapshot {
    /// The rate-limit tier Claude Code pairs with `subscriptionType == "team"`
    /// to recognise a Team premium seat (its check is literally
    /// `team && default_claude_max_5x`; no field spells "premium").
    static let teamPremiumRateLimitTier = "default_claude_max_5x"

    /// nil when the plan is unknown. `TEAM PREMIUM` for a Team premium seat;
    /// otherwise the plan uppercased, as before. The raw tier rides in the
    /// tooltip whenever it is known, so Max seats can read 5x/20x without a
    /// second rule. Decided here so the view never re-derives it.
    var planBadge: PlanBadge? {
        // Every live source normalises through `PlanLabel`; the trim and
        // lowercase here cover a value decoded from a cache written before
        // that rule. A blank plan is as unknown as a missing one: no empty
        // capsule.
        guard let plan = planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else { return nil }
        // Claude's rule, so it is guarded on the provider: Codex's raw
        // `plan_type` could read "team", and a tier Codex never reports must
        // not promote it.
        if provider == .claude, plan.lowercased() == "team",
           rateLimitTier == Self.teamPremiumRateLimitTier {
            return PlanBadge(
                text: "TEAM PREMIUM",
                help: "Team premium seat · rate limit tier \(Self.teamPremiumRateLimitTier)"
            )
        }
        return PlanBadge(
            text: plan.uppercased(),
            help: rateLimitTier.map { "Rate limit tier \($0)" }
        )
    }
}

/// One day's aggregated usage for the heatmap and spend.
struct UsageBucket: Identifiable, Codable, Sendable, Equatable {
    var id: Date { day }
    let day: Date               // start-of-day (local)
    var inputTokens: Int
    var outputTokens: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var cacheRead: Int
    var costUSD: Double

    var totalTokens: Int { inputTokens + outputTokens + cacheWrite5m + cacheWrite1h + cacheRead }
}

/// One day's token counts under one model: what the scanners emit, a report
/// carries, and the spend ledger stores. Dollars are derived from these under
/// the `PriceTable` current at display time, never stored and read back.
struct DayModelUsage: Codable, Sendable, Equatable {
    let day: Date               // start-of-day (local)
    let model: String
    var counts: TokenCounts
}

/// One day of activity for the heatmap and sparkline: tokens and spend only.
/// Recent days come from `UsageReport.buckets`; older ones come from the
/// persisted lifetime ledger, which reaches back past the scanner's file window
/// and therefore carries no token split.
struct UsageDayPoint: Identifiable, Sendable, Equatable {
    var id: Date { day }
    let day: Date               // start-of-day (local)
    let tokens: Int
    let costUSD: Double
}

/// Rolling-window spend + tokens attributed to one model.
struct ModelSpend: Identifiable, Codable, Sendable, Equatable {
    var id: String { model }
    let model: String
    let tokens: Int
    let costUSD: Double
}

/// Per-provider rollup of usage buckets + spend.
struct UsageReport: Codable, Sendable, Equatable {
    /// Widest rolling window the UI presents ("By model · 30-day",
    /// SpendBreakdownGrid). Scanners clamp totals/byModel to this window;
    /// buckets may reach further back for the heatmap. The popover footer's
    /// all-time figure comes from the persisted LifetimeSpendTracker ledger.
    static let totalsWindowDays = 30

    let provider: Provider
    let buckets: [UsageBucket]          // sorted ascending by day
    /// Scan-time dollars for the rolling window. Compatibility output for older
    /// builds reading `last-state.json`; this build prices `dayModels` instead.
    let totalCostUSD: Double
    let totalTokens: Int                // rolling last `totalsWindowDays` days
    var byModel: [ModelSpend] = []      // scan-time dollars per model; compat, like `totalCostUSD`
    /// The counts behind `buckets`, split by model, so every dollar figure can
    /// be computed under the table current at display time. Empty in a report
    /// restored from a cache an older build wrote; the spend helpers then fall
    /// back to that build's scan-time dollars until the first refresh.
    var dayModels: [DayModelUsage] = []
    /// True when `buckets` came from reading every log file rather than the
    /// scanner's recent-file window. Only such a report may lower a stored
    /// `LifetimeSpendTracker` day. Provenance of one scan, not state — kept out
    /// of `CodingKeys` so it is never restored from a cache.
    var isCompleteHistory = false
    /// Claude only: per day, how many of the requests counted on it closed
    /// with a final usage record, how many have only partial records (output
    /// a lower bound) and how many only zeroed replays. Provenance of one
    /// scan like `isCompleteHistory`, so not encoded; empty for a report
    /// restored from a cache and for other providers.
    var requestFinality: [Date: RequestFinalityCounts] = [:]

    init(
        provider: Provider,
        buckets: [UsageBucket],
        totalCostUSD: Double,
        totalTokens: Int,
        byModel: [ModelSpend] = [],
        dayModels: [DayModelUsage] = [],
        isCompleteHistory: Bool = false
    ) {
        self.provider = provider
        self.buckets = buckets
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.byModel = byModel
        self.dayModels = dayModels
        self.isCompleteHistory = isCompleteHistory
    }

    private enum CodingKeys: String, CodingKey {
        case provider, buckets, totalCostUSD, totalTokens, byModel, dayModels
    }

    /// Tolerates caches written before `dayModels` existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(Provider.self, forKey: .provider)
        buckets = try c.decode([UsageBucket].self, forKey: .buckets)
        totalCostUSD = try c.decode(Double.self, forKey: .totalCostUSD)
        totalTokens = try c.decode(Int.self, forKey: .totalTokens)
        byModel = try c.decodeIfPresent([ModelSpend].self, forKey: .byModel) ?? []
        dayModels = try c.decodeIfPresent([DayModelUsage].self, forKey: .dayModels) ?? []
    }

    static func empty(_ provider: Provider) -> UsageReport {
        UsageReport(provider: provider, buckets: [], totalCostUSD: 0, totalTokens: 0)
    }
}

/// Display-time spend. Everything here prices `dayModels` under the table it is
/// handed, so two figures shown side by side always come from the same table;
/// the scan-time `costUSD` fields are only a fallback for a report restored
/// from an older build's cache, which carries no counts by model.
extension UsageReport {
    /// First day of the rolling `totalsWindowDays` window that ends today.
    static func totalsCutoff(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -(totalsWindowDays - 1),
                      to: calendar.startOfDay(for: now)) ?? .distantPast
    }

    /// Spend on the days on or after `cutoff` (every day when nil).
    func costUSD(from cutoff: Date?, table: PriceTable) -> Double {
        if dayModels.isEmpty {
            return buckets.reduce(0) { $0 + (Self.includes(cutoff, $1.day) ? $1.costUSD : 0) }
        }
        return dayModels.reduce(0) {
            $0 + (Self.includes(cutoff, $1.day) ? table.cost(model: $1.model, counts: $1.counts) : 0)
        }
    }

    /// Spend on exactly `day`, a local start-of-day.
    func costUSD(on day: Date, table: PriceTable) -> Double {
        if dayModels.isEmpty {
            return buckets.first { $0.day == day }?.costUSD ?? 0
        }
        return dayModels.reduce(0) {
            $0 + ($1.day == day ? table.cost(model: $1.model, counts: $1.counts) : 0)
        }
    }

    /// Per-model rollup of the days on or after `cutoff`, costliest first.
    func modelSpend(from cutoff: Date, table: PriceTable) -> [ModelSpend] {
        if dayModels.isEmpty { return byModel }
        var totals: [String: (tokens: Int, cost: Double)] = [:]
        for entry in dayModels where entry.day >= cutoff {
            var t = totals[entry.model] ?? (0, 0)
            t.tokens += entry.counts.total
            t.cost += table.cost(model: entry.model, counts: entry.counts)
            totals[entry.model] = t
        }
        return totals
            .map { ModelSpend(model: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.model < $1.model }
    }

    private static func includes(_ cutoff: Date?, _ day: Date) -> Bool {
        guard let cutoff else { return true }
        return day >= cutoff
    }
}

/// Everything the UI renders for one provider.
struct ProviderState: Codable, Sendable, Equatable {
    let provider: Provider
    var quota: QuotaSnapshot
    var usage: UsageReport
}

/// Local identity for the transcript/log file backing a running agent.
struct ActiveAgentSession: Codable, Sendable, Equatable {
    let id: String
    let projectPath: String?
    let projectName: String?
    let branch: String?
    let lastUpdatedAt: Date?
    let source: String
    var tokenCount: Int? = nil
    var estimatedCostUSD: Double? = nil
    var logPath: String? = nil
    /// Raw model id behind the most recent tokens this session spent. Nil until
    /// the transcript has a token-bearing record to read it from.
    var model: String? = nil
    /// Reasoning effort on that same record (`effort` in a Claude transcript).
    /// Nil when the provider does not write one; Codex rollouts never do.
    var effort: String? = nil
    /// Session title as the provider recorded it: a user-set custom title, else
    /// the generated one. Untrusted text; render only through `SessionLabel`.
    var title: String? = nil
    /// Every subagent transcript found under this session's directory, newest
    /// first — finished ones included, since their spend is part of
    /// `tokenCount` / `estimatedCostUSD`. Which of them a row lists is decided
    /// at grouping time (`ActiveSubagent.isListed`). Claude only.
    var subagents: [ActiveSubagent] = []

    var shortID: String {
        String(id.prefix(8))
    }

    /// "incl. 2 subagents (1.2M · $3.45 of the total)" for the tooltip: how
    /// much of the session's total the subagents account for. The share is
    /// bracketed and says so, because "incl. 7 subagents · 5.5M" beside the session total
    /// can otherwise look like additional usage.
    /// Nil without any.
    var subagentUsageText: String? {
        guard !subagents.isEmpty else { return nil }
        let count = subagents.count
        var text = "incl. \(count) \(count == 1 ? "subagent" : "subagents")"
        let tokens = subagents.compactMap(\.tokenCount).reduce(0, +)
        if tokens > 0 {
            let cost = subagents.compactMap(\.estimatedCostUSD).reduce(0, +)
            text += " (" + TokenFormat.usage(tokens, costUSD: cost) + " of the total)"
        }
        return text
    }

    /// Branch as a row may show it. `gitBranch` is copied from the transcript,
    /// so it passes through `SessionLabel` like the title; a detached HEAD
    /// names no branch and is dropped.
    var displayBranch: String? {
        guard let branch = SessionLabel.title(branch), branch != "HEAD" else { return nil }
        return branch
    }

    var usageText: String? {
        guard let tokenCount else { return nil }
        if let estimatedCostUSD {
            return "\(TokenFormat.short(tokenCount)) · $\(String(format: "%.2f", estimatedCostUSD))"
        }
        return TokenFormat.short(tokenCount)
    }

    var displayProject: String {
        if let projectName, !projectName.isEmpty { return projectName }
        if let projectPath, !projectPath.isEmpty {
            return URL(fileURLWithPath: projectPath).lastPathComponent
        }
        return source
    }
}

/// One subagent of a Claude session, read from its own transcript
/// (`<projectKey>/<sessionID>/subagents/agent-<id>.jsonl` plus the sibling
/// `agent-<id>.meta.json`). Transcript-derived only: there is no process to
/// focus and no hook state — subagent tool calls report under the parent's
/// session id — so its state is the transcript's mtime. Lives on
/// `ActiveAgentSession.subagents`, which is never persisted.
struct ActiveSubagent: Identifiable, Codable, Sendable, Equatable {
    /// How long a finished subagent stays listed under its session. Long enough
    /// to read what just finished; short enough that a day's runs do not pile
    /// up under every row. Its spend counts in the session total regardless.
    static let lingerWindow: TimeInterval = 600

    /// The `<id>` of the filename.
    let id: String
    let logPath: String
    /// Transcript mtime — the only activity signal a subagent has.
    let lastUpdatedAt: Date
    let observedAt: Date
    /// `description` from the meta file (the spawning tool's short label),
    /// else the opening words of the first prompt. Untrusted; render only
    /// through `SessionLabel`.
    var description: String? = nil
    /// `agentType` from the meta file ("general-purpose", "Explore", …).
    var agentType: String? = nil
    var tokenCount: Int? = nil
    var estimatedCostUSD: Double? = nil
    /// Model and effort behind the subagent's newest counted record — its
    /// own, not the parent's; a subagent routinely runs a cheaper model.
    var model: String? = nil
    var effort: String? = nil

    /// Working while the transcript changed within the same window a session
    /// without hook state is judged by; a subagent has no other signal.
    var isWorking: Bool {
        let age = observedAt.timeIntervalSince(lastUpdatedAt)
        return age >= -ActiveAgent.futureActivityTolerance && age <= ActiveAgent.recentActivityWindow
    }

    /// Whether a row still shows it: in flight, or finished within `lingerWindow`.
    var isListed: Bool {
        observedAt.timeIntervalSince(lastUpdatedAt) <= Self.lingerWindow
    }

    var displayTitle: String {
        SessionLabel.title(description) ?? "agent \(id.prefix(8))"
    }

    var displayAgentType: String? {
        SessionLabel.effort(agentType)
    }

    /// "fable 5.1 · xhigh · working now" / "fable 5.1 · xhigh · done · 3m ago".
    var subtitleText: String {
        var parts: [String] = []
        if let model = ModelLabel.short(model) { parts.append(model) }
        if let effort = SessionLabel.effort(effort) { parts.append(effort) }
        parts.append(isWorking ? "working now" : "done · \(ActiveAgent.relativeAge(from: lastUpdatedAt, to: observedAt))")
        return parts.joined(separator: " · ")
    }

    var usageText: String {
        guard let tokenCount else { return "No usage yet" }
        return TokenFormat.usage(tokenCount, costUSD: estimatedCostUSD)
    }
}

/// Why a `waiting` session waits, from the registry's `waitingFor`. Only the
/// wordings Claude Code is known to write map to a case; anything else is
/// dropped and a registry-sourced row says plain "waiting", so the registry's text
/// never reaches the screen as is.
enum ActiveAgentWaitingReason: String, Codable, Sendable, Equatable {
    /// A tool needs approval: `permission prompt`, plus the sandbox network
    /// and worker requests, which are approvals as well.
    case permission
    /// Claude asked a question (`AskUserQuestion`) or an MCP server opened an
    /// elicitation form: `input needed`.
    case input
    /// A dialog that is not about the work is open: `dialog open`.
    case dialog

    init?(registryValue: String?) {
        switch registryValue?.lowercased() {
        case "permission prompt", "sandbox request", "worker request": self = .permission
        case "input needed": self = .input
        case "dialog open": self = .dialog
        default: return nil
        }
    }

    /// Row subtitle.
    var activityText: String {
        switch self {
        case .permission: return "waiting for permission"
        case .input: return "waiting for your input"
        case .dialog: return "waiting · dialog open"
        }
    }

    /// First words of the tooltip.
    var tooltipLead: String {
        switch self {
        case .permission: return "Waiting for permission"
        case .input: return "Waiting for your input"
        case .dialog: return "A dialog is open"
        }
    }
}

/// Where a row's `status` came from.
enum ActiveAgentStatusSource: String, Codable, Sendable, Equatable {
    /// Claude Code's own session registry (`ClaudeSessionRegistry`).
    case registry
    /// The hook payload, because the registry had nothing usable for the
    /// process, or because the payload is a `StopFailure` the registry's
    /// idle does not contradict.
    case hook
}

/// One locally running interactive agent process.
struct ActiveAgent: Identifiable, Codable, Sendable, Equatable {
    /// A transcript touched this recently is "working" for rows that have no
    /// hook state to say otherwise (Codex, and every subagent).
    static let recentActivityWindow: TimeInterval = 120
    static let futureActivityTolerance: TimeInterval = 60
    /// How long a hook-reported `error` keeps the row red. Nothing but the
    /// session's next hook event overwrites the state, so a failed turn in a
    /// tab nobody returns to would otherwise stay "needs attention" — and turn
    /// its whole group red — for as long as the tab is open. The same 12 hours
    /// after which the launch sweep (`AgentStatusStore.sweepStale`) drops a
    /// payload outright.
    static let errorAttentionWindow: TimeInterval = 12 * 3_600

    let provider: Provider
    let pid: Int
    let parentPID: Int
    let command: String
    let elapsedSeconds: TimeInterval
    let observedAt: Date
    /// Controlling terminal reported by `ps` (for exact terminal-tab focus).
    var tty: String? = nil
    var cwd: String? = nil
    var session: ActiveAgentSession? = nil
    /// Nearest ancestor that is another agent of the same provider.
    var parentAgentPID: Int? = nil
    /// Optional live state supplied by Claude Code hooks.
    var status: AgentStatusState? = nil
    /// Background tasks (subagents, shell jobs) the hook reported still in
    /// flight when `status` was recorded; see `AgentStatusPayload`. Only a
    /// `Stop` carries them, so a `working` written by `PreToolUse` has nil.
    var pendingBackgroundTasks: Int? = nil
    var pendingSubagents: Int? = nil
    /// When `status` was recorded: the registry's `statusUpdatedAt`, or the
    /// hook payload's `updatedAt`.
    var statusUpdatedAt: Date? = nil
    /// Where `status` came from. Nil with `status`.
    var statusSource: ActiveAgentStatusSource? = nil
    /// What a `waiting` session waits for, when the registry said and the
    /// wording was one AgentMeter knows.
    var waitingReason: ActiveAgentWaitingReason? = nil

    var id: String { "\(provider.rawValue):\(pid)" }

    var displayTitle: String {
        if let session { return session.displayProject }
        if let cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty { return name }
        }
        return provider.displayName
    }

    var sourceLabel: String {
        let lower = command.lowercased()
        switch provider {
        case .codex:
            return lower.contains(".app/contents/") ? "Codex Desktop" : "Codex CLI"
        case .claude:
            return lower.contains("application support/claude/") ? "Claude Desktop" : "Claude CLI"
        case .copilot:
            return "Copilot"
        }
    }

    /// The hook last recorded a failed turn, longer ago than
    /// `errorAttentionWindow`: the row goes gray and says when it failed.
    var hasStaleError: Bool {
        guard status == .error, let statusUpdatedAt else { return false }
        return observedAt.timeIntervalSince(statusUpdatedAt) > Self.errorAttentionWindow
    }

    var displayStatus: AgentStatusState? {
        if hasStaleError { return .idle }
        if let status { return status }
        guard session?.lastUpdatedAt != nil else { return nil }
        return hasRecentSessionActivity ? .working : .idle
    }

    var activityText: String {
        switch status {
        case .working: return workingText
        case .waiting:
            // The registry said waiting without a known reason: do not guess
            // that the user has to act.
            return waitingReason?.activityText ?? (statusSource == .registry ? "waiting" : "waiting for input")
        case .error:
            guard hasStaleError, let statusUpdatedAt else { return "needs attention" }
            return "last turn failed · \(relativeAge(since: statusUpdatedAt))"
        case .idle:
            // The turn ended with work still in flight (the last `Stop`'s
            // count, kept beside the registry's idle): that goes in the age's
            // place, which would otherwise read as the session having been
            // quiet all that time.
            if let pending = backgroundTaskText { return "idle · \(pending)" }
            guard let lastUpdatedAt = session?.lastUpdatedAt else { return "idle" }
            return "idle · \(relativeAge(since: lastUpdatedAt))"
        case nil:
            guard let lastUpdatedAt = session?.lastUpdatedAt else { return "open now" }
            if hasRecentSessionActivity { return "active now" }
            return "idle · \(relativeAge(since: lastUpdatedAt))"
        }
    }

    /// True when the process is known only to exist: no hook-reported state and
    /// no attributed transcript. Such a row can say nothing but "open now" — no
    /// model, no tokens, no spend — and a day of still-open editor tabs
    /// produces a dozen of them, burying the sessions that carry information.
    /// `ActiveAgentService.fetch()` drops them before anything renders.
    var isBlank: Bool { status == nil && session == nil }

    /// How long a session doing nothing stays in the popover list after its
    /// last sign of life. A Claude Code panel keeps its process until the panel
    /// is closed, so without a limit every panel ever opened stays listed as
    /// "idle · 9d ago" for as long as the editor runs.
    static let idleListingWindow: TimeInterval = 24 * 3_600

    /// The newest sign of life the row carries: the last change of its state
    /// (the registry's or the hook's) or the last write to its transcript.
    /// Nil when nothing it carries is dated.
    var lastActivityAt: Date? {
        [statusUpdatedAt, session?.lastUpdatedAt].compactMap { $0 }.max()
    }

    /// Whether the popover lists the row: it is running, or it did something
    /// within `idleListingWindow` (a failed turn is one: its error is dated).
    /// Nothing is deleted, killed
    /// or forgotten — the process lives on, its transcript and spend still
    /// count, and the row is back as soon as it does anything.
    ///
    /// `idle` alone does not end a session, and neither does its age. Claude
    /// Code's own registry vouches for a `busy` or `waiting` process whatever
    /// the date of that state (a long run with background agents keeps `busy`
    /// untouched while its main transcript stays quiet). A state only a hook
    /// reported vouches for nothing once it is that old: an interrupt fires no
    /// `Stop`, so a `working` can be left behind for good. Without a date to
    /// judge by, the row stays.
    var isListed: Bool {
        if statusSource == .registry, status == .working || status == .waiting { return true }
        guard let lastActivityAt else { return true }
        return observedAt.timeIntervalSince(lastActivityAt) <= Self.idleListingWindow
    }

    /// nil when no transcript could be attributed to this process — rendering
    /// nothing beats a wall of "Usage unavailable" rows.
    var usageDisplayText: String? {
        guard let session else { return nil }
        return session.usageText ?? "No usage yet"
    }

    /// Title for a row under a project-group header, where repeating the
    /// project name carries no information. Prefer what distinguishes the
    /// session (`titleDetail`), then terminal, then PID.
    var inGroupTitle: String {
        titleDetail ?? tty ?? "PID \(pid)"
    }

    /// The identity slot: what says which session this is, beside the project
    /// name on a lone row or as the whole title under a group header. The
    /// session title when the provider recorded one, else the branch — a title
    /// says which conversation this is; a branch only says where it runs. This
    /// is the one place that precedence lives; the tooltip shows the branch
    /// unconditionally so it stays reachable when a title displaces it.
    var titleDetail: String? {
        SessionLabel.title(session?.title) ?? session?.displayBranch
    }

    /// Row subtitle. The provider is implied by the surrounding popover
    /// section, so only the less common Desktop origin is called out.
    var subtitleText: String {
        var parts: [String] = []
        if sourceLabel.hasSuffix("Desktop") { parts.append("Desktop") }
        // Which model a session is burning decides whether its spend is worth
        // it, and sessions in one project often differ — so it belongs on the
        // row, not only in the tooltip.
        if let model = ModelLabel.short(session?.model) { parts.append(model) }
        // Effort multiplies the model's cost, so it sits right after it.
        if let effort = SessionLabel.effort(session?.effort) { parts.append(effort) }
        parts.append(activityText)
        return parts.joined(separator: " · ")
    }

    /// "working now", or what a quiet session is still working through: when
    /// the main turn ended with background tasks in flight the hook kept the
    /// row `working`, and the count says why a session that types nothing is
    /// green. Plain "subagent(s)" when that is all of them; otherwise the
    /// broader "background task(s)", since a shell job or MCP task is in there.
    private var workingText: String {
        guard let pending = backgroundTaskText else { return "working now" }
        return "working · \(pending)"
    }

    /// "2 subagents" / "1 background task": what the last `Stop` reported
    /// still in flight when the turn ended. Plain "subagent(s)" when that is
    /// all of them; otherwise the broader "background task(s)", since a shell
    /// job or MCP task is in there. Nil when nothing was. It is a count from
    /// that moment, not a reading of what runs now: the next `Stop` replaces it.
    var backgroundTaskText: String? {
        guard let pending = pendingBackgroundTasks, pending > 0 else { return nil }
        let noun: String
        if pendingSubagents == pending {
            noun = pending == 1 ? "subagent" : "subagents"
        } else {
            noun = pending == 1 ? "background task" : "background tasks"
        }
        return "\(pending) \(noun)"
    }

    private var hasRecentSessionActivity: Bool {
        guard let lastUpdatedAt = session?.lastUpdatedAt else { return false }
        let age = observedAt.timeIntervalSince(lastUpdatedAt)
        return age >= -Self.futureActivityTolerance && age <= Self.recentActivityWindow
    }

    private func relativeAge(since date: Date) -> String {
        Self.relativeAge(from: date, to: observedAt)
    }

    static func relativeAge(from date: Date, to observedAt: Date) -> String {
        let seconds = max(0, Int(observedAt.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
