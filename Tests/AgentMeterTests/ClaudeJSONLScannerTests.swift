import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeJSONLScannerTests: XCTestCase {
    func testUsageReportParsesInjectedJSONLFiles() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("claude-jsonl-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        // Dynamic timestamp: totals apply a rolling 30-day cutoff, so a fixed
        // date here would silently age out of the window and start failing.
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let payload = [
            #"{"timestamp":"\#(ts)","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":7,"ephemeral_1h_input_tokens":11}}}}"#,
            #"{"timestamp":"\#(ts)","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":999,"output_tokens":999}}}"#
        ].joined(separator: "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)

        let report = await ClaudeJSONLScanner.usageReport(files: [url])

        XCTAssertEqual(report.totalTokens, 53)
        XCTAssertEqual(report.buckets.first?.inputTokens, 10)
        XCTAssertEqual(report.buckets.first?.outputTokens, 20)
        XCTAssertEqual(report.buckets.first?.cacheRead, 5)
        XCTAssertEqual(report.buckets.first?.cacheWrite5m, 7)
        XCTAssertEqual(report.buckets.first?.cacheWrite1h, 11)
    }

    /// Regression: totalTokens/totalCostUSD/byModel are surfaced as "30-day"
    /// totals, but used to sum every day the file scan picked up, disagreeing
    /// with SpendWindows.lastDays(30). Days beyond the rolling cutoff must
    /// still appear in buckets (heatmap) while staying out of the totals.
    func testTotalsApplyRollingThirtyDayCutoffWhileBucketsKeepAllDays() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("claude-jsonl-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let iso = ISO8601DateFormatter()
        let old = iso.string(from: Date().addingTimeInterval(-40 * 86_400))
        let recent = iso.string(from: Date().addingTimeInterval(-86_400))
        let payload = [
            #"{"timestamp":"\#(old)","requestId":"req-old","message":{"id":"msg-old","model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":0}}}"#,
            #"{"timestamp":"\#(recent)","requestId":"req-new","message":{"id":"msg-new","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20}}}"#
        ].joined(separator: "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)

        let report = await ClaudeJSONLScanner.usageReport(files: [url])

        XCTAssertEqual(report.buckets.count, 2, "old days must stay in buckets for the heatmap")
        XCTAssertEqual(report.totalTokens, 30, "totals must only count the rolling 30-day window")
        XCTAssertEqual(report.byModel.first?.tokens, 30, "per-model totals must apply the same cutoff")
    }

    /// Resuming a session copies the earlier transcript into a new file, so the
    /// same assistant message is present in both. Per-file dedup therefore inflated the counts.
    func testDropsARecordAlreadyCountedInAnotherFile() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("claude-resume-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let shared = #"{"timestamp":"\#(ts)","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20}}}"#
        let fresh = #"{"timestamp":"\#(ts)","requestId":"req-2","message":{"id":"msg-2","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1,"output_tokens":2}}}"#
        let original = dir.appendingPathComponent("a-original.jsonl")
        let resumed = dir.appendingPathComponent("b-resumed.jsonl")
        try shared.write(to: original, atomically: true, encoding: .utf8)
        try [shared, fresh].joined(separator: "\n").write(to: resumed, atomically: true, encoding: .utf8)

        let report = await ClaudeJSONLScanner.usageReport(files: [original, resumed])

        XCTAssertEqual(report.totalTokens, 33, "the replayed message must be counted once, not twice")
    }

    /// Records without a `message.id` cannot be deduplicated, so they must keep
    /// summing — dropping them would under-count instead.
    func testKeepsEveryRecordThatHasNoMessageID() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("claude-nokey-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let line = #"{"timestamp":"\#(ts)","message":{"model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":0}}}"#
        try [line, line, line].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let report = await ClaudeJSONLScanner.usageReport(files: [url])

        XCTAssertEqual(report.totalTokens, 30)
    }

    func testWindowedScanIsNotMarkedAsCompleteHistory() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("claude-flag-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        try #"{"timestamp":"\#(ts)","requestId":"r","message":{"id":"m","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1,"output_tokens":0}}}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let windowed = await ClaudeJSONLScanner.usageReport(files: [url])
        let complete = await ClaudeJSONLScanner.usageReport(files: [url], completeHistory: true)

        XCTAssertFalse(windowed.isCompleteHistory)
        XCTAssertTrue(complete.isCompleteHistory)
    }

    /// Scan provenance describes one read, not stored state; restoring it from a
    /// cache would let a stale flag lower ledger days it never actually saw.
    func testCompleteHistoryFlagIsNotPersisted() throws {
        let report = UsageReport(provider: .claude, buckets: [], totalCostUSD: 0,
                                 totalTokens: 0, byModel: [], isCompleteHistory: true)

        let decoded = try JSONDecoder().decode(
            UsageReport.self, from: try JSONEncoder().encode(report))

        XCTAssertFalse(decoded.isCompleteHistory)
    }

    func testRollingThirtyDayCutoffIncludesTodayAndPreviousTwentyNineDays() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("claude-jsonl-boundary-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let outside = ISO8601DateFormatter().string(from: cal.date(byAdding: .day, value: -30, to: today)!)
        let inside = ISO8601DateFormatter().string(from: cal.date(byAdding: .day, value: -29, to: today)!)
        let payload = [
            #"{"timestamp":"\#(outside)","requestId":"req-out","message":{"id":"msg-out","model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":0}}}"#,
            #"{"timestamp":"\#(inside)","requestId":"req-in","message":{"id":"msg-in","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20}}}"#
        ].joined(separator: "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)

        let report = await ClaudeJSONLScanner.usageReport(files: [url])

        XCTAssertEqual(report.buckets.count, 2, "heatmap buckets keep scanned boundary days")
        XCTAssertEqual(report.totalTokens, 30, "30-day totals are today plus the previous 29 days")
        XCTAssertEqual(report.byModel.first?.tokens, 30)
    }

    /// Incremental resume must carry the per-file dedup set: a duplicate message
    /// that lands in the appended tail (after the cached head) must not recount.
    func testIncrementalAppendPreservesDedupAcrossResume() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("claude-incr-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let line = #"{"timestamp":"\#(ts)","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20}}}"#
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let first = await ClaudeJSONLScanner.usageReport(files: [url])
        XCTAssertEqual(first.totalTokens, 30)

        try appendLine(line, to: url)
        let second = await ClaudeJSONLScanner.usageReport(files: [url])
        XCTAssertEqual(second.totalTokens, 30, "duplicate message.id across the resume boundary must stay deduped")
    }

    /// The flip side: a genuinely new record in the appended tail must be counted,
    /// proving the resume actually parses the tail rather than returning the cache.
    func testIncrementalAppendCountsNewRecords() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("claude-incr2-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let head = #"{"timestamp":"\#(ts)","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20}}}"#
        try (head + "\n").write(to: url, atomically: true, encoding: .utf8)
        _ = await ClaudeJSONLScanner.usageReport(files: [url])

        let tail = #"{"timestamp":"\#(ts)","requestId":"req-2","message":{"id":"msg-2","model":"claude-sonnet-4-20250514","usage":{"input_tokens":5,"output_tokens":5}}}"#
        try appendLine(tail, to: url)
        let second = await ClaudeJSONLScanner.usageReport(files: [url])
        XCTAssertEqual(second.totalTokens, 40, "the appended record must add to the prior total")
    }

    private func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    func testRecentLogFilesFiltersOldFilesByModificationDate() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("claude-recent-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let old = base.appendingPathComponent("old.jsonl")
        let recent = base.appendingPathComponent("recent.jsonl")
        try "{}".write(to: old, atomically: true, encoding: .utf8)
        try "{}".write(to: recent, atomically: true, encoding: .utf8)

        let cutoff = Date(timeIntervalSince1970: 2_000)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: recent.path)

        XCTAssertEqual(ClaudeJSONLScanner.recentLogFiles([old, recent], modifiedSince: cutoff), [recent])
    }
}
