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

/// Derived prediction for one quota window, based on observed percent drain.
struct QuotaRunway: Codable, Sendable, Equatable {
    let provider: Provider
    let windowID: String
    let status: QuotaRunwayStatus
    let percentPerHour: Double?
    let estimatedDepletionAt: Date?
    let safePercentPerHour: Double?
    let message: String

    var isAtRisk: Bool { status == .atRisk }
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
    let fetchedAt: Date
    let note: String?           // user-facing hint when degraded

    init(
        provider: Provider,
        windows: [QuotaWindow],
        source: SourceKind,
        planType: String?,
        resetCreditsAvailable: Int? = nil,
        resetCreditsExpiresAt: Date? = nil,
        fetchedAt: Date,
        note: String?
    ) {
        self.provider = provider
        self.windows = windows
        self.source = source
        self.planType = planType
        self.resetCreditsAvailable = resetCreditsAvailable
        self.resetCreditsExpiresAt = resetCreditsExpiresAt
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

/// All-time spend + tokens attributed to one model.
struct ModelSpend: Identifiable, Codable, Sendable, Equatable {
    var id: String { model }
    let model: String
    let tokens: Int
    let costUSD: Double
}

/// Per-provider rollup of usage buckets + spend.
struct UsageReport: Codable, Sendable, Equatable {
    let provider: Provider
    let buckets: [UsageBucket]          // sorted ascending by day
    let totalCostUSD: Double            // rolling last 30 days, matches SpendWindows.lastDays(30)
    let totalTokens: Int                // rolling last 30 days, matches SpendWindows.lastDays(30)
    var byModel: [ModelSpend] = []      // rolling last 30 days, sorted by cost descending

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

    var shortID: String {
        String(id.prefix(8))
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

/// One locally running interactive agent process.
struct ActiveAgent: Identifiable, Codable, Sendable, Equatable {
    let provider: Provider
    let pid: Int
    let parentPID: Int
    let command: String
    let elapsedSeconds: TimeInterval
    let observedAt: Date
    var cwd: String? = nil
    var session: ActiveAgentSession? = nil

    var id: String { "\(provider.rawValue):\(pid)" }

    var elapsedText: String {
        let seconds = max(0, Int(elapsedSeconds))
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    var displayCommand: String {
        let pieces = command.split(separator: " ", maxSplits: 2).map(String.init)
        guard pieces.count > 1 else { return provider.displayName }
        return pieces.dropFirst().joined(separator: " ")
    }

    var displaySession: String {
        session?.shortID ?? "unknown"
    }
}
