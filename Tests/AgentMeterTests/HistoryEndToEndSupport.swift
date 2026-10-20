import Foundation
import os
import XCTest
@testable import AgentMeter

// The end-to-end harness: the REAL scanner, the REAL usage cache over a
// temporary directory and the REAL `HistoryStore` over another, fed by
// transcripts `TranscriptFixture` writes into a temporary projects tree.
// Nothing here touches Application Support or `HistoryStore.shared`.

/// A projects tree several lanes scan. Birth times are injected (the store
/// reads them through `HistoryDatabaseConfiguration.birthTime`), so a fork's
/// owner does not depend on how fast the test wrote its files.
final class E2ETree: @unchecked Sendable {
    let root: URL
    let project: URL
    let births = HMBirths()
    private var nextBirth: Int64 = 1_780_000_000_000

    init(root: URL) throws {
        self.root = root
        project = root.appendingPathComponent("projects/-Users-dev-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func main(_ session: String = TranscriptFixture.session) -> URL {
        project.appendingPathComponent("\(session).jsonl")
    }

    func subagent(_ agent: String, session: String = TranscriptFixture.session) -> URL {
        project.appendingPathComponent("\(session)/subagents/agent-\(agent).jsonl")
    }

    func workflowAgent(_ agent: String, run: String, session: String = TranscriptFixture.session) -> URL {
        project.appendingPathComponent("\(session)/subagents/workflows/\(run)/agent-\(agent).jsonl")
    }

    /// Writes `lines` (newline-terminated). A path seen for the first time gets
    /// the next birth time (1 s after the previous one) unless `birth` is given.
    func write(_ lines: [String], to url: URL, birth: Int64? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TranscriptFixture.write(lines, to: url)
        if births.get(url.path) == nil {
            if let birth {
                births.set(url.path, birth)
            } else {
                births.set(url.path, nextBirth)
                nextBirth += 1_000
            }
        }
    }

    func append(_ lines: [String], to url: URL) throws {
        try TranscriptFixture.append(lines.joined(separator: "\n") + "\n", to: url)
    }

    /// Truncates and rewrites the file through the SAME inode.
    func rewriteInPlace(_ lines: [String], at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    /// Every transcript under the tree, in path order.
    var files: [URL] {
        let base = root.appendingPathComponent("projects", isDirectory: true)
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" { out.append(url.resolvingSymlinksInPath()) }
        return out.sorted { $0.path < $1.path }
    }
}

/// One app instance's view: a usage cache and a history store, each over its
/// own temporary directory, scanning a shared tree.
final class E2ELane: @unchecked Sendable {
    let tree: E2ETree
    let dir: URL
    let timeZone: TimeZone
    let realBirth: Bool
    let clock = HMClock()
    private(set) var cache: ClaudeUsageCache
    private(set) var store: HistoryStore

    var cacheDir: URL { dir.appendingPathComponent("amcu", isDirectory: true) }
    var dbDir: URL { dir.appendingPathComponent("db", isDirectory: true) }

    init(tree: E2ETree, name: String, timeZone: TimeZone = .current, realBirth: Bool = false) {
        self.tree = tree
        self.timeZone = timeZone
        self.realBirth = realBirth
        dir = tree.root.appendingPathComponent("lane-\(name)", isDirectory: true)
        cache = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: dir.appendingPathComponent("amcu", isDirectory: true)))
        store = Self.makeStore(dir.appendingPathComponent("db", isDirectory: true), tree: tree, timeZone: timeZone,
                               clock: clock, realBirth: realBirth)
    }

    static func makeStore(_ dbDir: URL, tree: E2ETree, timeZone: TimeZone, clock: HMClock, realBirth: Bool) -> HistoryStore {
        let births = tree.births
        return HistoryStore(directory: dbDir, clock: { clock.get() }, timeZone: timeZone) { config in
            if !realBirth { config.birthTime = { births.get($0) } }
        }
    }

    /// One scan through this lane's cache. `history` defaults to the lane's store.
    @discardableResult
    func scan(_ files: [URL]? = nil, complete: Bool = true,
              history: (any HistoryIngesting)?? = .none) async -> UsageReport {
        let sink: (any HistoryIngesting)? = history ?? store
        return await ClaudeJSONLScanner.usageReport(files: files ?? tree.files, completeHistory: complete,
                                                    cache: cache, history: sink)
    }

    /// A new process: closes the store (a clean shutdown, which releases the
    /// lock), then a new usage cache over the same directory and/or a new
    /// store over the same database directory.
    func restart(cache newCache: Bool = true, store newStore: Bool = true) async {
        if newStore {
            // Drain first: `close()` between two queued commands would only
            // be undone by the drain's next command, which reopens (and
            // re-locks) the database under the old instance.
            await store.flush()
            await store.close()
            store = Self.makeStore(dbDir, tree: tree, timeZone: timeZone, clock: clock, realBirth: realBirth)
        }
        if newCache { cache = ClaudeUsageCache(store: ClaudeUsageCacheStore(directory: cacheDir)) }
    }

    func dump() async throws -> HistoryLogicalDump {
        await store.flush()
        return try await store.logicalDump()
    }

    func dayModels() async throws -> [HistoryDayModelUsage] {
        await store.flush()
        return try await store.dayModelUsage()
    }

    /// `sqlite3_total_changes` of the store's current connection.
    func totalChanges() async throws -> Int64 {
        await store.flush()
        return try await store.withDatabase { $0.conn.totalChanges }
    }

    func scanStats() async -> ClaudeScanStats.Snapshot { await cache.stats.snapshot() }

    func close() async {
        await store.flush()
        await store.close()
    }
}

/// The order-independence oracle: a FRESH cache and a FRESH store that
/// ingest `files` in ONE cold complete scan.
func e2eOracle(_ tree: E2ETree, files: [URL]? = nil, timeZone: TimeZone = .current,
               realBirth: Bool = false) async throws -> (dump: HistoryLogicalDump, report: UsageReport) {
    let lane = E2ELane(tree: tree, name: "oracle-\(UUID().uuidString.prefix(8))", timeZone: timeZone, realBirth: realBirth)
    let report = await lane.scan(files, complete: true)
    let dump = try await lane.dump()
    await lane.close()
    try? FileManager.default.removeItem(at: lane.dir)
    return (dump, report)
}

/// A whole-file batch of `lines` under `path`, parsed the way the scanner
/// parses (for oracles that need a contribution the tree no longer holds).
func e2eManualBatch(path: String, lines: [String], ticket: UInt64) -> HistoryFileBatch {
    let usage = TranscriptFixture.parse(lines)
    let wm = HistoryFileWatermark(fileID: hmStableID(path), volumeID: 1, size: Int64(ticket), modifiedAt: Double(ticket),
                                  parsedBytes: Int64(ticket), boundaryDigest: Data([UInt8(truncatingIfNeeded: ticket)]),
                                  parserVersion: Int(ClaudeUsageCacheStore.formatVersion))
    return HistoryFileBatch(path: path, scan: ticket, watermark: wm, delta: nil,
                            allRequests: { usage.allObservations() }, events: usage.extras)
}

/// Forwards to a target, records every scan batch, and drops the next
/// `dropScans` scan batches (an app that died between saving the usage cache
/// and ingesting).
final class E2ETeeSink: HistoryIngesting, @unchecked Sendable {
    private let lock = NSLock()
    private let target: (any HistoryIngesting)?
    private var recorded: [HistoryScanBatch] = []
    private var toDrop = 0
    private(set) var dropped = 0

    init(_ target: (any HistoryIngesting)?) { self.target = target }

    func dropNext(_ n: Int = 1) {
        lock.lock()
        toDrop += n
        lock.unlock()
    }

    func submit(scan: HistoryScanBatch) {
        lock.lock()
        recorded.append(scan)
        let drop = toDrop > 0
        if drop {
            toDrop -= 1
            dropped += 1
        }
        lock.unlock()
        if !drop { target?.submit(scan: scan) }
    }

    func submit(quota: [QuotaSampleRow]) { target?.submit(quota: quota) }
    func submit(legacyQuota: [QuotaSampleRow]) { target?.submit(legacyQuota: legacyQuota) }
    func submit(resetGrants: [ResetGrantObservation], recordedMs: Int64) {
        target?.submit(resetGrants: resetGrants, recordedMs: recordedMs)
    }

    var scans: [HistoryScanBatch] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// MARK: - Fixture records

enum E2EFix {
    static let opus = "claude-opus-5-5"
    static let fable = "claude-fable-5-1"
    static let sonnet = "claude-sonnet-5-5"

    /// Local midnight (in the current zone) that starts 2026-10-15 + `dayOffset`.
    static func localMidnight(dayOffset: Int = 0, timeZone: TimeZone = .current) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        return HistoryTime.ms(cal.date(byAdding: .day, value: dayOffset, to: day)!)
    }

    /// 2026-10-15 10:00 local: every scenario's records start here.
    static var t0: Int64 { localMidnight() + 10 * 3_600_000 }

    static func counts(_ output: Int, input: Int = 2, cacheRead: Int = 1_000, w5m: Int = 50, w1h: Int = 0)
        -> TranscriptFixture.Counts {
        var c = TranscriptFixture.Counts()
        c.output = output
        c.input = input
        c.cacheRead = cacheRead
        c.w5m = w5m
        c.w1h = w1h
        return c
    }

    /// An assistant usage record of request `n` (`msg_e2e_<n>` / `req_e2e_<n>`).
    static func rec(_ n: Int, _ ms: Int64, out: Int = 10, input: Int = 2, final: Bool = true, zeroed: Bool = false,
                    model: String = opus, version: String = "2.1.301", effort: String? = "high",
                    entrypoint: String? = "claude-vscode", cwd: String? = TranscriptFixture.cwd,
                    iterations: [(model: String, counts: TranscriptFixture.Counts)]? = nil,
                    thinking: Int? = nil, sidechain: Bool = false, aborted: Bool = false, tag: String = "a") -> String {
        let top = iterations?.last?.counts ?? counts(out, input: input)
        return TranscriptFixture.assistant(
            uuid: "u-\(n)-\(ms)-\(tag)", ts: TranscriptFixture.iso24(ms), mid: "msg_e2e_\(n)", rid: "req_e2e_\(n)",
            model: model, stop: final ? "end_turn" : nil, counts: top, zeroed: zeroed, version: version,
            effort: effort, entrypoint: entrypoint, cwd: cwd, thinking: thinking, aborted: aborted,
            iterations: iterations, sidechain: sidechain)
    }

    static func user(_ ms: Int64, tag: String = "a") -> String {
        TranscriptFixture.user(uuid: "user-\(ms)-\(tag)", ts: TranscriptFixture.iso24(ms))
    }
}

// MARK: - Assertions

/// YYYYMMDD of a report day (a local start of day), as `acct_day` writes it.
func e2eDayNumber(_ day: Date, timeZone: TimeZone = .current) -> Int64 {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let c = cal.dateComponents([.year, .month, .day], from: day)
    return Int64(c.year! * 10_000 + c.month! * 100 + c.day!)
}

func e2eAssertDump(_ got: HistoryLogicalDump, _ want: HistoryLogicalDump, _ label: String,
                   file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(got.sha256Hex, want.sha256Hex, "\(label): \(hmDiff(got, want))", file: file, line: line)
}

/// DB `acct_day` x model sums == the report's `dayModels` (entries with no
/// tokens dropped on both sides: the report never files an empty part).
func e2eAssertDayModels(_ db: [HistoryDayModelUsage], _ report: UsageReport, _ label: String,
                        file: StaticString = #filePath, line: UInt = #line) {
    var a: [String: TokenCounts] = [:]
    for r in db { a["\(r.acctDay.map(String.init) ?? "nil") \(r.model)", default: TokenCounts()].add(r.counts) }
    var b: [String: TokenCounts] = [:]
    for e in report.dayModels { b["\(e2eDayNumber(e.day)) \(e.model)", default: TokenCounts()].add(e.counts) }
    a = a.filter { $0.value.total > 0 }
    b = b.filter { $0.value.total > 0 }
    var diffs: [String] = []
    for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
        diffs.append("  \(key): db \(a[key].map { "\($0)" } ?? "-") report \(b[key].map { "\($0)" } ?? "-")")
    }
    XCTAssertTrue(diffs.isEmpty, "\(label): day x model sums differ\n" + diffs.joined(separator: "\n"), file: file, line: line)
    XCTAssertFalse(b.isEmpty, "\(label): the report has usage", file: file, line: line)
}

extension XCTestCase {
    /// A fresh tree under the system temp dir, removed at tear-down (permissions restored first).
    func e2eTree(_ name: String = #function) throws -> E2ETree {
        let root = historyTempDirectory(name)
        addTeardownBlock {
            if let en = FileManager.default.enumerator(atPath: root.path) {
                for case let rel as String in en {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                           ofItemAtPath: root.appendingPathComponent(rel).path)
                }
            }
        }
        return try E2ETree(root: root)
    }
}
