import Foundation
import os
import XCTest
@testable import AgentMeter

// Shared pieces of the merge tests: a reference model of the scanner's
// per-file fold over records, the CLOSED-FORM oracle of the merge rules
// (providers.md, "History store"), batch builders and the store harness.

// MARK: - Records and the per-file fold

/// One usage record as `consume(object:)` reduces it.
struct HMRecord: Sendable {
    var key: DedupKey
    var finality: UsageFinality
    var parts: [RequestPart]
    var thinking: Int?
    var version: String?
    var effort: String?
    var entrypoint: String?
    var flags: RequestFlags
    var ts: Int64?

    var outputTotal: Int { parts.reduce(0) { $0 + $1.counts.output } }
}

/// `ParseState.add` with the v3 stamp: the held record changes only when it is
/// outranked (finality, then strictly more output for partials); times and
/// flags MERGE over every record of the key (first = MIN over all, last = MAX
/// over non-zeroed, flags OR).
struct HMFold {
    private(set) var held: [DedupKey: RequestObservation] = [:]

    mutating func add(_ r: HMRecord) {
        let nonZeroTs = r.finality != .zeroed ? r.ts : nil
        guard let h = held[r.key] else {
            held[r.key] = Self.observation(r, first: r.ts, last: nonZeroTs, flags: r.flags)
            return
        }
        let first = HistoryNullAware.min(h.firstMs, r.ts)
        let last = HistoryNullAware.max(h.lastMs, nonZeroTs)
        let flags = h.flags.union(r.flags)
        let hOut = h.parts.reduce(0) { $0 + $1.counts.output }
        let outranks = r.finality != h.finality ? r.finality > h.finality : (r.finality == .partial && r.outputTotal > hOut)
        if outranks {
            held[r.key] = Self.observation(r, first: first, last: last, flags: flags)
        } else {
            held[r.key] = RequestObservation(key: h.key, parts: h.parts, finality: h.finality, firstMs: first, lastMs: last,
                                             finalMs: h.finalMs, thinkingTokens: h.thinkingTokens, ccVersion: h.ccVersion,
                                             effort: h.effort, entrypoint: h.entrypoint, flags: flags)
        }
    }

    static func observation(_ r: HMRecord, first: Int64?, last: Int64?, flags: RequestFlags) -> RequestObservation {
        RequestObservation(key: r.key, parts: r.parts, finality: r.finality, firstMs: first, lastMs: last,
                           finalMs: r.finality == .final ? r.ts : nil, thinkingTokens: r.thinking,
                           ccVersion: r.version, effort: r.effort, entrypoint: r.entrypoint, flags: flags)
    }

    /// In key-byte order, so a batch is deterministic.
    var observations: [RequestObservation] {
        held.values.sorted { $0.key.historyBytes.lexicographicallyPrecedes($1.key.historyBytes) }
    }
}

// MARK: - The closed-form oracle

/// What one file said at one parse state, under one parser version.
struct HMContribution: Sendable {
    let path: String
    let version: Int
    let observations: [RequestObservation]
}

enum HMOracle {
    /// The definition the database must equal, computed from the SET of
    /// contributions (order, partition and duplicates cannot enter it):
    /// rows = the parts of the max-rank observation; per occurrence first =
    /// MIN, last = MAX, attributes of the max (version, finality, output,
    /// att_sig) observation, flags OR; first_seen = MIN over occurrences;
    /// owner = argmin (last IS NULL, birth ?? +inf, path bytes); last_seen and
    /// attributes = the owner's; flags = OR; acct_day = day(first_seen) in
    /// `timeZone`, computed by `hmDay` (Foundation per time, NOT the store's
    /// cached `HistoryAccountingDays`, so a bug there cannot hide in both).
    static func dump(_ contributions: [HMContribution], births: [String: Int64], timeZone: TimeZone) -> HistoryLogicalDump {
        var dump = HistoryLogicalDump()
        let paths = Set(contributions.map(\.path)).sorted(by: historyBinaryLess)
        var sources: [String: HistorySourceFile] = [:]
        for p in paths { sources[p] = HistorySourceFile.parse(path: p, birthMs: births[p]) }
        dump.files = paths.map { p in
            let s = sources[p]!
            return .init(path: p, fileClass: Int64(s.fileClass.rawValue), sessionID: s.sessionID, agentID: s.agentID,
                         runID: s.runID, birthMs: s.birthMs)
        }
        dump.sessions = Set(sources.values.map(\.sessionID)).sorted(by: historyBinaryLess)
            .map { .init(sessionID: $0, firstCwd: nil, firstCwdMs: nil, entrypoint: nil, ccVersion: nil) }

        struct Occ {
            var first: Int64?
            var last: Int64?
            var attRank: (Int64, Int64, Int64, Int64)
            var source: RequestObservation
            var flags: RequestFlags
        }
        var byKey: [DedupKey: [(version: Int64, o: RequestObservation)]] = [:]
        var occ: [DedupKey: [String: Occ]] = [:]
        for c in contributions {
            for o in c.observations {
                let v = Int64(c.version)
                byKey[o.key, default: []].append((v, o))
                let att = (v, Int64(o.finality.rawValue), Int64(o.parts.reduce(0) { $0 + $1.counts.output }),
                           HistoryAttributeSignature.compute(o))
                if var cur = occ[o.key]?[c.path] {
                    cur.first = HistoryNullAware.min(cur.first, o.firstMs)
                    cur.last = HistoryNullAware.max(cur.last, o.lastMs)
                    cur.flags.formUnion(o.flags)
                    if att > cur.attRank { cur.attRank = att; cur.source = o }
                    occ[o.key]![c.path] = cur
                } else {
                    occ[o.key, default: [:]][c.path] = Occ(first: o.firstMs, last: o.lastMs, attRank: att, source: o, flags: o.flags)
                }
            }
        }
        let keys = byKey.keys.sorted { $0.historyBytes.lexicographicallyPrecedes($1.historyBytes) }
        for key in keys {
            let hex = key.historyHex
            let winner = byKey[key]!.max { HistoryRecordRank(ingestVersion: $0.version, observation: $0.o)
                < HistoryRecordRank(ingestVersion: $1.version, observation: $1.o) }!
            let occs = occ[key]!
            var first: Int64?
            var flags: RequestFlags = []
            for o in occs.values { first = HistoryNullAware.min(first, o.first); flags.formUnion(o.flags) }
            let ownerPath = occs.keys.min { a, b in
                let x = occs[a]!, y = occs[b]!
                if (x.last == nil) != (y.last == nil) { return x.last != nil }
                let bx = sources[a]!.birthMs ?? .max, by = sources[b]!.birthMs ?? .max
                if bx != by { return bx < by }
                return historyBinaryLess(a, b)
            }!
            let owner = occs[ownerPath]!
            let src = sources[ownerPath]!
            let rank = HistoryRecordRank(ingestVersion: winner.version, observation: winner.o)
            let day = hmDay(first, timeZone)
            for (idx, part) in winner.o.parts.enumerated() {
                dump.requests.append(.init(
                    keyHex: hex, idx: Int64(idx), model: part.model, input: Int64(part.counts.input),
                    output: Int64(part.counts.output), cacheWrite5m: Int64(part.counts.cacheWrite5m),
                    cacheWrite1h: Int64(part.counts.cacheWrite1h), cacheRead: Int64(part.counts.cacheRead),
                    thinking: idx == winner.o.parts.count - 1 ? winner.o.thinkingTokens.map(Int64.init) : nil,
                    finality: Int64(winner.o.finality.rawValue), parts: Int64(winner.o.parts.count),
                    outputTotal: rank.outputTotal, recSig: rank.recSig, ingestVersion: winner.version,
                    finalMs: winner.o.finalMs, firstSeenMs: first, lastSeenMs: owner.last, acctDay: day,
                    ownerPath: ownerPath, sessionID: src.sessionID, fileClass: Int64(src.fileClass.rawValue),
                    ccVersion: owner.source.ccVersion, effort: owner.source.effort, entrypoint: owner.source.entrypoint,
                    flags: Int64(flags.rawValue)))
            }
            for path in occs.keys.sorted(by: historyBinaryLess) {
                let o = occs[path]!
                dump.occurrences.append(.init(
                    keyHex: hex, path: path, firstMs: o.first, lastMs: o.last, ingestVersion: o.attRank.0,
                    attFin: o.attRank.1, attOut: o.attRank.2, attSig: o.attRank.3, ccVersion: o.source.ccVersion,
                    effort: o.source.effort, entrypoint: o.source.entrypoint, flags: Int64(o.flags.rawValue)))
            }
        }
        return dump
    }
}

// MARK: - Builders

/// The watermark and ingest version a real scan writes (`ClaudeHistoryBatch`).
let hmParserVersion = Int(ClaudeUsageCacheStore.formatVersion)

func hmKey(_ n: Int) -> DedupKey { DedupKey(messageID: "msg_\(n)", requestID: "req_\(n)") }

func hmPart(_ model: String = "claude-opus", input: Int = 1, output: Int, cw5m: Int = 0, cw1h: Int = 0,
            cacheRead: Int = 0) -> RequestPart {
    RequestPart(model: model, counts: TokenCounts(input: input, output: output, cacheWrite5m: cw5m,
                                                  cacheWrite1h: cw1h, cacheRead: cacheRead))
}

func hmObs(_ key: DedupKey, _ parts: [RequestPart], _ finality: UsageFinality, first: Int64?, last: Int64?,
           final: Int64? = nil, thinking: Int? = nil, cc: String? = nil, effort: String? = nil,
           entry: String? = nil, flags: RequestFlags = []) -> RequestObservation {
    RequestObservation(key: key, parts: parts, finality: finality, firstMs: first, lastMs: last, finalMs: final,
                       thinkingTokens: thinking, ccVersion: cc, effort: effort, entrypoint: entry, flags: flags)
}

/// `version` defaults to the format version the real scanner stamps, so rows a
/// test builds and rows a real scan writes compare like for like.
func hmWatermark(id: UInt64?, parsed: Int64, version: Int = hmParserVersion) -> HistoryFileWatermark {
    HistoryFileWatermark(fileID: id, volumeID: 1, size: parsed, modifiedAt: Double(parsed), parsedBytes: parsed,
                         boundaryDigest: Data([UInt8(truncatingIfNeeded: parsed), UInt8(truncatingIfNeeded: parsed >> 8)]),
                         parserVersion: version)
}

func hmFile(_ path: String, scan: UInt64 = 1, watermark: HistoryFileWatermark? = nil, _ observations: [RequestObservation],
            delta: (base: HistoryFileWatermark, requests: [RequestObservation])? = nil,
            events: HistoryFileEvents = .empty, version: Int = hmParserVersion) -> HistoryFileBatch {
    let wm = watermark ?? hmWatermark(id: hmStableID(path), parsed: Int64(observations.count + 1), version: version)
    let d = delta.map { HistoryFileBatch.Delta(basedOnParsedBytes: $0.base.parsedBytes, basedOnFileID: $0.base.fileID,
                                               basedOnBoundaryDigest: $0.base.boundaryDigest,
                                               basedOnParserVersion: $0.base.parserVersion, requests: $0.requests) }
    return HistoryFileBatch(path: path, scan: scan, watermark: wm, delta: d, allRequests: { observations }, events: events)
}

/// FNV-1a of the path: a file id that is the same in every process.
func hmStableID(_ path: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return h
}

func hmScan(_ ticket: UInt64 = 1, _ files: [HistoryFileBatch], complete: Bool = false, startedMs: Int64 = 1_000) -> HistoryScanBatch {
    HistoryScanBatch(ticket: ticket, startedMs: startedMs, isCompleteHistory: complete, files: files)
}

/// The accounting day of `ms` in `tz` with one uncached Foundation call: the
/// independent reference for `HistoryAccountingDays`.
func hmDay(_ ms: Int64?, _ tz: TimeZone) -> Int64? {
    guard let ms else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.year, .month, .day], from: HistoryTime.date(ms: ms))
    return Int64(c.year! * 10_000 + c.month! * 100 + c.day!)
}

/// Local midnight in `tz` as Unix ms.
func hmMidnight(_ tz: TimeZone, _ y: Int, _ m: Int, _ d: Int) -> Int64 {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return HistoryTime.ms(cal.date(from: DateComponents(year: y, month: m, day: d))!)
}

let hmTokyo = TimeZone(identifier: "Asia/Tokyo")!
let hmLosAngeles = TimeZone(identifier: "America/Los_Angeles")!

// MARK: - Store harness

/// Birth times by path, changeable between trials (the store reads it once per new path).
final class HMBirths: Sendable {
    private let map = OSAllocatedUnfairLock<[String: Int64]>(initialState: [:])
    func set(_ m: [String: Int64]) { map.withLock { $0 = m } }
    func set(_ path: String, _ ms: Int64?) { map.withLock { $0[path] = ms } }
    func get(_ path: String) -> Int64? { map.withLock { $0[path] } }
    var all: [String: Int64] { map.withLock { $0 } }
}

/// A settable clock.
final class HMClock: Sendable {
    private let now = OSAllocatedUnfairLock<Date>(initialState: Date(timeIntervalSince1970: 1_790_000_000))
    func get() -> Date { now.withLock { $0 } }
    func set(_ d: Date) { now.withLock { $0 = d } }
    func advance(_ seconds: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

func hmStore(_ dir: URL, timeZone: TimeZone = hmTokyo, clock: HMClock = HMClock(), births: HMBirths = HMBirths(),
             retention: HistoryRetention = HistoryRetention(),
             configure: @escaping @Sendable (inout HistoryDatabaseConfiguration) -> Void = { _ in }) -> HistoryStore {
    HistoryStore(directory: dir, retention: retention, clock: { clock.get() }, timeZone: timeZone) { config in
        config.birthTime = { births.get($0) }
        configure(&config)
    }
}

/// Deletes every logical row (children first) but keeps `meta`, so the next
/// schedule starts from an empty history without re-running maintenance.
func hmWipe(_ db: HistoryDatabase) throws {
    try db.conn.transaction(.immediate) {
        for table in ["request", "request_occurrence", "limit_event", "usage_report_limit", "usage_report_sample",
                      "cost_state_model", "cost_state_sample", "compact_event", "source_file", "session", "dict",
                      "ingest_scan", "quota_sample", "reset_event", "reset_grant_sample"] {
            try db.conn.exec("DELETE FROM \(table)")
        }
    }
}

/// `synchronous = OFF` on a TEST connection: thousands of schedules with
/// restarts would otherwise spend most of their time in fsync. The app keeps NORMAL.
func hmNoSync(_ db: HistoryDatabase) throws {
    try db.conn.setPragma("synchronous", "OFF")
}

/// A readable first difference of two dumps (for failure messages).
func hmDiff(_ a: HistoryLogicalDump, _ b: HistoryLogicalDump) -> String {
    let x = a.text.split(separator: "\n"), y = b.text.split(separator: "\n")
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? String(x[i]) : "<none>", r = i < y.count ? String(y[i]) : "<none>"
        if l != r { return "line \(i):\n  got  \(l)\n  want \(r)" }
    }
    return "equal"
}
