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
