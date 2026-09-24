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

/// One observed quota point, captured after a successful provider refresh.
struct QuotaObservation: Identifiable, Codable, Sendable, Equatable {
    let provider: Provider
    let windowID: String
    let remainingPercent: Double
    let observedAt: Date
    let resetsAt: Date?

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
    let resetCreditsAvailable: Int? // Codex-only reset credits, when exposed
    let resetCreditsExpiresAt: Date? // Codex-only, nil when the protocol omits expiry
    /// Claude-only pay-as-you-go spend past plan limits, in USD.
    let extraUsageSpentUSD: Double?
    let fetchedAt: Date
    let note: String?           // user-facing hint when degraded

    init(
        provider: Provider,
        windows: [QuotaWindow],
        source: SourceKind,
        planType: String?,
        resetCreditsAvailable: Int? = nil,
        resetCreditsExpiresAt: Date? = nil,
        extraUsageSpentUSD: Double? = nil,
        fetchedAt: Date,
        note: String?
    ) {
        self.provider = provider
        self.windows = windows
        self.source = source
        self.planType = planType
        self.resetCreditsAvailable = resetCreditsAvailable
        self.resetCreditsExpiresAt = resetCreditsExpiresAt
        self.extraUsageSpentUSD = extraUsageSpentUSD
        self.fetchedAt = fetchedAt
        self.note = note
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
            resetCreditsAvailable: resetCreditsAvailable,
            resetCreditsExpiresAt: expiresAt,
            extraUsageSpentUSD: extraUsageSpentUSD,
            fetchedAt: fetchedAt,
            note: note
        )
    }

    static func unavailable(_ provider: Provider, note: String) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, windows: [], source: .unavailable,
                      planType: nil, fetchedAt: Date(), note: note)
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
    let totalCostUSD: Double            // rolling last `totalsWindowDays` days
    let totalTokens: Int                // rolling last `totalsWindowDays` days
    var byModel: [ModelSpend] = []      // rolling last `totalsWindowDays` days, sorted by cost descending
    /// True when `buckets` came from reading every log file rather than the
    /// scanner's recent-file window. Only such a report may lower a stored
    /// `LifetimeSpendTracker` day. Provenance of one scan, not state — kept out
    /// of `CodingKeys` so it is never restored from a cache.
    var isCompleteHistory = false

    private enum CodingKeys: String, CodingKey {
        case provider, buckets, totalCostUSD, totalTokens, byModel
    }

    static func empty(_ provider: Provider) -> UsageReport {
        UsageReport(provider: provider, buckets: [], totalCostUSD: 0, totalTokens: 0)
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

/// One locally running interactive agent process.
struct ActiveAgent: Identifiable, Codable, Sendable, Equatable {
    /// A transcript touched this recently is "working" for rows that have no
    /// hook state to say otherwise (Codex, and every subagent).
    static let recentActivityWindow: TimeInterval = 120
    static let futureActivityTolerance: TimeInterval = 60

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

    var displayStatus: AgentStatusState? {
        if let status { return status }
        guard session?.lastUpdatedAt != nil else { return nil }
        return hasRecentSessionActivity ? .working : .idle
    }

    var activityText: String {
        switch status {
        case .working: return workingText
        case .waiting: return "waiting for input"
        case .error: return "needs attention"
        case .idle:
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
        guard let pending = pendingBackgroundTasks, pending > 0 else { return "working now" }
        let noun: String
        if pendingSubagents == pending {
            noun = pending == 1 ? "subagent" : "subagents"
        } else {
            noun = pending == 1 ? "background task" : "background tasks"
        }
        return "working · \(pending) \(noun)"
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
