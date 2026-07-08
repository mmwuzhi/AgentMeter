import Foundation

/// Whether a provider's own service is having problems, independent of this
/// account's quota. Lets the popover say "OpenAI is degraded" instead of a
/// generic "Live quota unavailable" when a fetch failure coincides with a real
/// incident.
enum ProviderStatusLevel: String, Codable, Sendable {
    case operational
    case degraded
    case outage

    var severityRank: Int {
        switch self {
        case .operational: 0
        case .degraded: 1
        case .outage: 2
        }
    }
}

/// Two readings of the same status page: the page-wide indicator, and one
/// filtered to the components this provider actually depends on. They diverge
/// when an incident touches only unrelated components (e.g. a FedRAMP-only
/// OpenAI incident flips the page to "minor" while every Codex component stays
/// operational) — the popover banner uses the component reading so it doesn't
/// cry wolf, while the quota-unavailable note keeps the page-wide reading
/// because when the fetch is failing, any incident is a plausible cause.
struct ProviderStatusResult: Sendable, Equatable {
    /// Page-wide status (`status.indicator` / `status.description`).
    let level: ProviderStatusLevel
    let description: String?
    /// Status of just the components relevant to this provider; mirrors the
    /// page-wide reading when the payload has no component data or nothing
    /// matched (so behavior degrades to page-wide, never to silence).
    let componentLevel: ProviderStatusLevel
    let componentDescription: String?

    init(
        level: ProviderStatusLevel,
        description: String?,
        componentLevel: ProviderStatusLevel? = nil,
        componentDescription: String? = nil
    ) {
        self.level = level
        self.description = description
        self.componentLevel = componentLevel ?? level
        self.componentDescription = componentDescription ?? description
    }
}

/// Polls each provider's public Statuspage.io status page. No auth, no API key —
/// these are the same pages status.openai.com / status.claude.com /
/// githubstatus.com show to anyone. Best-effort: a failed poll just omits that
/// provider from the result rather than asserting "operational" (silently
/// claiming "all good" when we simply don't know would be worse than staying
/// quiet).
enum ProviderStatusService {
    private static let urls: [Provider: URL] = [
        .codex: URL(string: "https://status.openai.com/api/v2/summary.json")!,
        .claude: URL(string: "https://status.claude.com/api/v2/summary.json")!,
        .copilot: URL(string: "https://www.githubstatus.com/api/v2/summary.json")!
    ]

    /// Case-insensitive substring matches against `components[].name`, chosen
    /// from the component lists each page serves today: OpenAI's "Codex Web" /
    /// "Codex API", Claude's "Claude Code" / "Claude API (api.anthropic.com)",
    /// GitHub's "Copilot" / "Copilot AI Model Providers". A renamed component
    /// stops matching and the reading falls back to page-wide — noisier, not
    /// blind.
    static let relevantComponentKeywords: [Provider: [String]] = [
        .codex: ["codex"],
        .claude: ["claude code", "claude api"],
        .copilot: ["copilot"]
    ]

    static func fetchAll() async -> [Provider: ProviderStatusResult] {
        await withTaskGroup(of: (Provider, ProviderStatusResult?).self) { group in
            for (provider, url) in urls {
                let keywords = relevantComponentKeywords[provider] ?? []
                group.addTask { (provider, await fetchOne(url, relevantComponentKeywords: keywords)) }
            }
            var result: [Provider: ProviderStatusResult] = [:]
            for await (provider, status) in group {
                if let status { result[provider] = status }
            }
            return result
        }
    }

    private static func fetchOne(_ url: URL, relevantComponentKeywords keywords: [String]) async -> ProviderStatusResult? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseStatus(obj, relevantComponentKeywords: keywords)
    }

    /// Shape: `{ "status": { "indicator": "none"|"minor"|"major"|"critical", "description": "..." },
    /// "components": [{ "id", "name", "status" }], "incidents": [{ "name", "components": [...] }] }` —
    /// the standard Statuspage.io v2 summary response, confirmed live against all three URLs above.
    static func parseStatus(_ obj: [String: Any], relevantComponentKeywords keywords: [String] = []) -> ProviderStatusResult? {
        guard let status = obj["status"] as? [String: Any],
              let indicator = status["indicator"] as? String else { return nil }
        let pageLevel = level(for: indicator)
        let pageDescription = sanitizedDescription(status["description"] as? String)
        guard let component = componentReading(obj, keywords: keywords) else {
            return ProviderStatusResult(level: pageLevel, description: pageDescription)
        }
        return ProviderStatusResult(
            level: pageLevel,
            description: pageDescription,
            componentLevel: component.level,
            // Nil incident description falls back to the page-wide text via
            // the init default, so a degraded component never loses its banner
            // just because no incident named it.
            componentDescription: component.description
        )
    }

    static func level(for indicator: String) -> ProviderStatusLevel {
        switch indicator {
        case "none": return .operational
        case "minor": return .degraded
        case "major", "critical": return .outage
        default: return .operational
        }
    }

    static func level(forComponentStatus status: String?) -> ProviderStatusLevel {
        switch status {
        case "degraded_performance", "under_maintenance": return .degraded
        case "partial_outage", "major_outage": return .outage
        default: return .operational
        }
    }

    /// The worst status among components matching `keywords`, plus the name of
    /// an incident that references one of them (nil when the payload carries no
    /// component data or nothing matched — callers fall back to page-wide).
    private static func componentReading(
        _ obj: [String: Any], keywords: [String]
    ) -> (level: ProviderStatusLevel, description: String?)? {
        guard !keywords.isEmpty,
              let components = obj["components"] as? [[String: Any]] else { return nil }
        let matched = components.filter { component in
            guard let name = (component["name"] as? String)?.lowercased() else { return false }
            return keywords.contains { name.contains($0) }
        }
        guard !matched.isEmpty else { return nil }
        let worst = matched
            .map { level(forComponentStatus: $0["status"] as? String) }
            .max { $0.severityRank < $1.severityRank } ?? .operational
        guard worst != .operational else { return (.operational, nil) }
        return (worst, incidentDescription(obj, matchedComponents: matched))
    }

    /// Name of the first incident whose affected-components list includes one
    /// of the matched components — the specific "Codex API elevated errors"
    /// beats the page-wide "Partial System Degradation". Incidents don't always
    /// tag components (observed live on status.openai.com), so nil is common.
    private static func incidentDescription(
        _ obj: [String: Any], matchedComponents: [[String: Any]]
    ) -> String? {
        guard let incidents = obj["incidents"] as? [[String: Any]] else { return nil }
        let matchedIDs = Set(matchedComponents.compactMap { $0["id"] as? String })
        let matchedNames = Set(matchedComponents.compactMap { ($0["name"] as? String)?.lowercased() })
        for incident in incidents {
            let touched = (incident["components"] as? [[String: Any]] ?? []).contains { component in
                if let id = component["id"] as? String, matchedIDs.contains(id) { return true }
                if let name = (component["name"] as? String)?.lowercased(), matchedNames.contains(name) { return true }
                return false
            }
            if touched, let name = incident["name"] as? String {
                return sanitizedDescription(name)
            }
        }
        return nil
    }

    /// `description` renders verbatim as UI copy (`MenuView`'s status banner and
    /// unavailable-note text), so this is a trust boundary even though the source
    /// pages are official — a compromised status backend or a MITM with a trusted
    /// root installed could otherwise inject unbounded, multi-line, attacker-chosen
    /// text into the popover. Newlines/whitespace collapse to a single space (so a
    /// crafted multi-line description can't break the single-line layout, without
    /// gluing words together); other control characters are dropped; length is capped.
    private static let maxDescriptionLength = 200
    static func sanitizedDescription(_ raw: String?) -> String? {
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
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxDescriptionLength))
    }
}
