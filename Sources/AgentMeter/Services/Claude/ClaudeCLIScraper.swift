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
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let s, !s.isEmpty { return URL(fileURLWithPath: s) }
            }
        }
        return nil
    }

    static var isAvailable: Bool { resolveBinary() != nil }

    static func fetch(timeout: TimeInterval = 30) async throws -> QuotaSnapshot {
        guard let bin = resolveBinary() else { throw URLError(.fileDoesNotExist) }
        let raw = try await run(bin: bin, args: ["/usage"], timeout: timeout)
        let text = stripANSI(raw)
        let windows = parse(text)
        guard !windows.isEmpty else { throw URLError(.cannotParseResponse) }
        return QuotaSnapshot(provider: .claude, windows: windows, source: .cli,
                             planType: nil, fetchedAt: Date(),
                             note: "Scraped from `claude /usage`")
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
                windows.append(QuotaWindow(id: id, label: label, usedPercent: pct, resetsAt: nil))
            }
        }
        return windows
    }
}
