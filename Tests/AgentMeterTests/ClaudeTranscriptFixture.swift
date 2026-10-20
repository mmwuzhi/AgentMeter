import Foundation
@testable import AgentMeter

/// Transcript lines in the shapes Claude Code writes (2026-10 corpus, key
/// order included where the scanner depends on it: system records start
/// with `parentUuid`, bookkeeping records with `type`). Every text field is
/// a placeholder; nothing here is conversation content.
enum TranscriptFixture {
    static let session = "0b3a5c1e-1111-4000-8000-00000000000a"
    static let cwd = "/Users/dev/project"

    /// 2026-10-14T23:59:00.000Z plus `offset` ms: a fixed instant, so stamps
    /// can be asserted exactly.
    static let base: Int64 = 1_792_022_340_000

    private static let utc: TimeZone = TimeZone(identifier: "UTC")!

    /// The 24-character form Claude Code writes: `2026-10-14T23:59:00.123Z`.
    static func iso24(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = utc
        return f.string(from: HistoryTime.date(ms: ms))
    }

    /// The 20-character form `ISO8601DateFormatter()` writes: whole seconds.
    static func iso20(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = utc
        return f.string(from: HistoryTime.date(ms: ms))
    }

    struct Counts {
        var input = 2
        var output = 10
        var cacheRead = 1_000
        var w5m = 50
        var w1h = 0
    }

    private static func usageBlock(_ c: Counts) -> String {
        #""input_tokens":\#(c.input),"cache_creation_input_tokens":\#(c.w5m + c.w1h),"cache_read_input_tokens":\#(c.cacheRead),"cache_creation":{"ephemeral_5m_input_tokens":\#(c.w5m),"ephemeral_1h_input_tokens":\#(c.w1h)},"output_tokens":\#(c.output)"#
    }

    private static func quoted(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }

    /// An assistant record carrying usage. `stop` nil = written mid-stream
    /// (no `iterations`); `zeroed` = a replay with the top level zeroed and
    /// the cache split, stop reason and iterations kept. `ts` nil = no
    /// timestamp key at all.
    static func assistant(
        uuid: String, ts: String?, mid: String, rid: String, model: String = "claude-opus-5-5",
        stop: String? = nil, counts: Counts = Counts(), zeroed: Bool = false,
        version: String? = "2.1.301", effort: String? = "high", entrypoint: String? = "claude-vscode",
        cwd: String? = TranscriptFixture.cwd, thinking: Int? = nil, speed: String? = "standard",
        aborted: Bool = false, iterations: [(model: String, counts: Counts)]? = nil,
        sidechain: Bool = false
    ) -> String {
        var usage = zeroed
            ? #""input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":\#(counts.w5m),"ephemeral_1h_input_tokens":\#(counts.w1h)},"output_tokens":0"#
            : usageBlock(counts)
        usage += #","service_tier":"standard""#
        if let speed { usage += #","speed":"\#(speed)""# }
        if let thinking { usage += #","output_tokens_details":{"thinking_tokens":\#(thinking)}"# }
        if stop != nil {
            let list = iterations ?? [(model, counts)]
            let items = list.enumerated().map { index, item -> String in
                let type = index == 0 ? "message" : "fallback_message"
                let modelKey = list.count > 1 ? #","model":"\#(item.model)""# : ""
                return #"{"type":"\#(type)"\#(modelKey),\#(usageBlock(item.counts))}"#
            }
            usage += #","iterations":[\#(items.joined(separator: ","))]"#
        }
        var line = #"{"parentUuid":"\#(uuid)-p","isSidechain":\#(sidechain),"userType":"external""#
        if let cwd { line += #","cwd":"\#(cwd)""# }
        line += #","sessionId":"\#(session)""#
        if let version { line += #","version":"\#(version)""# }
        line += #","gitBranch":"main","message":{"model":"\#(model)","id":"\#(mid)","type":"message","role":"assistant","content":[{"type":"text","text":"placeholder"}],"stop_reason":\#(quoted(stop)),"stop_sequence":null,"usage":{\#(usage)}},"requestId":"\#(rid)","type":"assistant","uuid":"\#(uuid)""#
        if let ts { line += #","timestamp":"\#(ts)""# }
        if let entrypoint { line += #","entrypoint":"\#(entrypoint)""# }
        if let effort { line += #","effort":"\#(effort)""# }
        if aborted { line += #","isAbortedMidStream":true"# }
        return line + "}"
    }

    enum LimitForm { case quotaLimits, rateLimitInfo, both, neither }

    /// A `<synthetic>` 429 assistant record (zero usage, so it passes the
    /// usage gate) with its window figures in `quotaLimits` and/or
    /// `apiErrorParams.rate_limit_info`.
    static func synthetic429(uuid: String, ts: String, rid: String, form: LimitForm, resetsAt: Int64 = 1_792_375_200) -> String {
        let quota = #"{"isUsingOverage":false,"overageDisabledReason":"org_level_disabled","overageStatus":"rejected","rateLimitType":"five_hour","resetsAt":\#(resetsAt),"status":"rejected","unifiedRateLimitFallbackAvailable":false}"#
        let info = #"{"isUsingOverage":false,"overageDisabledReason":"org_level_disabled","overageStatus":"rejected","rateLimitType":"five_hour","resetsAt":\#(resetsAt),"status":"rejected"}"#
        var line = #"{"parentUuid":"\#(uuid)-p","isSidechain":true,"userType":"external","cwd":"\#(cwd)","sessionId":"\#(session)","version":"2.1.301","gitBranch":"main","agentId":"a1b2c3","message":{"id":"\#(uuid)-m","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":null,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}},"content":[{"type":"text","text":"placeholder"}]},"type":"assistant","uuid":"\#(uuid)","timestamp":"\#(ts)","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"requestId":"\#(rid)""#
        switch form {
        case .quotaLimits: line += #","quotaLimits":\#(quota)"#
        case .rateLimitInfo: line += #","apiErrorParams":{"rate_limit_info":\#(info)},"apiError":"usage_limit_reached""#
        case .both: line += #","quotaLimits":\#(quota),"apiErrorParams":{"rate_limit_info":\#(info)},"apiError":"usage_limit_reached""#
        case .neither: line += #","apiError":"model_requires_usage_credits""#
        }
        return line + "}"
    }

    enum ReportShape { case rateLimitsNull, limitsNull, threeLimits }

    /// A `system/local_command` record of `/usage`: it carries no
    /// `message.usage`, and passes the usage gate only through
    /// `commandRun.command == "usage"`.
    static func usageCommand(uuid: String, ts: String, shape: ReportShape) -> String {
        let rateLimits: String
        switch shape {
        case .rateLimitsNull:
            rateLimits = "null"
        case .limitsNull:
            rateLimits = #"{"extra_usage":{"currency":"USD","is_enabled":true,"monthly_limit":0,"used_credits":0,"utilization":null},"limits":null}"#
        case .threeLimits:
            rateLimits = #"{"extra_usage":{"currency":"USD","is_enabled":true,"monthly_limit":0,"used_credits":0,"utilization":null},"limits":[{"kind":"session","group":"session","percent":27,"severity":"normal","is_active":false,"resets_at":null,"scope":null},{"kind":"weekly_all","group":"weekly","percent":81,"severity":"warning","is_active":true,"resets_at":"2026-10-20T02:09:59.709000+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":93,"severity":"critical","is_active":false,"resets_at":"2026-10-20T02:10:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}"#
        }
        return #"{"parentUuid":"\#(uuid)-p","isSidechain":false,"type":"system","subtype":"local_command","content":"placeholder","level":"info","timestamp":"\#(ts)","uuid":"\#(uuid)","isMeta":false,"commandRun":{"command":"usage","args":""},"usageReport":{"rate_limits":\#(rateLimits),"session":{"total_cost_usd":0,"total_duration_ms":1,"total_api_duration_ms":0,"total_lines_added":0,"total_lines_removed":0,"model_usage":{}}},"userType":"external","entrypoint":"claude-vscode","cwd":"\#(cwd)","sessionId":"\#(session)","version":"2.1.285","gitBranch":"main"}"#
    }

    /// A `cost-state` record: `type` first, no timestamp, no `"usage"` key.
    static func costState(start: Int64, total: Int64, cost: String = "1.5", withModels: Bool = true) -> String {
        let models = withModels
            ? #"{"claude-opus-5-5":{"inputTokens":10,"outputTokens":20,"cacheReadInputTokens":30,"cacheCreationInputTokens":40,"thinkingTokens":5,"webSearchRequests":0,"costUSD":1.25},"claude-opus-5-5[1m]":{"inputTokens":1,"outputTokens":2,"cacheReadInputTokens":3,"cacheCreationInputTokens":4,"thinkingTokens":0,"webSearchRequests":1,"costUSD":0.25}}"#
            : "{}"
        return #"{"type":"cost-state","sessionId":"\#(session)","totalCostUSD":\#(cost),"totalAPIDuration":4000,"totalAPIDurationWithoutRetries":3900,"totalToolDuration":10,"totalLinesAdded":1,"totalLinesRemoved":0,"totalDuration":\#(total),"startTime":\#(start),"modelUsage":\#(models),"hasUnknownModelCost":false}"#
    }

    /// A `system/compact_boundary` record (replayed verbatim up to 4x in a file).
    static func compactBoundary(uuid: String, ts: String, trigger: String = "manual", pre: Int = 180_512, post: Int = 9_871) -> String {
        #"{"parentUuid":null,"logicalParentUuid":"\#(uuid)-l","isSidechain":false,"type":"system","subtype":"compact_boundary","content":"placeholder","isMeta":false,"timestamp":"\#(ts)","uuid":"\#(uuid)","level":"info","compactMetadata":{"trigger":"\#(trigger)","preTokens":\#(pre),"postTokens":\#(post),"durationMs":11840,"preCompactDiscoveredTools":[],"preservedSegment":{"headUuid":"h","tailUuid":"t","anchorUuid":"a"}},"userType":"external","entrypoint":"claude-vscode","cwd":"\#(cwd)","sessionId":"\#(session)","version":"2.1.301","gitBranch":"main"}"#
    }

    /// A user record: no usage, nothing the scan reads.
    static func user(uuid: String, ts: String) -> String {
        #"{"parentUuid":"\#(uuid)-p","isSidechain":false,"userType":"external","cwd":"\#(cwd)","sessionId":"\#(session)","version":"2.1.301","gitBranch":"main","type":"user","message":{"role":"user","content":"placeholder"},"uuid":"\#(uuid)","timestamp":"\#(ts)"}"#
    }

    /// A bookkeeping record (`type` first).
    static func title() -> String {
        #"{"type":"ai-title","sessionId":"\#(session)","aiTitle":"placeholder"}"#
    }

    /// One parse of `lines` from the top on the global (dated, extras) path.
    static func parse(_ lines: [String], resuming base: ClaudeFileUsage? = nil,
                      collectsCompactEvents: Bool = ClaudeJSONLScanner.collectsCompactEvents) -> ClaudeFileUsage {
        var state = ClaudeJSONLScanner.ParseState(resuming: base, collectsCompactEvents: collectsCompactEvents)
        let cal = Calendar.current
        for line in lines {
            JSONLLineReader.withLine(Data(line.utf8)) { ClaudeJSONLScanner.consume(line: $0, into: &state, calendar: cal) }
        }
        return state.usage
    }

    static func write(_ lines: [String], to url: URL, terminated: Bool = true) throws {
        let body = lines.joined(separator: "\n") + (terminated && !lines.isEmpty ? "\n" : "")
        try Data(body.utf8).write(to: url)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

/// A `HistoryIngesting` test double: records every scan batch it is handed.
/// `submit` never blocks; with `gated`, the batches stay pending until
/// `open()`, the way a real store's inbox waits for its drain, so a test can
/// show the scan returned without waiting for the history.
final class RecordingHistorySink: HistoryIngesting, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingScans: [HistoryScanBatch] = []
    private var appliedScans: [HistoryScanBatch] = []
    private var isOpen: Bool

    init(gated: Bool = false) {
        isOpen = !gated
    }

    func submit(scan: HistoryScanBatch) {
        lock.lock()
        defer { lock.unlock() }
        if isOpen { appliedScans.append(scan) } else { pendingScans.append(scan) }
    }

    func submit(quota: [QuotaSampleRow]) {}
    func submit(legacyQuota: [QuotaSampleRow]) {}
    func submit(resetGrants: [ResetGrantObservation], recordedMs: Int64) {}

    /// Applies what was pending, in submission order.
    func open() {
        lock.lock()
        defer { lock.unlock() }
        isOpen = true
        appliedScans.append(contentsOf: pendingScans)
        pendingScans.removeAll()
    }

    var pending: [HistoryScanBatch] {
        lock.lock()
        defer { lock.unlock() }
        return pendingScans
    }

    var scans: [HistoryScanBatch] {
        lock.lock()
        defer { lock.unlock() }
        return appliedScans
    }

    var lastScan: HistoryScanBatch? { scans.last }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        appliedScans.removeAll()
        pendingScans.removeAll()
    }
}

extension HistoryScanBatch {
    func file(_ url: URL) -> HistoryFileBatch? {
        files.first { $0.path == url.path }
    }
}

/// Applies a batch the way the store's rule does, on a plain dictionary:
/// equal watermark → nothing; a delta whose base is what is held → the
/// delta's requests replace theirs by key; anything else → every request.
struct ReferenceIngest {
    var watermark: HistoryFileWatermark?
    var requests: [DedupKey: RequestObservation] = [:]
    var deltasApplied = 0
    var wholeIngests = 0

    mutating func apply(_ batch: HistoryFileBatch) {
        if let watermark, watermark == batch.watermark { return }
        if let delta = batch.delta, let held = watermark,
           held.fileID == delta.basedOnFileID, held.parsedBytes == delta.basedOnParsedBytes,
           held.boundaryDigest == delta.basedOnBoundaryDigest, held.parserVersion == delta.basedOnParserVersion {
            for request in delta.requests { requests[request.key] = request }
            deltasApplied += 1
        } else {
            requests = Dictionary(batch.allRequests().map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
            wholeIngests += 1
        }
        watermark = batch.watermark
    }
}
