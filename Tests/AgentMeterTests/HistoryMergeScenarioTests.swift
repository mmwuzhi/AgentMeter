import Foundation
import XCTest
@testable import AgentMeter

/// The named merge cases. Each runs EVERY arrival order of its contributions
/// and must equal the closed form; then the values the case is about are
/// asserted explicitly.
final class HistoryMergeScenarioTests: XCTestCase {
    typealias Item = (path: String, obs: [RequestObservation], version: Int)

    /// Applies each item as its own whole-file scan (a fresh file identity, so
    /// even a repeated path applies), in order, on a fresh store.
    func ingest(_ items: [Item], births: [String: Int64] = [:], tz: TimeZone = hmTokyo) async throws -> HistoryLogicalDump {
        let b = HMBirths()
        b.set(births)
        let store = hmStore(historyTempDirectory("scenario"), timeZone: tz, births: b)
        try await store.withDatabase { try hmNoSync($0) }
        for (n, item) in items.enumerated() {
            let wm = hmWatermark(id: UInt64(1_000 + n), parsed: 10, version: item.version)
            try await store.applyScanCommand(hmScan(UInt64(n + 1), [hmFile(item.path, scan: UInt64(n + 1), watermark: wm, item.obs)]))
        }
        let dump = try await store.logicalDump()
        await store.close()
        return dump
    }

    @discardableResult
    func assertAllOrders(_ items: [Item], births: [String: Int64] = [:], tz: TimeZone = hmTokyo,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> HistoryLogicalDump {
        let want = HMOracle.dump(items.map { HMContribution(path: $0.path, version: $0.version, observations: $0.obs) },
                                 births: births, timeZone: tz)
        for order in permutations(Array(items.indices)) {
            let got = try await ingest(order.map { items[$0] }, births: births, tz: tz)
            XCTAssertEqual(got, want, "order \(order): \(hmDiff(got, want))", file: file, line: line)
        }
        return want
    }

    func permutations(_ a: [Int]) -> [[Int]] {
        guard a.count > 1 else { return [a] }
        return a.indices.flatMap { i -> [[Int]] in
            var rest = a
            let x = rest.remove(at: i)
            return permutations(rest).map { [x] + $0 }
        }
    }

    let k = hmKey(1)
    let a = "/p/proj/sA.jsonl"
    let b = "/p/proj/sB.jsonl"
    let c = "/p/proj/sA/subagents/agent-c1.jsonl"

    // MARK: Record rank

    func testPartialThenFinalInEitherOrder() async throws {
        let partial = hmObs(k, [hmPart(output: 3)], .partial, first: 10, last: 10)
        let final = hmObs(k, [hmPart(output: 9)], .final, first: 10, last: 12, final: 12)
        let dump = try await assertAllOrders([(a, [partial], 3), (a, [final], 3)])
        XCTAssertEqual(dump.requests.map(\.output), [9])
        XCTAssertEqual(dump.requests.first?.finality, 2)
        XCTAssertEqual(dump.requests.first?.finalMs, 12)
        XCTAssertEqual(dump.requests.first?.firstSeenMs, 10)
        XCTAssertEqual(dump.requests.first?.lastSeenMs, 12)
    }

    func testAZeroedReplayChangesNothingInTheSameFileOrAnother() async throws {
        let final = hmObs(k, [hmPart(output: 9)], .final, first: 10, last: 12, final: 10)
        let zeroed = hmObs(k, [hmPart(input: 0, output: 0)], .zeroed, first: 10, last: nil)
        let alone = try await ingest([(a, [final], 3)])
        try await assertAllOrders([(a, [final], 3), (a, [zeroed], 3)])
        // The other file holds only the replay; it is born first, but a NULL `last` never owns.
        let dump = try await assertAllOrders([(a, [final], 3), (b, [zeroed], 3)], births: [a: 200, b: 100])
        XCTAssertEqual(dump.requests.map(\.output), alone.requests.map(\.output))
        XCTAssertEqual(dump.requests.first?.ownerPath, a)
        XCTAssertEqual(dump.requests.first?.lastSeenMs, 12)
        XCTAssertEqual(dump.occurrences.count, 2)
    }

    func testABeatenTwoIterationRecordLeavesNoStaleRow() async throws {
        let twoParts = hmObs(k, [hmPart("fable", output: 1), hmPart("opus", output: 1)], .partial, first: 5, last: 5)
        let final = hmObs(k, [hmPart("opus", output: 5)], .final, first: 5, last: 6, final: 6)
        let dump = try await assertAllOrders([(a, [twoParts], 3), (b, [final], 3)])
        XCTAssertEqual(dump.requests.count, 1, "the partial's second iteration must not survive the final")
        XCTAssertEqual(dump.requests.first?.parts, 1)
    }

    func testAWinnerGrowingToTwoPartsInANonOwnerFileGetsTheOwnersDerivedValuesOnBothRows() async throws {
        let partial = hmObs(k, [hmPart("opus", output: 7)], .partial, first: 1_000, last: 1_100)
        let final = hmObs(k, [hmPart("fable", output: 188), hmPart("opus", output: 9_705)], .final,
                          first: 1_000, last: 1_200, final: 1_200)
        let dump = try await assertAllOrders([(a, [partial], 3), (b, [final], 3)], births: [a: 100, b: 200])
        XCTAssertEqual(dump.requests.map(\.idx), [0, 1])
        XCTAssertEqual(Set(dump.requests.map(\.ownerPath)), [a])
        XCTAssertEqual(Set(dump.requests.map(\.lastSeenMs)), [1_100])
        XCTAssertEqual(dump.requests.last?.thinking, nil)
    }

    func testEqualRankFinalsOfDifferentContentPickTheLargerSignatureInEveryOrder() async throws {
        // Never seen on the corpus; the DB's total order (rec_sig) differs from
        // UsageSelection's first-wins only here.
        let one = hmObs(k, [hmPart("opus", output: 100)], .final, first: 1, last: 1, final: 1)
        let two = hmObs(k, [hmPart("fable", output: 40), hmPart("opus", output: 60)], .final, first: 1, last: 1, final: 1)
        let dump = try await assertAllOrders([(a, [one], 3), (b, [two], 3)])
        let winner = HistoryRecordSignature.compute(one) > HistoryRecordSignature.compute(two) ? one : two
        XCTAssertEqual(dump.requests.count, winner.parts.count)
    }

    func testCopiesWithDifferentFinalTimesKeepTheEarliestFinal() async throws {
        let early = hmObs(k, [hmPart(output: 10)], .final, first: 1_000, last: 1_200, final: 1_200)
        let noTime = hmObs(k, [hmPart(output: 10)], .final, first: nil, last: nil, final: nil)
        let later = hmObs(k, [hmPart(output: 10)], .final, first: 1_000, last: 1_100, final: 1_100)
        let dump = try await assertAllOrders([(a, [early], 3), (b, [noTime], 3), (c, [later], 3)])
        XCTAssertEqual(dump.requests.first?.finalMs, 1_100, "smaller final_ms wins; NULL ranks as +inf")
    }

    // MARK: Owner

    func testOwnerIsTheEarliestBornThenTheSmallerPathThenANonNullBirth() async throws {
        let o = hmObs(k, [hmPart(output: 5)], .final, first: 10, last: 20, final: 10)
        let ob = hmObs(k, [hmPart(output: 5)], .final, first: 10, last: 30, final: 10)
        var dump = try await assertAllOrders([(a, [o], 3), (b, [ob], 3)], births: [a: 200, b: 100])
        XCTAssertEqual(dump.requests.first?.ownerPath, b, "by birth")
        XCTAssertEqual(dump.requests.first?.lastSeenMs, 30, "last_seen is the owner's")
        dump = try await assertAllOrders([(a, [o], 3), (b, [ob], 3)], births: [a: 100, b: 100])
        XCTAssertEqual(dump.requests.first?.ownerPath, a, "equal birth: the smaller path")
        dump = try await assertAllOrders([(a, [o], 3), (b, [ob], 3)], births: [b: 500])
        XCTAssertEqual(dump.requests.first?.ownerPath, b, "a NULL birth ranks last")
    }

    func testAZeroedOnlyOccurrenceNeverOwnsUnlessAllAre() async throws {
        let zeroed = hmObs(k, [hmPart(input: 0, output: 0)], .zeroed, first: 10, last: nil)
        let final = hmObs(k, [hmPart(output: 5)], .final, first: 10, last: 13, final: 10)
        var dump = try await assertAllOrders([(a, [zeroed], 3), (b, [final], 3)], births: [a: 1, b: 2])
        XCTAssertEqual(dump.requests.first?.ownerPath, b)
        dump = try await assertAllOrders([(a, [zeroed], 3), (b, [zeroed], 3)], births: [a: 2, b: 1])
        XCTAssertEqual(dump.requests.first?.ownerPath, b, "all zeroed: birth decides")
        XCTAssertNil(dump.requests.first?.lastSeenMs)
    }

    // MARK: Times

    func testFirstSeenIsANullAwareMinimum() async throws {
        let noTime = hmObs(k, [hmPart(output: 5)], .partial, first: nil, last: nil)
        let timed = hmObs(k, [hmPart(output: 5)], .partial, first: 5_000, last: 5_000)
        var dump = try await assertAllOrders([(a, [noTime], 3), (a, [timed], 3)])
        XCTAssertEqual(dump.requests.first?.firstSeenMs, 5_000, "scalar min(NULL, x) would keep NULL forever")
        XCTAssertNotNil(dump.requests.first?.acctDay)
        XCTAssertEqual(dump.occurrences.first?.firstMs, 5_000)
        dump = try await assertAllOrders([(a, [noTime], 3), (b, [timed], 3)])
        XCTAssertEqual(dump.requests.first?.firstSeenMs, 5_000)
    }

    func testAFinalAfterMidnightKeepsTheDayOfTheFirstRecord() async throws {
        let midnight = hmMidnight(hmTokyo, 2026, 9, 6)
        let partial = hmObs(k, [hmPart(output: 3)], .partial, first: midnight - 516, last: midnight - 516)
        let final = hmObs(k, [hmPart(output: 9)], .final, first: midnight - 516, last: midnight + 325, final: midnight + 325)
        let dump = try await assertAllOrders([(a, [partial], 3), (a, [final], 3)])
        XCTAssertEqual(dump.requests.first?.acctDay, 20_260_905)
        XCTAssertEqual(dump.requests.first?.finalMs, midnight + 325)
    }

    // MARK: Attributes and flags

    func testAttributesComeFromTheOwnerNotFromTheHashChosenCopy() async throws {
        let origin = hmObs(k, [hmPart(output: 50)], .final, first: 1_000, last: 1_000, final: 1_000, cc: "2.1.200",
                           effort: "high", entry: "cli")
        let fork = hmObs(k, [hmPart(output: 50)], .final, first: 1_000, last: 1_500, final: 1_000, cc: "2.1.205",
                         effort: nil, entry: "sdk-ts")
        let dump = try await assertAllOrders([(a, [origin], 3), (b, [fork], 3)], births: [a: 1, b: 2])
        XCTAssertEqual(dump.requests.first?.ccVersion, "2.1.200")
        XCTAssertEqual(dump.requests.first?.effort, "high")
        XCTAssertEqual(dump.requests.first?.entrypoint, "cli")
        XCTAssertEqual(dump.occurrences.map(\.ccVersion), ["2.1.200", "2.1.205"])
    }

    /// The flag is an OR over every record and every occurrence.
    func testFlagsAreAnOrOverRecordsAndOccurrences() async throws {
        var fold = HMFold()
        fold.add(HMRecord(key: k, finality: .partial, parts: [hmPart(output: 1)], flags: .abortedMidStream, ts: 1))
        fold.add(HMRecord(key: k, finality: .partial, parts: [hmPart(output: 2)], flags: .abortedMidStream, ts: 2))
        fold.add(HMRecord(key: k, finality: .final, parts: [hmPart(output: 3)], flags: [], ts: 3))
        let other = hmObs(k, [hmPart(output: 3)], .final, first: 3, last: 3, final: 3, flags: .fast)
        let dump = try await assertAllOrders([(a, fold.observations, 3), (b, [other], 3)])
        XCTAssertEqual(dump.requests.first?.flags, Int64(RequestFlags([.fast, .abortedMidStream]).rawValue))
    }

    // MARK: Versions and union semantics

    func testAHigherIngestVersionSupersedesAndALowerOneNeverDoes() async throws {
        let v3 = hmObs(k, [hmPart(output: 50)], .final, first: 10, last: 10, final: 10, cc: "old")
        let v4 = hmObs(k, [hmPart(output: 40)], .final, first: 10, last: 10, final: 10, cc: "new")
        let dump = try await assertAllOrders([(a, [v3], 3), (a, [v4], 4)])
        XCTAssertEqual(dump.requests.first?.output, 40, "a parser fix wins per key even with less output")
        XCTAssertEqual(dump.requests.first?.ingestVersion, 4)
        XCTAssertEqual(dump.occurrences.first?.ccVersion, "new")
    }

    /// A transcript rewritten in place keeps its earlier contribution: the
    /// dump equals ingesting old and new in any order, not the new one alone.
    func testAFileReplacedInPlaceKeepsItsEarlierContribution() async throws {
        let l = hmKey(2)
        let old = [hmObs(k, [hmPart(output: 9)], .final, first: 10, last: 10, final: 10),
                   hmObs(l, [hmPart(output: 3)], .final, first: 15, last: 15, final: 15)]
        let new = [hmObs(k, [hmPart(output: 3)], .partial, first: 20, last: 20)]
        let dump = try await assertAllOrders([(a, old, 3), (a, new, 3)])
        XCTAssertEqual(dump.requests.count, 2, "L stays")
        XCTAssertEqual(dump.requests.first { $0.keyHex == k.historyHex }?.output, 9)
        XCTAssertEqual(dump.occurrences.first { $0.keyHex == k.historyHex }.map { [$0.firstMs, $0.lastMs] }, [10, 20])
        let freshNew = try await ingest([(a, new, 3)])
        XCTAssertNotEqual(dump, freshNew, "union semantics: not a retraction")
    }

    /// A file rewritten in place whose old and new content state one key with
    /// an equal (version, finality, output): the occurrence's attributes (and,
    /// as the owner, the request's) come from the greater `att_sig`, never
    /// from whichever content arrived first. Labels only, and labels plus
    /// another input count (which `rec_sig` decides for the row itself).
    func testARewriteWithEqualRankKeepsTheSameAttributesInEveryOrder() async throws {
        let old = hmObs(k, [hmPart(input: 1, output: 5)], .final, first: 10, last: 10, final: 10, cc: "2.1.301",
                        effort: "high", entry: "cli")
        let relabeled = hmObs(k, [hmPart(input: 1, output: 5)], .final, first: 10, last: 10, final: 10, cc: "2.1.305",
                              effort: nil, entry: "cli")
        let recounted = hmObs(k, [hmPart(input: 2, output: 5)], .final, first: 10, last: 10, final: 10, cc: "2.1.302")
        for other in [relabeled, recounted] {
            let dump = try await assertAllOrders([(a, [old], 3), (a, [other], 3)])
            let winner = HistoryAttributeSignature.compute(old) > HistoryAttributeSignature.compute(other) ? old : other
            XCTAssertEqual(dump.occurrences.map(\.ccVersion), [winner.ccVersion])
            XCTAssertEqual(dump.occurrences.map(\.attSig), [HistoryAttributeSignature.compute(winner)])
            XCTAssertEqual(dump.requests.map(\.ccVersion), [winner.ccVersion], "the owner's attributes")
            XCTAssertEqual(dump.requests.map(\.effort), [winner.effort])
        }
        XCTAssertNotEqual(HistoryAttributeSignature.compute(old), HistoryAttributeSignature.compute(relabeled),
                          "labels are in att_sig")
        XCTAssertEqual(HistoryRecordSignature.compute(old), HistoryRecordSignature.compute(relabeled),
                       "and deliberately not in rec_sig")
    }

    /// Two contents of one file with an equal (version, finality, output)
    /// but another input count AND other labels: `rec_sig` picks the row's
    /// counts and `att_sig` the labels, and both pick the same content, so
    /// the row never shows one content's counts with the other's labels.
    /// Twelve label pairs, so a tie-break independent of `rec_sig` (which
    /// mixes about half of them) cannot pass by chance.
    func testBetweenContentsWithOtherCountsTheLabelsFollowTheRowsCounts() async throws {
        for x in 0..<12 {
            let one = hmObs(k, [hmPart(input: 1, output: 5)], .final, first: 10, last: 10, final: 10, cc: "2.1.30\(x)")
            let two = hmObs(k, [hmPart(input: 2, output: 5)], .final, first: 10, last: 10, final: 10, cc: "2.1.31\(x)")
            let dump = try await assertAllOrders([(a, [one], 3), (a, [two], 3)])
            let row = try XCTUnwrap(dump.requests.first)
            let counted = row.input == 1 ? one : two
            XCTAssertEqual(row.ccVersion, counted.ccVersion, "pair \(x): input \(row.input) with version \(row.ccVersion ?? "nil")")
            XCTAssertEqual(dump.occurrences.map(\.ccVersion), [counted.ccVersion], "pair \(x)")
        }
    }

    /// The same through the real scanner and usage cache: a transcript
    /// rewritten in place with the same counts and another `version`. Two
    /// instances see the two contents in opposite orders; the set of
    /// contributions is the same, so the dumps must be.
    func testATranscriptRewrittenInPlaceWithAnotherVersionGivesOneDumpInBothOrders() async throws {
        let tree = try e2eTree()
        let main = tree.main()
        let first = [E2EFix.rec(1, E2EFix.t0, out: 5, version: "2.1.301")]
        let second = [E2EFix.rec(1, E2EFix.t0, out: 5, version: "2.1.305")]
        try tree.write(first, to: main)
        let forward = E2ELane(tree: tree, name: "forward")
        await forward.scan()
        try tree.rewriteInPlace(second, at: main)
        await forward.scan()
        let d1 = try await forward.dump()
        await forward.close()
        let backward = E2ELane(tree: tree, name: "backward")     // the tree holds `second` now
        await backward.scan()
        try tree.rewriteInPlace(first, at: main)
        await backward.scan()
        let d2 = try await backward.dump()
        await backward.close()
        XCTAssertEqual(d1.occurrences.count, 1)
        XCTAssertEqual(d1.sha256Hex, d2.sha256Hex, hmDiff(d1, d2))
    }
}
