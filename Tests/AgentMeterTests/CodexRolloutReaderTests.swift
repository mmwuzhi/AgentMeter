import Foundation
@testable import AgentMeter
import XCTest

final class CodexRolloutReaderTests: XCTestCase {
    /// Regression: Codex ≥0.142 moves older sessions from `~/.codex/sessions`
    /// into `~/.codex/archived_sessions`. The reader used to enumerate only the
    /// live `sessions` dir, so the instant Codex archived an active session the
    /// day's usage/spend collapsed to whatever was still live. `rolloutFiles`
    /// must walk both roots.
    func testRolloutFilesIncludeArchivedSessions() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("codex-reader-\(UUID().uuidString)")
        let live = base.appendingPathComponent("sessions/2026/07/02", isDirectory: true)
        let archived = base.appendingPathComponent("archived_sessions", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let liveFile = live.appendingPathComponent("rollout-2026-07-02T21-00-00-aaaa.jsonl")
        let archivedFile = archived.appendingPathComponent("rollout-2026-07-02T18-00-00-bbbb.jsonl")
        try "{}".write(to: liveFile, atomically: true, encoding: .utf8)
        try "{}".write(to: archivedFile, atomically: true, encoding: .utf8)

        let roots = [base.appendingPathComponent("sessions"), archived]
        let names = CodexRolloutReader.rolloutFiles(in: roots).map(\.lastPathComponent)

        XCTAssertTrue(names.contains("rollout-2026-07-02T18-00-00-bbbb.jsonl"),
                      "archived session must be counted")
        XCTAssertTrue(names.contains("rollout-2026-07-02T21-00-00-aaaa.jsonl"),
                      "live session must be counted")
    }

    /// A session momentarily present in both roots during an archive move must
    /// not be double-counted, or the day would briefly show inflated tokens.
    func testRolloutFilesDedupeSameNameAcrossRoots() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("codex-reader-\(UUID().uuidString)")
        let live = base.appendingPathComponent("sessions", isDirectory: true)
        let archived = base.appendingPathComponent("archived_sessions", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let name = "rollout-2026-07-02T18-00-00-bbbb.jsonl"
        try "{}".write(to: live.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try "{}".write(to: archived.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let files = CodexRolloutReader.rolloutFiles(in: [live, archived])
        XCTAssertEqual(files.filter { $0.lastPathComponent == name }.count, 1,
                       "same rollout name across roots must be deduped")
    }

    /// The production roots must include the archived directory.
    func testSessionRootsIncludeArchived() {
        let names = CodexRolloutReader.sessionRoots.map(\.lastPathComponent)
        XCTAssertTrue(names.contains("sessions"))
        XCTAssertTrue(names.contains("archived_sessions"))
    }

    func testUsageReportParsesInjectedRolloutFiles() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("codex-rollout-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        // Dynamic timestamp: totals apply a rolling 30-day cutoff, so a fixed
        // date here would silently age out of the window and start failing.
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let payload = [
            #"{"timestamp":"\#(ts)","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"\#(ts)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30}}}}"#
        ].joined(separator: "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)

        let report = await CodexRolloutReader.usageReport(files: [url])

        XCTAssertEqual(report.totalTokens, 150)
        XCTAssertEqual(report.buckets.first?.inputTokens, 100)
        XCTAssertEqual(report.buckets.first?.cacheRead, 20)
        XCTAssertEqual(report.buckets.first?.outputTokens, 30)
    }

    /// Regression: totalTokens/totalCostUSD/byModel are surfaced as "30-day"
    /// totals, but used to sum every day the file scan picked up, disagreeing
    /// with SpendWindows.lastDays(30). Days beyond the rolling cutoff must
    /// still appear in buckets (heatmap) while staying out of the totals.
    func testTotalsApplyRollingThirtyDayCutoffWhileBucketsKeepAllDays() async throws {
        let fm = FileManager.default
        let oldURL = fm.temporaryDirectory.appendingPathComponent("codex-rollout-old-\(UUID().uuidString).jsonl")
        let recentURL = fm.temporaryDirectory.appendingPathComponent("codex-rollout-new-\(UUID().uuidString).jsonl")
        defer {
            try? fm.removeItem(at: oldURL)
            try? fm.removeItem(at: recentURL)
        }
        let iso = ISO8601DateFormatter()
        let old = iso.string(from: Date().addingTimeInterval(-40 * 86_400))
        let recent = iso.string(from: Date().addingTimeInterval(-86_400))
        try [
            #"{"timestamp":"\#(old)","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"\#(old)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#
        ].joined(separator: "\n").write(to: oldURL, atomically: true, encoding: .utf8)
        try [
            #"{"timestamp":"\#(recent)","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"\#(recent)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30}}}}"#
        ].joined(separator: "\n").write(to: recentURL, atomically: true, encoding: .utf8)

        let report = await CodexRolloutReader.usageReport(files: [oldURL, recentURL])

        XCTAssertEqual(report.buckets.count, 2, "old days must stay in buckets for the heatmap")
        XCTAssertEqual(report.totalTokens, 150, "totals must only count the rolling 30-day window")
        XCTAssertEqual(report.byModel.first?.tokens, 150, "per-model totals must apply the same cutoff")
    }

    func testRollingThirtyDayCutoffIncludesTodayAndPreviousTwentyNineDays() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("codex-rollout-boundary-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let outside = ISO8601DateFormatter().string(from: cal.date(byAdding: .day, value: -30, to: today)!)
        let inside = ISO8601DateFormatter().string(from: cal.date(byAdding: .day, value: -29, to: today)!)
        let payload = [
            #"{"timestamp":"\#(outside)","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"\#(outside)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
            #"{"timestamp":"\#(inside)","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"\#(inside)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30}}}}"#
        ].joined(separator: "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)

        let report = await CodexRolloutReader.usageReport(files: [url])

        XCTAssertEqual(report.buckets.count, 2, "heatmap buckets keep scanned boundary days")
        XCTAssertEqual(report.totalTokens, 150, "30-day totals are today plus the previous 29 days")
        XCTAssertEqual(report.byModel.first?.tokens, 150)
    }

    /// Incremental resume must be additive and carry the session model: a
    /// token_count appended after the cached head (with no fresh model line) must
    /// add to the prior total and stay attributed to the head's model, not the
    /// default — otherwise a spurious second model bucket appears.
    func testIncrementalAppendIsAdditiveAndCarriesModel() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("codex-incr-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        // Deliberately not the default "gpt-5-codex", so a lost model shows up.
        let head = [
            #"{"timestamp":"\#(ts)","payload":{"model":"gpt-5.1-codex-max"}}"#,
            #"{"timestamp":"\#(ts)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30}}}}"#
        ].joined(separator: "\n") + "\n"
        try head.write(to: url, atomically: true, encoding: .utf8)

        let first = await CodexRolloutReader.usageReport(files: [url])
        XCTAssertEqual(first.totalTokens, 150)
        XCTAssertEqual(first.byModel.first?.model, "gpt-5.1-codex-max")

        let tail = #"{"timestamp":"\#(ts)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(tail.utf8))
        try handle.close()

        let second = await CodexRolloutReader.usageReport(files: [url])
        XCTAssertEqual(second.totalTokens, 165, "appended token_count must add to the prior total")
        XCTAssertEqual(second.byModel.count, 1, "carried model means no spurious default-model bucket")
        XCTAssertEqual(second.byModel.first?.model, "gpt-5.1-codex-max")
    }

    func testRecentRolloutFilesFiltersOldFilesByModificationDate() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("codex-recent-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let old = base.appendingPathComponent("old.jsonl")
        let recent = base.appendingPathComponent("recent.jsonl")
        try "{}".write(to: old, atomically: true, encoding: .utf8)
        try "{}".write(to: recent, atomically: true, encoding: .utf8)

        let cutoff = Date(timeIntervalSince1970: 2_000)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: recent.path)

        XCTAssertEqual(CodexRolloutReader.recentRolloutFiles([old, recent], modifiedSince: cutoff), [recent])
    }
}
