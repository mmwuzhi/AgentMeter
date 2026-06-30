import Foundation

/// Persists the last successfully-fetched provider states to disk so the menu bar
/// and popover show the previous values immediately on launch, before the first
/// refresh completes and replaces them. Kept out of UserDefaults so writing it on
/// every refresh doesn't spam `UserDefaults.didChangeNotification` observers.
enum StateCache {
    struct Snapshot: Codable {
        var codex: ProviderState
        var claude: ProviderState
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

    static func save(codex: ProviderState, claude: ProviderState) {
        let snap = Snapshot(codex: codex, claude: claude)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
