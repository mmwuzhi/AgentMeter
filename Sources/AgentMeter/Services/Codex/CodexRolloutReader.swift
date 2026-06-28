import Foundation

/// Reads Codex usage & quota directly from local session rollout logs.
/// Path: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
/// Each `token_count` event embeds `rate_limits` (quota) and `info.total/last_token_usage`.
enum CodexRolloutReader {
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// All rollout files, newest last (sorted by name, which is timestamp-prefixed).
    static func rolloutFiles() -> [URL] {
        guard let en = FileManager.default.enumerator(at: sessionsDir,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in en where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Quota (latest token_count across newest files)

    static func latestQuota() -> QuotaSnapshot? {
        // Scan newest files first; first file with a token_count wins.
        for url in rolloutFiles().reversed() {
            if let snap = quota(fromFile: url) { return snap }
        }
        return nil
    }

    private static func quota(fromFile url: URL) -> QuotaSnapshot? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var last: [String: Any]?
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  payload["rate_limits"] is [String: Any] else { continue }
            last = payload
        }
        guard let payload = last, let rl = payload["rate_limits"] as? [String: Any] else { return nil }

        var windows: [QuotaWindow] = []
        if let primary = rl["primary"] as? [String: Any] {
            windows.append(window(id: "primary", from: primary))
        }
        if let secondary = rl["secondary"] as? [String: Any] {
            windows.append(window(id: "secondary", from: secondary))
        }
        let plan = rl["plan_type"] as? String
        return QuotaSnapshot(provider: .codex, windows: windows, source: .rolloutFile,
                             planType: plan, fetchedAt: Date(),
                             note: "From local session log (updates when Codex runs)")
    }

    private static func window(id: String, from d: [String: Any]) -> QuotaWindow {
        let used = (d["used_percent"] as? Double) ?? 0
        let minutes = (d["window_minutes"] as? Double) ?? 0
        let resets = (d["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return QuotaWindow(id: id, label: Self.label(forMinutes: minutes), usedPercent: used, resetsAt: resets)
    }

    static func label(forMinutes minutes: Double) -> String {
        switch minutes {
        case 0: return "Quota"
        case ..<120: return "\(Int(minutes / 60))-hour"
        case ..<(60 * 24 * 2): return "\(Int(minutes / 60))-hour"
        default: return "\(Int(minutes / (60 * 24)))-day"
        }
    }

    // MARK: - Usage (per-day token deltas across all files)

    static func usageReport() async -> UsageReport {
        var byDay: [Date: TokenCounts] = [:]
        var models: [Date: String] = [:]
        let cal = Calendar.current

        for url in rolloutFiles() {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var sessionModel = "gpt-5-codex"
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // Capture model when it appears (turn_context / session_meta).
                if let payload = obj["payload"] as? [String: Any], let m = payload["model"] as? String {
                    sessionModel = m
                }
                guard let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else { continue }
                let ts = (obj["timestamp"] as? String).flatMap(Self.parseISO) ?? Date()
                let day = cal.startOfDay(for: ts)
                var c = byDay[day] ?? TokenCounts()
                let input = (last["input_tokens"] as? Int) ?? 0
                let cached = (last["cached_input_tokens"] as? Int) ?? 0
                let output = (last["output_tokens"] as? Int) ?? 0
                c.input += max(0, input - cached)
                c.cacheRead += cached
                c.output += output
                byDay[day] = c
                models[day] = sessionModel
            }
        }

        var buckets: [UsageBucket] = []
        var totalCost = 0.0
        var totalTokens = 0
        for (day, c) in byDay {
            let model = models[day] ?? "gpt-5-codex"
            let cost = await PricingService.shared.cost(model: model, counts: c)
            let bucket = UsageBucket(day: day, inputTokens: c.input, outputTokens: c.output,
                                     cacheWrite5m: c.cacheWrite5m, cacheWrite1h: c.cacheWrite1h,
                                     cacheRead: c.cacheRead, costUSD: cost)
            buckets.append(bucket)
            totalCost += cost
            totalTokens += bucket.totalTokens
        }
        buckets.sort { $0.day < $1.day }
        return UsageReport(provider: .codex, buckets: buckets, totalCostUSD: totalCost, totalTokens: totalTokens)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
