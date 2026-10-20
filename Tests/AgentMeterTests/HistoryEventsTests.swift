import Foundation
import XCTest
@testable import AgentMeter

/// The whole-file extras: 429 limit events, /usage reports, cost states,
/// compactions, and the session's first cwd.
final class HistoryEventsTests: XCTestCase {
    let main = "/p/proj/sA.jsonl"
    let fork = "/p/proj/sB.jsonl"
    let agent = "/p/proj/sA/subagents/agent-q.jsonl"

    func limit(_ uuid: String, request: String?, ts: Int64 = 5_000, resetsAt: Int64? = 1_790_000_099_979,
               cc: String? = "2.1.300") -> LimitEventObservation {
        LimitEventObservation(uuid: uuid, requestID: request, tsMs: ts, windowID: "five_hour", status: "rejected",
                              resetsAtMs: resetsAt, overageStatus: "rejected", overageDisabledReason: "org_level_disabled",
                              isUsingOverage: false, fallbackAvailable: nil, source: "quotaLimits", apiError: "rate_limit",
                              ccVersion: cc)
    }

    func report(_ uuid: String, ts: Int64 = 9_000) -> UsageReportObservation {
        UsageReportObservation(uuid: uuid, tsMs: ts, ccVersion: "2.1.301", hasLimits: true, extraEnabled: true,
                               extraMonthlyLimit: 5_000, extraUsedCredits: 12, limits: [
                                   UsageReportLimit(index: 0, kind: "session", group: "a", percent: 41.5, severity: "normal",
                                                    isActive: true, resetsAtMs: 1_790_000_030_000, scopeModel: nil),
                                   UsageReportLimit(index: 1, kind: "weekly_scoped", group: nil, percent: 7, severity: nil,
                                                    isActive: nil, resetsAtMs: nil, scopeModel: " Fable "),
                                   UsageReportLimit(index: 2, kind: "mystery", group: nil, percent: 1, severity: nil,
                                                    isActive: nil, resetsAtMs: nil, scopeModel: nil),
                               ])
    }

    func cost(session: String = "sA", start: Int64 = 100, duration: Int64 = 50) -> CostStateObservation {
        CostStateObservation(sessionID: session, startTimeMs: start, totalDurationMs: duration, totalAPIDurationMs: 40,
                             totalCostUSD: 1.25, hasUnknownModelCost: false, afterTsMs: 4_000,
                             models: [CostStateModel(modelKey: "claude-opus[1m]", input: 1, output: 2, cacheRead: 3,
                                                     cacheCreation: 4, thinking: 5, webSearch: 0, costUSD: 1.25)])
    }

    func events(limits: [LimitEventObservation] = [], reports: [UsageReportObservation] = [],
                costs: [CostStateObservation] = [], compacts: [CompactEventObservation] = [],
                cwd: String? = nil, cwdMs: Int64? = nil, entry: String? = nil, cc: String? = nil) -> HistoryFileEvents {
        HistoryFileEvents(limitEvents: limits, usageReports: reports, costStates: costs, compactEvents: compacts,
                          firstCwd: cwd, firstCwdMs: cwdMs, firstEntrypoint: entry, firstCcVersion: cc)
    }

    /// Each (path, events) as its own scan with a fresh identity, so every one applies.
    func ingest(_ items: [(String, HistoryFileEvents)], into store: HistoryStore? = nil, births: [String: Int64] = [:],
                mutations: HistoryMergeMutations = []) async throws -> HistoryLogicalDump {
        let b = HMBirths()
        b.set(births)
        let s = store ?? hmStore(historyTempDirectory("events"), births: b) { $0.mergeMutations = mutations }
        for (n, (path, ev)) in items.enumerated() {
            let wm = hmWatermark(id: UInt64(500 + n), parsed: 10)
            try await s.applyScanCommand(hmScan(UInt64(n + 1), [hmFile(path, scan: UInt64(n + 1), watermark: wm, [], events: ev)]))
        }
        return try await s.logicalDump()
    }

    func testLimitEventsAreKeyedByRequestIDSoReplaysAndForkCopiesLandOnce() async throws {
        let original = events(limits: [limit("u1", request: "req_1"), limit("u2", request: nil)])
        let replayed = events(limits: [limit("u1", request: "req_1"), limit("u1", request: "req_1"), limit("u2", request: nil)])
        let forked = events(limits: [limit("u9", request: "req_1")])
        let dump = try await ingest([(main, original), (main, replayed), (fork, forked)])
        let lines = dump.events.filter { $0.hasPrefix("L|") }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains { $0.hasPrefix("L|\"req_1\"|\"u1\"|") }, "the fork's new uuid did not add a row")
        XCTAssertTrue(lines.contains { $0.hasPrefix("L|\"uuid:u2\"|") }, "no request id: keyed by uuid")
        XCTAssertEqual(HistoryEpoch.seconds(ms: 1_790_000_099_979), 1_790_000_100, "59.979 s past the minute rounds to the NEAREST minute")
        XCTAssertTrue(lines.contains { $0.contains("|1790000099979|1790000100|") })
    }

    /// Copies of one event in several files (a fork re-stamps uuids) belong
    /// to the file that ranks first by (birth IS NULL, birth, path): the same
    /// row whichever copy arrives first. Returns both orders' dumps.
    func bothOrders(_ a: (String, HistoryFileEvents), _ b: (String, HistoryFileEvents), births: [String: Int64],
                    mutations: HistoryMergeMutations = [], file: StaticString = #filePath, line: UInt = #line)
        async throws -> (HistoryLogicalDump, HistoryLogicalDump) {
        let ab = try await ingest([a, b], births: births, mutations: mutations)
        let ba = try await ingest([b, a], births: births, mutations: mutations)
        if mutations.isEmpty { XCTAssertEqual(ab, ba, hmDiff(ab, ba), file: file, line: line) }
        return (ab, ba)
    }

    func testAForkCopiedLimitEventBelongsToTheEarliestBornFileInEitherOrder() async throws {
        let (dump, _) = try await bothOrders((main, events(limits: [limit("u1", request: "req_1", cc: "2.1.300")])),
                                             (fork, events(limits: [limit("u9", request: "req_1", cc: "2.1.305")])),
                                             births: [main: 200, fork: 100])
        let lines = dump.events.filter { $0.hasPrefix("L|") }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("L|\"req_1\"|\"u9\"|\"req_1\"|\"sB\"|"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("|\"2.1.305\"|\"\(fork)\""), "the owner's own copy, and its path: \(lines[0])")
        // Equal birth: the smaller path owns; a NULL birth ranks last.
        let (tie, _) = try await bothOrders((main, events(limits: [limit("u1", request: "req_1")])),
                                            (fork, events(limits: [limit("u9", request: "req_1")])), births: [main: 5, fork: 5])
        XCTAssertTrue(tie.events[0].hasSuffix("\"\(main)\""))
        let (nullBirth, _) = try await bothOrders((main, events(limits: [limit("u1", request: "req_1")])),
                                                  (fork, events(limits: [limit("u9", request: "req_1")])), births: [fork: 900])
        XCTAssertTrue(nullBirth.events[0].hasSuffix("\"\(fork)\""))
    }

    func testAForkCopiedUsageReportAndItsLimitsBelongToTheOwnerInEitherOrder() async throws {
        let (dump, _) = try await bothOrders((main, events(reports: [report("r1")])), (fork, events(reports: [report("r9")])),
                                             births: [main: 200, fork: 100])
        let samples = dump.events.filter { $0.hasPrefix("U|") }
        XCTAssertEqual(samples.count, 1)
        XCTAssertTrue(samples[0].contains("|\"r9\"|\"sB\"|") && samples[0].hasSuffix("\"\(fork)\""), samples[0])
        XCTAssertEqual(dump.events.filter { $0.hasPrefix("UL|") }.count, 2, "the winning report's limits, once")
    }

    func testAForkCopiedCompactionIsKeyedByItsContentNotItsUuid() async throws {
        let original = CompactEventObservation(uuid: "c1", tsMs: 7_000, trigger: "auto", preTokens: 150_000, postTokens: 9_000)
        let copy = CompactEventObservation(uuid: "c9", tsMs: 7_000, trigger: "auto", preTokens: 150_000, postTokens: 9_000)
        let (dump, _) = try await bothOrders((main, events(compacts: [original])), (fork, events(compacts: [copy])),
                                             births: [main: 100, fork: 200])
        XCTAssertEqual(dump.events.filter { $0.hasPrefix("X|") },
                       ["X|\"7000|auto|150000|9000\"|\"sA\"|7000|\"auto\"|150000|9000|\"\(main)\""])
        XCTAssertEqual(HistoryEventCheck.compactKey(CompactEventObservation(uuid: "x", tsMs: 1, trigger: nil, preTokens: nil,
                                                                            postTokens: 3)), "1|||3")
    }

    func testCopiedCostStatesMergeTheirAfterTimeAsAMaximum() async throws {
        let late = CostStateObservation(sessionID: "sA", startTimeMs: 100, totalDurationMs: 50, totalAPIDurationMs: 40,
                                        totalCostUSD: 1.25, hasUnknownModelCost: false, afterTsMs: 9_000, models: cost().models)
        let none = CostStateObservation(sessionID: "sA", startTimeMs: 100, totalDurationMs: 50, totalAPIDurationMs: 40,
                                    totalCostUSD: 1.25, hasUnknownModelCost: false, afterTsMs: nil, models: cost().models)
        let (dump, _) = try await bothOrders((main, events(costs: [cost()])), (fork, events(costs: [late])),
                                             births: [main: 100, fork: 200])
        XCTAssertEqual(dump.events.filter { $0.hasPrefix("C|") }.count, 1)
        XCTAssertTrue(dump.events.contains { $0.hasPrefix("C|\"sA\"|100|50|") && $0.hasSuffix("|9000") })
        XCTAssertEqual(dump.events.filter { $0.hasPrefix("CM|") }.count, 1)
        let (withNull, _) = try await bothOrders((main, events(costs: [none])), (fork, events(costs: [cost()])),
                                                 births: [main: 100, fork: 200])
        XCTAssertTrue(withNull.events.contains { $0.hasPrefix("C|") && $0.hasSuffix("|4000") }, "a NULL never wins the MAX")
    }

    /// Negative control: a first-arrival `DO NOTHING` is order-dependent.
    func testFirstArrivalWouldMakeForkCopiesOrderDependent() async throws {
        let (ab, ba) = try await bothOrders((main, events(limits: [limit("u1", request: "req_1")])),
                                            (fork, events(limits: [limit("u9", request: "req_1")])),
                                            births: [main: 200, fork: 100], mutations: .firstArrivalEvents)
        XCTAssertNotEqual(ab.events, ba.events)
    }

    func testUsageReportsAreKeyedByTimeAndLimitsAndSkipUnknownWindows() async throws {
        let dump = try await ingest([(main, events(reports: [report("r1")])), (fork, events(reports: [report("r2")])),
                                     (main, events(reports: [report("r1"), report("r3", ts: 9_500)]))])
        let samples = dump.events.filter { $0.hasPrefix("U|") }
        XCTAssertEqual(samples.count, 2, "the fork copy (new uuid, same time and limits) lands once")
        let key = HistoryEventCheck.reportKey(report("r1"))
        XCTAssertTrue(key.hasPrefix("9000|") && key.count == "9000|".count + 8, key)
        let limits = dump.events.filter { $0.hasPrefix("UL|\"\(key)\"") }
        XCTAssertEqual(limits.count, 2, "the unknown kind has no window id and is skipped")
        XCTAssertTrue(limits.contains { $0.contains("|\"five_hour\"|") })
        XCTAssertTrue(limits.contains { $0.contains("|\"seven_day_fable\"|") })
    }

    func testCostStatesUseTheRecordsSessionAndReplayedCompactionsLandOnce() async throws {
        let compact = CompactEventObservation(uuid: "c1", tsMs: 7_000, trigger: "auto", preTokens: 150_000, postTokens: 9_000)
        let dump = try await ingest([(main, events(costs: [cost(session: "sResumed")], compacts: [compact, compact])),
                                     (main, events(costs: [cost(session: "sResumed"), cost(start: 200)], compacts: [compact]))])
        XCTAssertEqual(dump.events.filter { $0.hasPrefix("C|") }.count, 2)
        XCTAssertTrue(dump.events.contains { $0.hasPrefix("C|\"sResumed\"|100|50|") })
        XCTAssertEqual(dump.events.filter { $0.hasPrefix("CM|") }.count, 2)
        XCTAssertEqual(dump.events.filter { $0.hasPrefix("X|") },
                       ["X|\"7000|auto|150000|9000\"|\"sA\"|7000|\"auto\"|150000|9000|\"\(main)\""])
        XCTAssertEqual(Set(dump.sessions.map(\.sessionID)), ["sA", "sResumed"])
    }

    func testTheFirstCwdIsTheEarliestOfMainFilesWithTiesOnTheSmallerCwd() async throws {
        let late = events(cwd: "/work/late", cwdMs: 900, entry: "cli", cc: "2.1.1")
        let early = events(cwd: "/work/zz", cwdMs: 100, entry: "sdk", cc: "2.1.0")
        let tie = events(cwd: "/work/aa", cwdMs: 100, entry: "cli", cc: "2.1.2")
        let fromAgent = events(cwd: "/worktree/agent", cwdMs: 1)
        let noTime = events(cwd: "/a", cwdMs: nil)
        var dumps: [HistoryLogicalDump] = []
        for order in [[0, 1, 2, 3, 4], [4, 3, 2, 1, 0], [2, 0, 4, 1, 3]] {
            let items: [(String, HistoryFileEvents)] = [(main, late), (main, early), (main, tie), (agent, fromAgent), (main, noTime)]
            dumps.append(try await ingest(order.map { items[$0] }))
        }
        XCTAssertEqual(dumps[0], dumps[1])
        XCTAssertEqual(dumps[0], dumps[2])
        let session = dumps[0].sessions.first { $0.sessionID == "sA" }
        XCTAssertEqual(session?.firstCwd, "/work/aa", "earliest time, then the smaller cwd; an agent file's cwd never counts")
        XCTAssertEqual(session?.firstCwdMs, 100)
        XCTAssertEqual(session?.entrypoint, "cli")
        XCTAssertEqual(session?.ccVersion, "2.1.2")
    }

    func testInvalidEventsAreDroppedAndCountedNotTheFile() async throws {
        let store = hmStore(historyTempDirectory())
        let badReport = UsageReportObservation(uuid: "r1", tsMs: 1, ccVersion: nil, hasLimits: true, extraEnabled: nil,
                                           extraMonthlyLimit: nil, extraUsedCredits: nil,
                                           limits: [UsageReportLimit(index: 0, kind: "session", group: nil, percent: .nan,
                                                                     severity: nil, isActive: nil, resetsAtMs: nil, scopeModel: nil)])
        let badCost = CostStateObservation(sessionID: "sA", startTimeMs: 1, totalDurationMs: 1, totalAPIDurationMs: nil,
                                       totalCostUSD: .infinity, hasUnknownModelCost: false, afterTsMs: nil, models: [])
        let dump = try await ingest([(main, events(limits: [limit("u1", request: "r")], reports: [badReport], costs: [badCost]))],
                                    into: store)
        XCTAssertEqual(dump.events.count, 1)
        let stats = await store.statistics()
        XCTAssertEqual(stats.skippedInvalidEvents, 2)
        XCTAssertEqual(stats.failedChunks, 0)
    }
}
