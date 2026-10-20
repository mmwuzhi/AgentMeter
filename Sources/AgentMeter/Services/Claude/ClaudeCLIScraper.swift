import Foundation

/// Fallback: runs the `claude` CLI with `/usage` and scrapes the rendered panel
/// for session/weekly percentages and reset lines. Slower and layout-fragile —
/// used only when the OAuth path is unavailable.
enum ClaudeCLIScraper {
    static func resolveBinary() -> URL? {
        for p in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                  NSHomeDirectory() + "/.local/bin/claude", NSHomeDirectory() + "/.claude/local/claude"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        // PATH lookup
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "claude"]
        p.currentDirectoryURL = SubprocessWorkingDirectory.url
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        if (try? p.run()) != nil {
            guard waitForExit(p, timeout: 1) else {
                p.terminate()
                return nil
            }
            if p.terminationStatus == 0 {
                let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let s, !s.isEmpty { return URL(fileURLWithPath: s) }
            }
        }
        return nil
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }

    static var isAvailable: Bool { resolveBinary() != nil }

    static func fetch(
        timeout: TimeInterval = 30,
        planType: String? = nil,
        rateLimitTier: String? = nil
    ) async throws -> QuotaSnapshot {
        guard let bin = resolveBinary() else { throw URLError(.fileDoesNotExist) }
        let raw = try await run(bin: bin, args: ["/usage"], timeout: timeout)
        let text = stripANSI(raw)
        let windows = parse(text)
        guard !windows.isEmpty else { throw URLError(.cannotParseResponse) }
        // Read after the CLI has exited: a read of its own that succeeded
        // has rewritten the cache by then, and matches it at about now. The
        // output itself never says which it was — run on a pipe, the CLI
        // prints in print mode, which annotates a cached reading not at all.
        return snapshot(windows: windows, planType: planType, rateLimitTier: rateLimitTier,
                        cachedAt: cachedReadingTime(matching: windows, config: loadClaudeConfig()))
    }

    /// The scraped panel names no plan, so the plan and tier are whatever the
    /// login credential said when the OAuth path gave up; without them every
    /// tick spent on the scrape dropped the badge.
    static func snapshot(
        windows: [QuotaWindow],
        planType: String?,
        rateLimitTier: String?,
        fetchedAt: Date = Date(),
        cachedAt: Date? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(provider: .claude, windows: windows, source: .cli,
                      planType: planType, rateLimitTier: rateLimitTier,
                      fetchedAt: fetchedAt, note: "Scraped from `claude /usage`",
                      cachedAt: cachedAt)
    }

    /// Claude Code's global config, parsed; nil when missing or unreadable.
    /// Only `cachedUsageUtilization` is looked at.
    static func loadClaudeConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeConfigURL(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Where Claude Code keeps its global config, resolved the way it does
    /// (2.1.301): a legacy `.config.json` in its config home
    /// (`$CLAUDE_CONFIG_DIR`, else `~/.claude`) wins when it is a non-empty
    /// file, symlinks followed; otherwise `.claude.json` — `.claude-custom-oauth.json`
    /// under `CLAUDE_CODE_CUSTOM_OAUTH_URL` — in `$CLAUDE_CONFIG_DIR`, else
    /// in the home directory.
    static func claudeConfigURL(environment: [String: String], home: URL) -> URL {
        let configDir = environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let legacy = (configDir ?? home.appendingPathComponent(".claude", isDirectory: true))
            .appendingPathComponent(".config.json")
        let values = try? legacy.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 {
            return legacy
        }
        let suffix = (environment["CLAUDE_CODE_CUSTOM_OAUTH_URL"] ?? "").isEmpty ? "" : "-custom-oauth"
        return (configDir ?? home).appendingPathComponent(".claude\(suffix).json")
    }

    /// When the printed numbers are the ones in Claude Code's
    /// `cachedUsageUtilization` — what `claude /usage` prints when its own
    /// read fails — the time that cache was fetched. Every scraped window
    /// the cache has a figure for must agree with it within a point (print
    /// mode floors the percent); a window it has none for says nothing either
    /// way, since one run prints from one source. Nil when nothing could be
    /// compared or anything differs, i.e. the CLI read them live.
    static func cachedReadingTime(matching windows: [QuotaWindow], config: [String: Any]?) -> Date? {
        guard let cache = config?["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
              fetchedAtMs.isFinite, fetchedAtMs > 0,
              let utilization = cache["utilization"] as? [String: Any] else { return nil }
        var compared = 0
        for window in windows {
            guard let cached = cachedPercent(for: window.id, in: utilization) else { continue }
            guard abs(cached - window.usedPercent) < 1 else { return nil }
            compared += 1
        }
        return compared > 0 ? Date(timeIntervalSince1970: fetchedAtMs / 1000) : nil
    }

    /// The cache's figure for a scraped window: the named key `parse` files
    /// it under, else — for a model-scoped weekly, which the CLI prints from
    /// `limits[]` as `Current week (<model>)` — the `weekly_scoped` limit of
    /// that model.
    private static func cachedPercent(for id: String, in utilization: [String: Any]) -> Double? {
        if let named = ((utilization[id] as? [String: Any])?["utilization"] as? NSNumber)?.doubleValue {
            return named
        }
        let model: String
        switch id {
        case "seven_day_opus": model = "opus"
        case "seven_day_sonnet": model = "sonnet"
        default: return nil
        }
        for limit in (utilization["limits"] as? [[String: Any]]) ?? [] where limit["kind"] as? String == "weekly_scoped" {
            let scope = limit["scope"] as? [String: Any]
            guard let name = (scope?["model"] as? [String: Any])?["display_name"] as? String,
                  name.lowercased().contains(model) else { continue }
            return (limit["percent"] as? NSNumber)?.doubleValue
        }
        return nil
    }

    private static func run(bin: URL, args: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = bin
            p.arguments = args
            p.currentDirectoryURL = SubprocessWorkingDirectory.url
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            let queue = DispatchQueue(label: "claude.cli")
            queue.async {
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let deadline = DispatchTime.now() + timeout
                while p.isRunning && DispatchTime.now() < deadline { usleep(100_000) }
                if p.isRunning { p.terminate() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    static func stripANSI(_ s: String) -> String {
        let pattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    /// Scrape lines like "Current session  42% used  Resets 3:00pm".
    static func parse(_ text: String) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        let lines = text.split(separator: "\n").map(String.init)
        func percent(in line: String) -> Double? {
            guard let re = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)%"),
                  let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line) else { return nil }
            return Double(line[r])
        }
        for line in lines {
            let lower = line.lowercased()
            let id: String?
            let label: String?
            if lower.contains("current session") { id = "five_hour"; label = "5-hour" }
            else if lower.contains("opus") { id = "seven_day_opus"; label = "Weekly (Opus)" }
            else if lower.contains("sonnet") { id = "seven_day_sonnet"; label = "Weekly (Sonnet)" }
            else if lower.contains("current week") || lower.contains("weekly") { id = "seven_day"; label = "Weekly" }
            else { id = nil; label = nil }
            if let id, let label, let pct = percent(in: line), !windows.contains(where: { $0.id == id }) {
                windows.append(QuotaWindow(id: id, label: label, usedPercent: pct, resetsAt: nil,
                                           cycle: ClaudeOAuthFetcher.cycle(forWindowID: id)))
            }
        }
        return windows
    }
}
