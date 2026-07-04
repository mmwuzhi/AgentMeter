import Foundation

/// Reads individual GitHub Copilot quota by shelling out to the GitHub CLI:
/// `gh api /copilot_internal/user`. This reuses the user's existing `gh` login —
/// the token stays in gh's keyring and we never touch it, matching AgentMeter's
/// "reuse the CLI logins, no API keys" approach.
///
/// `copilot_internal/user` is the same internal endpoint editors use; it is not a
/// documented REST API, so the response shape can change. The fields we read:
/// `copilot_plan`, `quota_reset_date_utc`, and `quota_snapshots` (each with
/// `percent_remaining`, `unlimited`, `has_quota`).
enum CopilotGitHubClient {
    static func resolveBinary() -> URL? {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/homebrew/sbin/gh"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "gh"]
        p.currentDirectoryURL = SubprocessWorkingDirectory.url
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        if (try? p.run()) != nil {
            guard waitForExit(p, timeout: 1) else {
                p.terminate()
                return nil
            }
            if p.terminationStatus == 0,
               let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return URL(fileURLWithPath: s)
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

    static func fetch(timeout: TimeInterval = 20) async throws -> QuotaSnapshot {
        guard let bin = resolveBinary() else { throw URLError(.fileDoesNotExist) }
        let raw = try await run(bin: bin, args: ["api", "/copilot_internal/user"], timeout: timeout)
        guard let data = raw.data(using: .utf8), !data.isEmpty else { throw URLError(.zeroByteResource) }
        let resp = try JSONDecoder().decode(Response.self, from: data)
        let windows = resp.windows()
        return QuotaSnapshot(
            provider: .copilot, windows: windows, source: .cli,
            planType: resp.copilot_plan, fetchedAt: Date(),
            note: windows.isEmpty ? "All Copilot quotas are unlimited on this plan" : nil)
    }

    private static func run(bin: URL, args: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = bin
            p.arguments = args
            p.currentDirectoryURL = SubprocessWorkingDirectory.url
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            let queue = DispatchQueue(label: "copilot.gh")
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

    /// The slice of `copilot_internal/user` we care about.
    private struct Response: Decodable {
        let copilot_plan: String?
        let quota_reset_date_utc: String?
        let quota_snapshots: [String: Quota]?

        struct Quota: Decodable {
            let percent_remaining: Double?
            let unlimited: Bool?
            let has_quota: Bool?
        }

        /// Metered quotas only (skip the `unlimited` ones), in a friendly order.
        func windows() -> [QuotaWindow] {
            guard let snaps = quota_snapshots else { return [] }
            let reset = Self.parseDate(quota_reset_date_utc)
            let order = ["premium_interactions", "chat", "completions"]
            let keys = snaps.keys.sorted {
                (order.firstIndex(of: $0) ?? Int.max, $0) < (order.firstIndex(of: $1) ?? Int.max, $1)
            }
            return keys.compactMap { key -> QuotaWindow? in
                guard let q = snaps[key], q.has_quota == true, q.unlimited != true,
                      let pct = q.percent_remaining else { return nil }
                return QuotaWindow(id: key, label: Self.label(for: key),
                                   usedPercent: max(0, min(100, 100 - pct)), resetsAt: reset)
            }
        }

        static func label(for key: String) -> String {
            switch key {
            case "premium_interactions": return "Premium"
            case "chat": return "Chat"
            case "completions": return "Completions"
            default: return key.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        static func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
    }
}
