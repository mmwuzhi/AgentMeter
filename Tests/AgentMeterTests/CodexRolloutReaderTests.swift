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

    /// Same contract as the Claude scanner: `dayModels` carries the counts
    /// behind every bucket split by model — the session's model at the time of
    /// each `token_count` — and priced under the scan's own table they give
    /// back the scan-time dollars exactly.
    func testUsageReportCarriesPerDayModelCountsThatPriceLikeItsBuckets() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("codex-daymodels-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: Date().addingTimeInterval(-3_600))
        let earlier = iso.string(from: Date().addingTimeInterval(-3 * 86_400))
        let payload = [
            #"{"timestamp":"\#(earlier)","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"\#(earlier)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5}}}}"#,
            #"{"timestamp":"\#(recent)","payload":{"model":"gpt-5.1-codex-max"}}"#,
            #"{"timestamp":"\#(recent)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30}}}}"#
        ].joined(separator: "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)

        let report = await CodexRolloutReader.usageReport(files: [url])

        XCTAssertEqual(report.buckets.count, 2)
        XCTAssertEqual(Set(report.dayModels.map(\.model)), ["gpt-5-codex", "gpt-5.1-codex-max"],
                       "each day's counts stay under the model the session named")
        for bucket in report.buckets {
            let counted = report.dayModels.filter { $0.day == bucket.day }.reduce(0) { $0 + $1.counts.total }
            XCTAssertEqual(counted, bucket.totalTokens, "the day's per-model counts must add up to its bucket")
        }
        let table = await PricingService.shared.snapshot()
        XCTAssertEqual(report.costUSD(from: nil, table: table),
                       report.buckets.reduce(0) { $0 + $1.costUSD }, accuracy: 1e-6,
                       "the counts priced under the scan's table must give back the scan-time dollars")
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

    func testCycleAcceptsPlausibleCadences() {
        XCTAssertEqual(CodexRolloutReader.cycle(forMinutes: 300), 5 * 3600)
        XCTAssertEqual(CodexRolloutReader.cycle(forMinutes: 60 * 24 * 7), 7 * 24 * 3600)
        XCTAssertEqual(CodexRolloutReader.cycle(forMinutes: 5), CodexRolloutReader.minimumCycle)
    }

    func testLabelSurvivesAnImplausibleCadence() {
        // `Int(Double)` traps on NaN, on infinity and past Int64, and `minutes`
        // is a raw provider number, so the label goes through the same band the
        // cycle does rather than crashing the refresh.
        XCTAssertEqual(CodexRolloutReader.label(forMinutes: .nan), "Quota")
        XCTAssertEqual(CodexRolloutReader.label(forMinutes: .infinity), "Quota")
        XCTAssertEqual(CodexRolloutReader.label(forMinutes: 1e25), "Quota")
        XCTAssertEqual(CodexRolloutReader.label(forMinutes: 0), "Quota")
        XCTAssertEqual(CodexRolloutReader.label(forMinutes: -300), "Quota")
        // The believable band still reads the way it always did.
        XCTAssertEqual(CodexRolloutReader.label(forMinutes: 300), "5-hour")
        XCTAssertEqual(CodexRolloutReader.label(forMinutes: 60 * 24 * 7), "7-day")
    }

    func testCycleRejectsImplausibleCadences() {
        // `cycle` is a raw provider number and it only ever feeds rules that
        // *suppress* a warning (the peer-capacity floor and the run-out
        // horizon), so a units change or a truncated field must read as "no
        // cadence stated" rather than as a very fast refill.
        XCTAssertNil(CodexRolloutReader.cycle(forMinutes: 0))
        XCTAssertNil(CodexRolloutReader.cycle(forMinutes: -300))
        XCTAssertNil(CodexRolloutReader.cycle(forMinutes: 1))
        XCTAssertNil(CodexRolloutReader.cycle(forMinutes: 60 * 24 * 365))
        XCTAssertNil(CodexRolloutReader.cycle(forMinutes: .nan))
        XCTAssertNil(CodexRolloutReader.cycle(forMinutes: .infinity))
    }

}
