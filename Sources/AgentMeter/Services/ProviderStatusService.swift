import Foundation

/// Whether a provider's own service is having problems, independent of this
/// account's quota. Lets the popover say "OpenAI is degraded" instead of a
/// generic "Live quota unavailable" when a fetch failure coincides with a real
/// incident.
enum ProviderStatusLevel: String, Codable, Sendable {
    case operational
    case degraded
    case outage
}

struct ProviderStatusResult: Sendable, Equatable {
    let level: ProviderStatusLevel
    let description: String?
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

    static func fetchAll() async -> [Provider: ProviderStatusResult] {
        await withTaskGroup(of: (Provider, ProviderStatusResult?).self) { group in
            for (provider, url) in urls {
                group.addTask { (provider, await fetchOne(url)) }
            }
            var result: [Provider: ProviderStatusResult] = [:]
            for await (provider, status) in group {
                if let status { result[provider] = status }
            }
            return result
        }
    }

    private static func fetchOne(_ url: URL) async -> ProviderStatusResult? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseStatus(obj)
    }

    /// Shape: `{ "status": { "indicator": "none"|"minor"|"major"|"critical", "description": "..." }, ... }` —
    /// the standard Statuspage.io v2 summary response, confirmed live against all three URLs above.
    static func parseStatus(_ obj: [String: Any]) -> ProviderStatusResult? {
        guard let status = obj["status"] as? [String: Any],
              let indicator = status["indicator"] as? String else { return nil }
        return ProviderStatusResult(
            level: level(for: indicator),
            description: sanitizedDescription(status["description"] as? String)
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
