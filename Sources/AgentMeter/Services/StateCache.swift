import Foundation

/// Persists the last successfully-fetched provider states to disk so the menu bar
/// and popover show the previous values immediately on launch, before the first
/// refresh completes and replaces them. Kept out of UserDefaults so writing it on
/// every refresh doesn't spam `UserDefaults.didChangeNotification` observers.
enum StateCache {
    struct Snapshot: Codable {
        var codex: ProviderState
        var claude: ProviderState
        var copilot: ProviderState
        var quotaObservations: [QuotaObservation]
        var codexResetCreditState: CodexResetCreditState

        init(
            codex: ProviderState,
            claude: ProviderState,
            copilot: ProviderState,
            quotaObservations: [QuotaObservation] = [],
            codexResetCreditState: CodexResetCreditState = CodexResetCreditState()
        ) {
            self.codex = codex
            self.claude = claude
            self.copilot = copilot
            self.quotaObservations = quotaObservations
            self.codexResetCreditState = codexResetCreditState
        }

        // Tolerate caches written before Copilot existed: fall back to an empty
        // Copilot state instead of failing the whole decode (which would blank the
        // Codex/Claude values on the first launch after upgrading).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            codex = try c.decode(ProviderState.self, forKey: .codex)
            claude = try c.decode(ProviderState.self, forKey: .claude)
            copilot = try c.decodeIfPresent(ProviderState.self, forKey: .copilot)
                ?? ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "Loading…"),
                                 usage: .empty(.copilot))
            quotaObservations = try c.decodeIfPresent([QuotaObservation].self, forKey: .quotaObservations) ?? []
            codexResetCreditState = try c.decodeIfPresent(
                CodexResetCreditState.self,
                forKey: .codexResetCreditState
            ) ?? CodexResetCreditState()
        }
    }

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AgentMeter", isDirectory: true)
    }
    private static var fileURL: URL { dir.appendingPathComponent("last-state.json") }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(
        codex: ProviderState,
        claude: ProviderState,
        copilot: ProviderState,
        quotaObservations: [QuotaObservation] = [],
        codexResetCreditState: CodexResetCreditState = CodexResetCreditState()
    ) {
        let snap = Snapshot(
            codex: codex,
            claude: claude,
            copilot: copilot,
            quotaObservations: quotaObservations,
            codexResetCreditState: codexResetCreditState
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
