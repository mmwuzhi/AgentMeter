import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeJSONLScannerTests: XCTestCase {
    func testUsageReportParsesInjectedJSONLFiles() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("claude-jsonl-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let payload = [
            #"{"timestamp":"2026-07-05T01:02:03Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":7,"ephemeral_1h_input_tokens":11}}}}"#,
            #"{"timestamp":"2026-07-05T01:02:04Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":999,"output_tokens":999}}}"#
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
