import Foundation
import XCTest
@testable import AgentMeter

/// What the store refuses or normalises before a transaction: times at or
/// beyond `HistoryTime.maxMagnitudeMs` (skipped, never trapped on), model
/// names that are not a printable label (kept, under a sentinel, with their
/// counts), over-long event texts and working directories.
final class HistoryValidationTests: XCTestCase {
    let path = "/p/proj/sA.jsonl"
    let t0: Int64 = 1_790_000_000_000
    let huge = Int64.max - 1
    let hugeNegative = -Int64.max

    func ingest(_ obs: [RequestObservation], events: HistoryFileEvents = .empty, into store: HistoryStore) async throws {
        try await store.applyScanCommand(hmScan(1, [hmFile(path, scan: 1, watermark: hmWatermark(id: 7, parsed: 10), obs,
                                                           events: events)]))
    }

    func limit(_ uuid: String, ts: Int64, resetsAt: Int64?) -> LimitEventObservation {
        LimitEventObservation(uuid: uuid, requestID: nil, tsMs: ts, windowID: "five_hour", status: "rejected",
                              resetsAtMs: resetsAt, overageStatus: nil, overageDisabledReason: nil, isUsingOverage: nil,
                              fallbackAvailable: nil, source: "quotaLimits", apiError: nil, ccVersion: nil)
    }

    func quota(at reading: Int64, recorded: Int64? = nil, resetsAt: Int64? = nil) -> QuotaSampleRow {
        QuotaSampleRow(provider: .claude, windowID: "five_hour", source: .oauth, readingMs: reading, fetchedMs: reading,
                       cachedMs: nil, recordedMs: recorded ?? reading, usedPercent: 10, resetsAtMs: resetsAt,
                       cycleSeconds: nil, isModelScoped: nil, isOneTimeCredit: nil, isActive: nil, severity: nil,
                       lockedReason: nil, scopeName: nil, shareUsedOfWeekly: nil, shareAllowanceOfWeekly: nil,
                       plan: nil, tier: nil, flags: [])
    }

    // MARK: Times

    /// `(ms + 30_000)` of the epoch rounding would trap near Int64.max, so a
    /// time at or beyond 10^15 ms never reaches it: the observation, event or
    /// quota row is skipped and counted.
    func testTimesAtOrBeyondTheBoundAreSkippedAndCountedNeverTrappedOn() async throws {
        let edge = HistoryTime.maxMagnitudeMs
        XCTAssertEqual(edge, 1_000_000_000_000_000)
        XCTAssertNil(HistoryEpoch.seconds(ms: huge))
        XCTAssertNil(HistoryEpoch.seconds(ms: hugeNegative))
        XCTAssertNil(quota(at: t0, resetsAt: huge).resetEpochSeconds)
        XCTAssertEqual(HistoryEpoch.seconds(ms: edge - 1), (edge - 1 + 30_000) / 60_000 * 60)

        let store = hmStore(historyTempDirectory())
        let obs = [
            hmObs(hmKey(1), [hmPart(output: 1)], .final, first: huge, last: huge, final: huge),
            hmObs(hmKey(2), [hmPart(output: 1)], .partial, first: hugeNegative, last: t0),
            hmObs(hmKey(3), [hmPart(output: 1)], .final, first: t0, last: t0, final: edge),
            hmObs(hmKey(4), [hmPart(output: 1)], .final, first: t0, last: edge - 1, final: edge - 1),
        ]
        let report = UsageReportObservation(
            uuid: "r1", tsMs: t0, ccVersion: nil, hasLimits: true, extraEnabled: nil, extraMonthlyLimit: nil,
            extraUsedCredits: nil, limits: [UsageReportLimit(index: 0, kind: "session", group: nil, percent: 1, severity: nil,
                                                             isActive: nil, resetsAtMs: huge, scopeModel: nil)])
        let cost = CostStateObservation(sessionID: "sA", startTimeMs: hugeNegative, totalDurationMs: 1, totalAPIDurationMs: nil,
                                        totalCostUSD: 1, hasUnknownModelCost: false, afterTsMs: nil, models: [])
        let compact = CompactEventObservation(uuid: "c1", tsMs: huge, trigger: "auto", preTokens: nil, postTokens: nil)
        let events = HistoryFileEvents(
            limitEvents: [limit("u1", ts: t0, resetsAt: huge), limit("u2", ts: hugeNegative, resetsAt: t0),
                          limit("u3", ts: t0, resetsAt: t0 + 3_600_000)],
            usageReports: [report], costStates: [cost], compactEvents: [compact],
            firstCwd: "/w", firstCwdMs: huge, firstEntrypoint: nil, firstCcVersion: nil)
        try await ingest(obs, events: events, into: store)
        let dump = try await store.logicalDump()
        XCTAssertEqual(dump.requests.map(\.keyHex), [hmKey(4).historyHex], "only the key whose times are all below 10^15 ms")
        XCTAssertEqual(dump.events.filter { $0.hasPrefix("L|") }.count, 1)
        XCTAssertEqual(dump.events.filter { !$0.hasPrefix("L|") }, [])
        XCTAssertNil(dump.sessions.first?.firstCwd)
        var stats = await store.statistics()
        XCTAssertEqual(stats.skippedInvalidObservations, 3)
        XCTAssertEqual(stats.skippedInvalidEvents, 6, "two limits, the report, the cost state, the compaction, the first cwd")
        XCTAssertEqual(stats.failedChunks, 0)

        try await store.applyQuotaCommand([quota(at: t0, resetsAt: huge), quota(at: hugeNegative),
                                           quota(at: t0 + 1, recorded: huge), quota(at: t0 + 2, resetsAt: t0 + 3_600_000)])
        stats = await store.statistics()
        XCTAssertEqual(stats.skippedInvalidEvents, 6 + 3)
        let readings = try await store.withDatabase { try $0.conn.queryTexts("SELECT reading_ms FROM quota_sample") }
        XCTAssertEqual(readings, ["\(t0 + 2)"])
        await store.close()
    }

    // MARK: Model names

    /// The scanner takes `message.model` unchecked. A name that is not 1-128
    /// printable ASCII bytes must not cost the observation (the usage report
    /// counts its tokens): its parts are stored under the sentinel model.
    func testAnUnusableModelNameKeepsItsTokensUnderTheSentinel() async throws {
        let store = hmStore(historyTempDirectory())
        let longest = String(repeating: "m", count: 128)
        let names = [String(repeating: "m", count: 129), String(repeating: "x", count: 70_000), "claude\u{7}opus",
                     "claude-\u{4E2D}", "", "claude\nopus"]
        var obs = names.enumerated().map { n, name in
            hmObs(hmKey(n), [hmPart(name, input: 3, output: 7 + n, cacheRead: 11)], .final, first: t0, last: t0, final: t0)
        }
        obs.append(hmObs(hmKey(50), [hmPart(longest, output: 2)], .final, first: t0, last: t0, final: t0))
        obs.append(hmObs(hmKey(51), [hmPart("claude-opus", output: 1), hmPart(names[0], output: 4)], .final,
                         first: t0, last: t0, final: t0))
        try await ingest(obs, into: store)
        let dump = try await store.logicalDump()
        let stats = await store.statistics()
        XCTAssertEqual(stats.skippedInvalidObservations, 0, "no observation is lost for its model name")
        XCTAssertEqual(dump.requests.count, names.count + 3)
        for (n, _) in names.enumerated() {
            let row = dump.requests.first { $0.keyHex == hmKey(n).historyHex }
            XCTAssertEqual(row?.model, HistoryObservationCheck.unrecognizedModel, "name \(n)")
            XCTAssertEqual(row.map { [$0.input, $0.output, $0.cacheRead] }, [3, Int64(7 + n), 11], "name \(n): counts intact")
        }
        XCTAssertEqual(dump.requests.first { $0.keyHex == hmKey(50).historyHex }?.model, longest)
        XCTAssertEqual(dump.requests.filter { $0.keyHex == hmKey(51).historyHex }.map(\.model),
                       ["claude-opus", HistoryObservationCheck.unrecognizedModel], "per part")
        let models = try await store.withDatabase { try $0.conn.queryTexts("SELECT value FROM dict WHERE kind = 1 ORDER BY value") }
        XCTAssertEqual(models, [HistoryObservationCheck.unrecognizedModel, "claude-opus", longest])
        // The sentinel is what the signature sees, so two unusable names tie as one model.
        XCTAssertEqual(HistoryObservationCheck.normalized(obs[0])?.parts.map(\.model), [HistoryObservationCheck.unrecognizedModel])
        await store.close()
    }

    // MARK: Event texts and the first cwd

    /// The store's text bound on every event string (1,024 bytes) and the
    /// first cwd's own bound (4,096 bytes, the scanner's `cwd()` bound): one
    /// byte over drops that event (counted), at the bound it is kept.
    func testEventTextsAndTheFirstCwdAreBoundedAtTheirLimits() async throws {
        let maxText = HistoryEventCheck.maxText
        XCTAssertEqual(maxText, 1_024)
        XCTAssertEqual(HistoryEventCheck.maxCwdBytes, 4_096)
        let store = hmStore(historyTempDirectory())
        let events = HistoryFileEvents(
            limitEvents: [limit(String(repeating: "u", count: maxText), ts: t0, resetsAt: nil),
                          limit(String(repeating: "v", count: maxText + 1), ts: t0, resetsAt: nil)],
            compactEvents: [CompactEventObservation(uuid: "c1", tsMs: t0, trigger: String(repeating: "t", count: maxText + 1),
                                                    preTokens: nil, postTokens: nil)])
        try await ingest([], events: events, into: store)
        var dump = try await store.logicalDump()
        XCTAssertEqual(dump.events.count, 1)
        XCTAssertTrue(dump.events[0].contains(String(repeating: "u", count: maxText)))
        var stats = await store.statistics()
        XCTAssertEqual(stats.skippedInvalidEvents, 2)

        for (n, length) in [4_097, 4_096].enumerated() {
            let cwd = "/" + String(repeating: "d", count: length - 1)
            let file = HistoryFileEvents(firstCwd: cwd, firstCwdMs: t0 - Int64(n), firstEntrypoint: "cli", firstCcVersion: "2.1.1")
            try await store.applyScanCommand(hmScan(UInt64(2 + n), [hmFile(path, scan: UInt64(2 + n),
                                                                           watermark: hmWatermark(id: 7, parsed: Int64(20 + n)),
                                                                           [], events: file)]))
            dump = try await store.logicalDump()
            stats = await store.statistics()
            if length == 4_097 {
                XCTAssertNil(dump.sessions.first?.firstCwd, "one byte over the scanner's bound")
                XCTAssertEqual(stats.skippedInvalidEvents, 3)
            } else {
                XCTAssertEqual(dump.sessions.first?.firstCwd?.utf8.count, 4_096, "every cwd the scanner keeps")
                XCTAssertEqual(dump.sessions.first?.entrypoint, "cli")
                XCTAssertEqual(stats.skippedInvalidEvents, 3)
            }
        }
        await store.close()
    }
}
