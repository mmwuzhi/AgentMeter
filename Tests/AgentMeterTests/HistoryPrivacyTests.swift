import Foundation
import XCTest
@testable import AgentMeter

/// No conversation content reaches disk. Every content-bearing field of every
/// record shape the scanner meets carries a canary; the REAL scanner parses
/// the transcript into a REAL `ClaudeUsageCacheStore` and a REAL
/// `HistoryStore`, and the canary must be in no byte of any file they wrote:
/// the database, its `-wal` (scanned while it still holds the commits, and
/// again after the close checkpointed it), `-shm`, the lock file and the
/// usage-cache entry. Ids, times, counts, labels and paths are stored by
/// design; text never is.
///
/// Everything lives under one temporary directory, and the test checks the
/// directories both stores were given before either writes, so it cannot
/// reach the app's database or cache under Application Support.
final class HistoryPrivacyTests: XCTestCase {
    private static let canary = "ZQXCANARY"

    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private func isInside(_ url: URL, _ dir: URL) -> Bool {
        let path = resolved(url), base = resolved(dir)
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Every regular file below `dir`, named by its path from `dir` ("/a/b").
    private func files(below dir: URL) throws -> [(name: String, data: Data)] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = resolved(dir)
        var out: [(String, Data)] = []
        for case let url as URL in walker where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let path = resolved(url)
            XCTAssertTrue(path.hasPrefix(base + "/"), path)
            out.append((String(path.dropFirst(base.count)), try Data(contentsOf: url)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private func assertNoCanary(in written: [(name: String, data: Data)], _ when: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        for needle in [Self.canary, Self.canary.lowercased(), "secret prompt"] {
            for f in written {
                XCTAssertNil(f.data.range(of: Data(needle.utf8)), "\(when): \"\(needle)\" found in \(f.name)",
                             file: file, line: line)
            }
        }
    }

    /// One transcript in which every field that holds conversation text — the
    /// user's and the assistant's text, thinking, a tool call's input, a tool
    /// result, error bodies, the `<synthetic>` 429's text, the `/usage`
    /// command's output, a compaction's summary, titles, summaries, the last
    /// prompt, queued prompts, attachments and the string fields of
    /// `cost-state` the scanner does not read — holds the canary.
    private func canaryTranscript(at url: URL) throws {
        let c = Self.canary
        let t = TranscriptFixture.self
        let ts = { (n: Int64) in t.iso24(t.base + n * 1_000) }
        var lines: [String] = [
            t.user(uuid: "u1", ts: ts(1)),
            t.assistant(uuid: "a1", ts: ts(2), mid: "msg_1", rid: "req_1", stop: "end_turn", thinking: 7),
            t.assistant(uuid: "a2", ts: ts(3), mid: "msg_2", rid: "req_2", stop: nil),
            t.synthetic429(uuid: "s1", ts: ts(4), rid: "req_3", form: .both),
            t.synthetic429(uuid: "s2", ts: ts(5), rid: "req_4", form: .quotaLimits),
            t.usageCommand(uuid: "c1", ts: ts(6), shape: .threeLimits),
            t.costState(start: t.base, total: 60_000),
            t.compactBoundary(uuid: "b1", ts: ts(7)),
            t.title(),
        ].map { $0.replacingOccurrences(of: "placeholder", with: c + " secret prompt text") }
        // Shapes and fields the fixtures do not carry.
        lines.append(#"{"parentUuid":"x-p","isSidechain":false,"userType":"external","cwd":"\#(t.cwd)","sessionId":"\#(t.session)","version":"2.1.301","message":{"model":"claude-opus-5-5","id":"msg_9","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"\#(c) thinking","signature":"\#(c)"},{"type":"text","text":"\#(c) answer"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo \#(c)","description":"\#(c)"}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}},"requestId":"req_9","type":"assistant","uuid":"x9","timestamp":"\#(ts(8))","error":{"message":"\#(c) error"}}"#)
        lines.append(#"{"parentUuid":"x9","isSidechain":false,"userType":"external","cwd":"\#(t.cwd)","sessionId":"\#(t.session)","version":"2.1.301","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"\#(c) tool output"}]},"uuid":"r9","timestamp":"\#(ts(9))","toolUseResult":{"stdout":"\#(c)","stderr":"\#(c)"}}"#)
        lines.append(#"{"parentUuid":"r9","isSidechain":false,"type":"system","subtype":"api_error","level":"error","content":"\#(c) api error","error":{"message":"\#(c)"},"timestamp":"\#(ts(10))","uuid":"e1","userType":"external","cwd":"\#(t.cwd)","sessionId":"\#(t.session)","version":"2.1.301"}"#)
        lines.append(#"{"parentUuid":"e1","isSidechain":false,"type":"attachment","attachment":{"type":"file","content":"\#(c) attachment"},"timestamp":"\#(ts(11))","uuid":"at1","sessionId":"\#(t.session)"}"#)
        lines.append(#"{"type":"queue-operation","operation":"enqueue","timestamp":"\#(ts(12))","sessionId":"\#(t.session)","content":"\#(c) queued prompt"}"#)
        lines.append(#"{"type":"summary","summary":"\#(c) summary","leafUuid":"x9"}"#)
        lines.append(#"{"type":"last-prompt","lastPrompt":"\#(c) last prompt","sessionId":"\#(t.session)"}"#)
        lines.append(#"{"type":"custom-title","customTitle":"\#(c) title","sessionId":"\#(t.session)"}"#)
        lines.append(#"{"type":"cost-state","sessionId":"\#(t.session)","totalCostUSD":2.5,"totalAPIDuration":4000,"totalDuration":120000,"startTime":\#(t.base),"note":"\#(c) extra","modelUsage":{"claude-opus-5-5":{"inputTokens":1,"outputTokens":2,"costUSD":0.5,"comment":"\#(c)"}},"hasUnknownModelCost":false}"#)
        try TranscriptFixture.write(lines, to: url)
    }

    func testNoConversationContentReachesTheHistoryOrTheUsageCache() async throws {
        let root = historyTempDirectory()
        let logs = root.appendingPathComponent("projects/-Users-dev-project", isDirectory: true)
        let dbDir = root.appendingPathComponent("db", isDirectory: true)
        let cacheDir = root.appendingPathComponent("amcu", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        // Where the app keeps its real files. Nothing below may be written
        // here; the shared store and cache are never touched (not even built).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The store's log goes to the unified log as public text, so it is
        // held to the same rule as the files.
        let logLines = HistoryOrderLog()
        let store = HistoryStore(directory: dbDir, log: { logLines.add($0) })
        let cacheStore = ClaudeUsageCacheStore(directory: cacheDir)
        let cache = ClaudeUsageCache(store: cacheStore)
        let entriesDir = await cacheStore.directory
        guard isInside(store.databaseURL, dbDir), isInside(entriesDir, cacheDir),
              !isInside(root, support), !isInside(store.databaseURL, support), !isInside(entriesDir, support),
              !isInside(store.databaseURL, HistoryStore.defaultDirectory),
              !isInside(entriesDir, ClaudeUsageCacheStore.defaultDirectory)
        else {
            return XCTFail("the stores must live in the test's temporary directory, never under \(support.path)")
        }

        let transcript = logs.appendingPathComponent("\(TranscriptFixture.session).jsonl")
        try canaryTranscript(at: transcript)
        XCTAssertNotNil(try Data(contentsOf: transcript).range(of: Data(Self.canary.utf8)), "the canary is in the transcript")

        _ = await ClaudeJSONLScanner.usageReport(files: [transcript], completeHistory: true, cache: cache, history: store)
        await store.flush()
        let counts = try await store.historyStatistics().rowCounts
        // Every record shape reached its table, so the scan below is not vacuous.
        XCTAssertEqual(counts["request"], 3, "msg_1, msg_2 and the content-heavy msg_9")
        XCTAssertEqual(counts["limit_event"], 2)
        XCTAssertEqual(counts["usage_report_sample"], 1)
        XCTAssertEqual(counts["usage_report_limit"], 3)
        XCTAssertEqual(counts["cost_state_sample"], 2)
        XCTAssertEqual(counts["compact_event"], 1)
        XCTAssertEqual(counts["session"], 1)

        // Open: the commits are still in the WAL.
        let db = try files(below: dbDir), entries = try files(below: cacheDir)
        let name = HistoryDatabase.fileName
        XCTAssertEqual(Set(db.map(\.name)), ["/\(name)", "/\(name)-wal", "/\(name)-shm", "/\(name).lock"])
        XCTAssertGreaterThan(db.first { $0.name == "/\(name)-wal" }?.data.count ?? 0, 0,
                             "the WAL holds the commits while the store is open")
        XCTAssertEqual(entries.count, 1, "one usage-cache entry for the one transcript")
        XCTAssertGreaterThan(entries.first?.data.count ?? 0, 0)
        assertNoCanary(in: db + entries, "while open")
        print("[history-privacy] scanned while open: " + (db + entries).map { "\($0.name) \($0.data.count) B" }.joined(separator: ", "))

        await store.close()
        assertNoCanary(in: try files(below: dbDir) + files(below: cacheDir), "after close")
        XCTAssertFalse(logLines.all.isEmpty, "the store logged its open, so the check below is not vacuous")
        for line in logLines.all {
            for needle in [Self.canary, Self.canary.lowercased(), "secret prompt", "/"] {
                XCTAssertFalse(line.contains(needle), "log line holds \(needle): \(line)")
            }
        }
        // Nothing else was written anywhere in the temporary tree.
        let elsewhere = try files(below: root).map(\.name).filter { !$0.hasPrefix("/db/") && !$0.hasPrefix("/amcu/") }
        XCTAssertEqual(elsewhere, ["/projects/-Users-dev-project/\(TranscriptFixture.session).jsonl"])
    }
}
