import Foundation
@testable import AgentMeter
import XCTest

/// What a parse records beside the counted record of each key: the times
/// and flags of every record of the key in the file (`RecordStamp`), the
/// standing record's attributes, and the file's extras. None of it may
/// change which record counts.
final class ClaudeUsageStampTests: XCTestCase {
    private typealias F = TranscriptFixture
    private let t0 = F.base

    private func entry(_ usage: ClaudeFileUsage, _ mid: String, _ rid: String) throws -> KeyedUsage {
        let key = DedupKey(messageID: mid, requestID: rid)
        return try XCTUnwrap(usage.keyed.first { $0.key == key })
    }

    private func attributes(_ usage: ClaudeFileUsage, _ record: KeyedUsage) -> RecordAttributes {
        record.stamp.attributes == 0 ? RecordAttributes() : usage.attributeSets[Int(record.stamp.attributes) - 1]
    }

    // MARK: - The stamp of one key

    func testOwnStampOfASingleRecord() throws {
        let usage = F.parse([
            F.assistant(uuid: "u1", ts: F.iso24(t0 + 123), mid: "msg_1", rid: "req_1", stop: "end_turn",
                        version: "2.1.301", effort: "xhigh", entrypoint: "claude-vscode", thinking: 321, speed: "fast"),
        ])
        let record = try entry(usage, "msg_1", "req_1")
        XCTAssertEqual(record.stamp.first, t0 + 123)
        XCTAssertEqual(record.stamp.lastMs, t0 + 123)
        XCTAssertEqual(record.stamp.finalMs, t0 + 123)
        XCTAssertEqual(record.stamp.thinking, 321)
        XCTAssertEqual(record.stamp.flags, .fast)
        XCTAssertEqual(attributes(usage, record), RecordAttributes(version: "2.1.301", effort: "xhigh", entrypoint: "claude-vscode"))
        let observation = usage.observation(at: 0)
        XCTAssertEqual(observation.firstMs, t0 + 123)
        XCTAssertEqual(observation.finalMs, t0 + 123)
        XCTAssertEqual(observation.thinkingTokens, 321)
        XCTAssertEqual(observation.ccVersion, "2.1.301")
        XCTAssertEqual(observation.effort, "xhigh")
        XCTAssertEqual(observation.entrypoint, "claude-vscode")
        XCTAssertEqual(observation.parts.map(\.model), ["claude-opus-5-5"])
    }

    /// Records that do not stand give their times, never their attributes:
    /// a same-file replay under a newer CLI keeps the request's own version.
    func testNonWinningRecordsFoldOnlyTheirTimes() throws {
        let usage = F.parse([
            F.assistant(uuid: "u1", ts: F.iso24(t0 + 1_000), mid: "msg_1", rid: "req_1",
                        counts: .init(output: 3), version: "2.1.290", effort: "low"),
            F.assistant(uuid: "u2", ts: F.iso24(t0 + 5_000), mid: "msg_1", rid: "req_1", stop: "tool_use",
                        counts: .init(output: 700), version: "2.1.291", effort: "high", thinking: 40),
            // A same-file replay of the final record, appended later by a newer CLI.
            F.assistant(uuid: "u3", ts: F.iso24(t0 + 5_000), mid: "msg_1", rid: "req_1", stop: "tool_use",
                        counts: .init(output: 700), version: "2.1.301", effort: "max", thinking: 40),
            // A zeroed replay carries the original's timestamp... or a later one.
            F.assistant(uuid: "u4", ts: F.iso24(t0 + 90_000), mid: "msg_1", rid: "req_1", stop: "tool_use",
                        counts: .init(output: 700), zeroed: true, version: "2.1.301"),
        ])
        let record = try entry(usage, "msg_1", "req_1")
        XCTAssertEqual(record.finality, .final)
        XCTAssertEqual(record.usage.counts.output, 700)
        XCTAssertEqual(attributes(usage, record).version, "2.1.291")
        XCTAssertEqual(attributes(usage, record).effort, "high")
        XCTAssertEqual(record.stamp.first, t0 + 1_000)
        XCTAssertEqual(record.stamp.lastMs, t0 + 5_000, "a zeroed replay never raises the last time")
        XCTAssertEqual(record.stamp.finalMs, t0 + 5_000)
        XCTAssertEqual(usage.attributeSets.count, 2, "replays that did not stand never enter the table")
    }

    /// A sidechain partial before midnight and its final the next day. The request keeps day D and its
    /// first time; the final time is the final record's own.
    func testReplacingFoldsTheHeldPartialsTime() throws {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date().addingTimeInterval(-3 * 86_400))
        let partialMs = HistoryTime.ms(midnight) - 250
        let finalMs = HistoryTime.ms(midnight) + 500
        let lines = [
            F.assistant(uuid: "u1", ts: F.iso24(partialMs), mid: "msg_m", rid: "req_m", counts: .init(output: 4), sidechain: true),
            F.assistant(uuid: "u2", ts: F.iso24(finalMs), mid: "msg_m", rid: "req_m", stop: "tool_use",
                        counts: .init(output: 700), sidechain: true),
        ]
        let whole = F.parse(lines)
        let resumed = F.parse(Array(lines.dropFirst()), resuming: F.parse(Array(lines.prefix(1))))
        XCTAssertEqual(resumed, whole, "the same across the boundary between the two")
        let record = try entry(whole, "msg_m", "req_m")
        let dayD = cal.startOfDay(for: HistoryTime.date(ms: partialMs))
        XCTAssertEqual(record.usage.day, dayD)
        XCTAssertEqual(record.stamp.first, partialMs)
        XCTAssertEqual(record.stamp.lastMs, finalMs)
        XCTAssertEqual(record.stamp.finalMs, finalMs)
        XCTAssertEqual(cal.startOfDay(for: HistoryTime.date(ms: try XCTUnwrap(record.stamp.first))), record.usage.day)

        // Held zeroed: the winner keeps its own day, the times still fold.
        let zeroedFirst = F.parse([
            F.assistant(uuid: "u3", ts: F.iso24(partialMs), mid: "msg_z", rid: "req_z", stop: "end_turn", zeroed: true),
            F.assistant(uuid: "u4", ts: F.iso24(finalMs), mid: "msg_z", rid: "req_z", stop: "end_turn"),
        ])
        let z = try entry(zeroedFirst, "msg_z", "req_z")
        XCTAssertEqual(z.usage.day, cal.startOfDay(for: HistoryTime.date(ms: finalMs)))
        XCTAssertEqual(z.stamp.first, partialMs)
        XCTAssertEqual(z.stamp.finalMs, finalMs)
    }

    /// `consume(object:)` answers "did it count" exactly as before the
    /// stamps: a record that counts is the one whose times a session row's
    /// model and effort follow (`ClaudeFileUsage.latestCounted`).
    func testCountedFlagIsUnchanged() throws {
        let lines = [
            F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", counts: .init(output: 3)),            // new key
            F.assistant(uuid: "b", ts: F.iso24(t0 + 1), mid: "m1", rid: "r1", counts: .init(output: 3)),        // equal partial
            F.assistant(uuid: "c", ts: F.iso24(t0 + 2), mid: "m1", rid: "r1", counts: .init(output: 9)),        // streamed further
            F.assistant(uuid: "d", ts: F.iso24(t0 + 3), mid: "m1", rid: "r1", stop: "end_turn"),                // final
            F.assistant(uuid: "e", ts: F.iso24(t0 + 4), mid: "m1", rid: "r1", stop: "end_turn", speed: "fast"), // final replay
            F.assistant(uuid: "f", ts: F.iso24(t0 + 5), mid: "m1", rid: "r1", stop: "end_turn", zeroed: true),  // zeroed replay
            F.assistant(uuid: "g", ts: F.iso24(t0 + 6), mid: "m1", rid: "r1", counts: .init(output: 99)),       // partial after final
            F.assistant(uuid: "h", ts: F.iso24(t0 + 7), mid: "m2", rid: "r2", stop: "end_turn", zeroed: true),  // zeroed new key
            F.assistant(uuid: "i", ts: F.iso24(t0 + 8), mid: "m2", rid: "r2", stop: "end_turn"),                // beats zeroed
            F.synthetic429(uuid: "j", ts: F.iso24(t0 + 9), rid: "r3", form: .both),                              // never counts
            F.usageCommand(uuid: "k", ts: F.iso24(t0 + 10), shape: .threeLimits),                               // not usage
        ]
        let expected = [true, false, true, true, false, false, false, true, true, false, false]
        let objects = lines.map { try! XCTUnwrap(JSONLLineReader.withLine(Data($0.utf8)) { $0.jsonObject() }) }
        var state = ClaudeJSONLScanner.ParseState(resuming: nil)
        XCTAssertEqual(objects.map { ClaudeJSONLScanner.consume(object: $0, into: &state, calendar: .current) }, expected)
        XCTAssertEqual(state.usage.keyed.map(\.finality), [.final, .final])
    }

    /// first = MIN, last = MAX over non-zeroed: the fold gives one value
    /// whatever the order and grouping of the records, and keeps every time
    /// exact however far apart the records are.
    func testTimeFoldIsOrderIndependentAtAnySpan() {
        let u32 = Int64(UInt32.max)
        let sets: [[(Int64?, UsageFinality, RequestFlags)]] = [
            [(1_000, .partial, []), (5_000, .final, .fast), (900, .zeroed, []), (nil, .partial, .abortedMidStream), (3_000, .partial, [])],
            // Spans around and far past 2^32 ms (49.7 days).
            [(0, .partial, []), (u32 - 10, .partial, []), (u32 + 5, .partial, []), (20, .zeroed, []), (7, .partial, .fast)],
            [(-50, .partial, []), (u32 - 60, .final, []), (nil, .zeroed, []), (10, .partial, []), (5, .partial, [])],
            [(-999_999_999_999_000, .zeroed, []), (999_999_999_999_000, .partial, []), (0, .final, .fast),
             (400 * 86_400_000, .final, []), (nil, .final, [])],
        ]
        func permutations<T>(_ items: [T]) -> [[T]] {
            guard items.count > 1 else { return [items] }
            return items.indices.flatMap { i -> [[T]] in
                var rest = items
                let head = rest.remove(at: i)
                return permutations(rest).map { [head] + $0 }
            }
        }
        for set in sets {
            let stamps = set.map { RecordStamp.of(ms: $0.0, finality: $0.1, flags: $0.2) }
            var results = Set<String>()
            for order in permutations(Array(stamps.indices)) {
                // The first record stands; the others fold in, one by one...
                var folded = stamps[order[0]]
                for i in order.dropFirst() { folded.absorb(stamps[i]) }
                // ...or as two pre-merged halves.
                var left = stamps[order[0]]
                for i in order[1..<3] { left.absorb(stamps[i]) }
                var right = stamps[order[3]]
                right.absorb(stamps[order[4]])
                left.absorb(right)
                XCTAssertEqual(folded.first, left.first)
                XCTAssertEqual(folded.lastMs, left.lastMs)
                XCTAssertEqual(folded.flags, left.flags)
                // The standing record's own final time never moves.
                XCTAssertEqual(folded.finalMs, stamps[order[0]].finalMs)
                XCTAssertEqual(left.finalMs, stamps[order[0]].finalMs)
                results.insert("\(String(describing: folded.first)) \(String(describing: folded.lastMs)) \(folded.flags.rawValue)")
            }
            XCTAssertEqual(results.count, 1, "one value for every order: \(results)")
            // The closed form: MIN over every stated time, MAX over the
            // counted records' ones.
            let times = set.compactMap(\.0)
            let counted = set.filter { $0.1 != .zeroed }.compactMap(\.0)
            XCTAssertEqual(results.first, "\(String(describing: times.min())) \(String(describing: counted.max())) "
                + "\(set.reduce(RequestFlags()) { $0.union($1.2) }.rawValue)")
        }
        // A span past the u32 range keeps its exact last time.
        var whole = RecordStamp.of(ms: 0, finality: .partial)
        whole.absorb(.of(ms: u32 + 5, finality: .partial))
        XCTAssertEqual(whole.lastMs, u32 + 5)
        var late = RecordStamp.of(ms: u32 + 5, finality: .final)
        late.absorb(.of(ms: 0, finality: .zeroed))
        XCTAssertEqual(late.first, 0)
        XCTAssertEqual(late.finalMs, u32 + 5)
    }

    /// Random keys whose records span up to 400 days in one file, through
    /// the real parser: every stamp is the closed form over the key's
    /// records, a resume at every line boundary — from memory or from a
    /// decoded entry — ends on the same value, and the observation states
    /// every time a record stated.
    func testStampsOfLongSpansAreExactAndResumeAtEveryBoundary() throws {
        let day: Int64 = 86_400_000
        var rng = HistorySplitMix64(seed: 0x5EED_0B5E)
        let tag = "gregorian|\(TimeZone.current.identifier)"
        for trial in 0..<40 {
            var lines: [String] = []
            var expected: [String: (first: Int64?, last: Int64?, final: Int64?)] = [:]
            var standing: [String: (finality: UsageFinality, output: Int)] = [:]
            for n in 0..<Int.random(in: 2...9, using: &rng) {
                let k = "k\(Int.random(in: 0..<3, using: &rng))"
                let finality: UsageFinality = [.zeroed, .partial, .partial, .final].randomElement(using: &rng)!
                let ts: Int64? = Int.random(in: 0..<10, using: &rng) == 0
                    ? nil
                    : t0 + Int64.random(in: -400 * day...400 * day, using: &rng)
                let output = Int.random(in: 1...50, using: &rng)
                lines.append(F.assistant(uuid: "u\(n)", ts: ts.map(F.iso24), mid: "m_\(k)", rid: "r_\(k)",
                                         stop: finality == .partial ? nil : "end_turn",
                                         counts: .init(output: output), zeroed: finality == .zeroed))
                // The closed form, with the parse's own rule for which record stands.
                var e = expected[k] ?? (nil, nil, nil)
                if let ts {
                    e.first = min(e.first ?? ts, ts)
                    if finality != .zeroed { e.last = max(e.last ?? ts, ts) }
                }
                let held = standing[k]
                let stands = held.map { finality != $0.finality ? finality > $0.finality
                    : finality == .partial && output > $0.output } ?? true
                if stands {
                    standing[k] = (finality, output)
                    e.final = finality == .final ? ts : nil
                }
                expected[k] = e
            }
            let whole = F.parse(lines)
            for (k, e) in expected {
                let record = try entry(whole, "m_\(k)", "r_\(k)")
                let label = "trial \(trial) \(k)"
                XCTAssertEqual(record.stamp.first, e.first, label)
                XCTAssertEqual(record.stamp.lastMs, e.last, label)
                XCTAssertEqual(record.stamp.finalMs, e.final, label)
                let index = try XCTUnwrap(whole.keyed.firstIndex { $0.key == record.key })
                let observation = whole.observation(at: index)
                XCTAssertEqual(observation.firstMs, e.first, label)
                XCTAssertEqual(observation.lastMs, e.last, label)
                XCTAssertEqual(observation.finalMs, e.final, label)
            }
            for split in 0...lines.count {
                let head = F.parse(Array(lines[..<split]))
                let stored = ClaudeUsageCacheStore.Entry(
                    fingerprint: LogFileFingerprint(path: "/tmp/p.jsonl", size: 1, modifiedAt: 1, fileID: 1, volumeID: 1),
                    parsedBytes: 1, value: head)
                let decoded = try ClaudeUsageCacheStore.decode(ClaudeUsageCacheStore.encode(stored, calendarTag: tag),
                                                               calendarTag: tag)
                XCTAssertEqual(decoded.value, head, "trial \(trial) split \(split): codec")
                XCTAssertEqual(F.parse(Array(lines[split...]), resuming: decoded.value), whole,
                               "trial \(trial) split \(split): resumed")
            }
        }
    }

    func testRecordWithoutTimestampContributesNoTime() throws {
        let usage = F.parse([
            F.assistant(uuid: "a", ts: nil, mid: "m1", rid: "r1", stop: "end_turn"),
        ])
        let record = try entry(usage, "m1", "r1")
        XCTAssertEqual(record.stamp.firstMs, RecordStamp.noTime)
        XCTAssertNil(record.stamp.lastMs)
        XCTAssertNil(record.stamp.finalMs)
        XCTAssertEqual(record.usage.day, Calendar.current.startOfDay(for: Date()), "the day keeps the undated-record fallback")
        XCTAssertNil(usage.observation(at: 0).firstMs)
        XCTAssertEqual(usage.usageHighWaterMs, RecordStamp.noTime)
        XCTAssertNil(usage.extras.firstCwdMs, "no time, no first record")

        // A timed record of the key folds in later.
        let later = F.parse([
            F.assistant(uuid: "a", ts: nil, mid: "m1", rid: "r1", stop: "end_turn"),
            F.assistant(uuid: "b", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn"),
        ])
        let folded = try entry(later, "m1", "r1")
        XCTAssertEqual(folded.stamp.first, t0)
        XCTAssertEqual(folded.stamp.lastMs, t0)
        XCTAssertNil(folded.stamp.finalMs, "the standing record stated no time of its own")
    }

    func testUnsafeLabelsAreDropped() throws {
        let long = String(repeating: "x", count: 65)
        let usage = F.parse([
            F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn",
                        version: "2.1.301\\u0007", effort: long, entrypoint: "claude-vsc\\u00f6de"),
            F.assistant(uuid: "b", ts: F.iso24(t0), mid: "m2", rid: "r2", stop: "end_turn",
                        version: "", effort: String(repeating: "y", count: 64), entrypoint: nil),
        ])
        XCTAssertEqual(attributes(usage, try entry(usage, "m1", "r1")), RecordAttributes(), "control byte, 65 bytes, non-ASCII")
        XCTAssertEqual(attributes(usage, try entry(usage, "m2", "r2")),
                       RecordAttributes(version: nil, effort: String(repeating: "y", count: 64), entrypoint: nil))
        XCTAssertNil(ClaudeJSONLScanner.label(1))
        XCTAssertNil(ClaudeJSONLScanner.label("tab\there"))
        XCTAssertEqual(ClaudeJSONLScanner.label("five_hour"), "five_hour")
        XCTAssertNil(ClaudeJSONLScanner.cwd(String(repeating: "/", count: 4_097)))
        XCTAssertEqual(ClaudeJSONLScanner.cwd("/tmp/äöü"), "/tmp/äöü")
    }

    /// Three absolute times (24 bytes) plus thinking, attributes and flags
    /// (7) leave one byte of the stamp's 8-byte alignment, which `finality`
    /// fills: 88 bytes of key, usage and iterations, then 32. Every warm
    /// launch holds one `KeyedUsage` per request, so extra stride increases retained heap.
    func testKeyedUsageStrideIsPinned() {
        XCTAssertEqual(MemoryLayout<RecordStamp>.size, 31)
        XCTAssertEqual(MemoryLayout<KeyedUsage>.stride, 120)
    }

    /// OR over every record of the key: 3 of the 4 real aborted records are
    /// not the one that counts.
    func testFlagsAreFoldedOverNonWinningRecords() throws {
        let lines = [
            F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", counts: .init(output: 9), aborted: true),
            F.assistant(uuid: "b", ts: F.iso24(t0 + 1), mid: "m1", rid: "r1", counts: .init(output: 3)),  // does not stand
            F.assistant(uuid: "c", ts: F.iso24(t0 + 2), mid: "m1", rid: "r1", stop: "end_turn", speed: "standard"),
            F.assistant(uuid: "d", ts: F.iso24(t0 + 3), mid: "m1", rid: "r1", stop: "end_turn", speed: "fast"), // replay, does not stand
            F.assistant(uuid: "e", ts: F.iso24(t0), mid: "m2", rid: "r2", stop: "end_turn"),
            F.assistant(uuid: "f", ts: F.iso24(t0), mid: "m2", rid: "r2", counts: .init(output: 1), aborted: true), // loser
        ]
        let usage = F.parse(lines)
        XCTAssertEqual(try entry(usage, "m1", "r1").stamp.flags, [.fast, .abortedMidStream])
        XCTAssertEqual(try entry(usage, "m2", "r2").stamp.flags, .abortedMidStream)
        XCTAssertEqual(usage.observation(at: 0).flags, [.fast, .abortedMidStream])
        for split in 1..<lines.count {
            XCTAssertEqual(F.parse(Array(lines[split...]), resuming: F.parse(Array(lines[..<split]))), usage, "split \(split)")
        }
        XCTAssertEqual(try entry(usage, "m1", "r1").usage.counts.output, 10, "flags never decide which record counts")
    }

    func testBothTimestampFormsParse() throws {
        let whole: Int64 = t0 + 7_000
        let usage = F.parse([
            F.assistant(uuid: "a", ts: F.iso20(whole), mid: "m1", rid: "r1", stop: "end_turn"),
            F.assistant(uuid: "b", ts: F.iso24(whole + 1), mid: "m2", rid: "r2", stop: "end_turn"),
            F.assistant(uuid: "c", ts: "2026-10-14T23:59:07.0015Z", mid: "m3", rid: "r3", stop: "end_turn"),
        ])
        XCTAssertEqual(F.iso20(whole).count, 20)
        XCTAssertEqual(F.iso24(whole).count, 24)
        XCTAssertEqual(try entry(usage, "m1", "r1").stamp.first, whole)
        XCTAssertEqual(try entry(usage, "m2", "r2").stamp.first, whole + 1)
        XCTAssertEqual(try entry(usage, "m3", "r3").stamp.first, whole + 1, "sub-ms digits are cut, as the parse does")
    }

    // MARK: - Extras

    private func scanFile(_ lines: [String]) async throws -> (UsageReport, HistoryFileBatch) {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(F.session).jsonl")
        try F.write(lines, to: url)
        let sink = RecordingHistorySink()
        let report = await ClaudeJSONLScanner.usageReport(files: [url], completeHistory: true,
                                                          cache: ClaudeUsageCache(store: nil), history: sink)
        return (report, try XCTUnwrap(sink.lastScan?.file(url)))
    }

    func testLimitEventIsReadFromTheSyntheticRecordAndNotCounted() async throws {
        let counted = F.assistant(uuid: "a", ts: F.iso24(t0), mid: "m1", rid: "r1", stop: "end_turn")
        let limitLines = [
            F.synthetic429(uuid: "q1", ts: F.iso24(t0 + 1_000), rid: "req_q1", form: .quotaLimits),
            F.synthetic429(uuid: "q1", ts: F.iso24(t0 + 1_000), rid: "req_q1", form: .quotaLimits),   // same-file replay
            F.synthetic429(uuid: "q2", ts: F.iso24(t0 + 2_000), rid: "req_q2", form: .rateLimitInfo),
            F.synthetic429(uuid: "q3", ts: F.iso24(t0 + 3_000), rid: "req_q3", form: .both),
            F.synthetic429(uuid: "q4", ts: F.iso24(t0 + 4_000), rid: "req_q4", form: .neither),
        ]
        let (plain, _) = try await scanFile([counted])
        let (report, batch) = try await scanFile([counted] + limitLines)
        XCTAssertEqual(report.dayModels, plain.dayModels, "a 429 never counts")
        XCTAssertEqual(report.requestFinality, plain.requestFinality)
        let events = batch.events.limitEvents
        XCTAssertEqual(events.map(\.uuid), ["q1", "q2", "q3"])
        XCTAssertEqual(events.map(\.source), ["quotaLimits", "rate_limit_info", "quotaLimits"])
        XCTAssertEqual(events[0].requestID, "req_q1")
        XCTAssertEqual(events[0].tsMs, t0 + 1_000)
        XCTAssertEqual(events[0].windowID, "five_hour")
        XCTAssertEqual(events[0].status, "rejected")
        XCTAssertEqual(events[0].resetsAtMs, 1_792_375_200_000, "seconds in the record, ms here")
        XCTAssertEqual(events[0].overageStatus, "rejected")
        XCTAssertEqual(events[0].overageDisabledReason, "org_level_disabled")
        XCTAssertEqual(events[0].isUsingOverage, false)
        XCTAssertEqual(events[0].fallbackAvailable, false)
        XCTAssertNil(events[0].apiError)
        XCTAssertEqual(events[0].ccVersion, "2.1.301")
        XCTAssertNil(events[1].fallbackAvailable, "rate_limit_info has no fallback flag")
        XCTAssertEqual(events[1].apiError, "usage_limit_reached")
        XCTAssertEqual(batch.allRequests().count, 1, "the 429s are not requests")
    }

    /// One rejected request is one event, as the history keys it (by request
    /// id): a second 429 line of the same request under another uuid is a
    /// copy, in one parse and across a resume between the two.
    func testLimitEventsOfOneRequestAreOneEventWhateverTheirUuids() async throws {
        let lines = [
            F.synthetic429(uuid: "q1", ts: F.iso24(t0 + 1_000), rid: "req_q1", form: .quotaLimits),
            F.synthetic429(uuid: "q1-copy", ts: F.iso24(t0 + 1_200), rid: "req_q1", form: .rateLimitInfo),
            F.synthetic429(uuid: "q2", ts: F.iso24(t0 + 2_000), rid: "req_q2", form: .quotaLimits),
        ]
        let (_, batch) = try await scanFile(lines)
        let events = batch.events.limitEvents
        XCTAssertEqual(events.map(\.requestID), ["req_q1", "req_q2"])
        XCTAssertEqual(events.map(\.uuid), ["q1", "q2"], "the first copy is kept")
        XCTAssertEqual(events.first?.tsMs, t0 + 1_000)
        XCTAssertEqual(events.first?.source, "quotaLimits")
        for split in 1..<lines.count {
            XCTAssertEqual(F.parse(Array(lines[split...]), resuming: F.parse(Array(lines[..<split]))).extras.limitEvents,
                           events, "split \(split)")
        }
    }

    func testUsageReportIsReadFromLocalCommand() async throws {
        let (_, batch) = try await scanFile([
            F.usageCommand(uuid: "r1", ts: F.iso24(t0), shape: .rateLimitsNull),
            F.usageCommand(uuid: "r2", ts: F.iso24(t0 + 1), shape: .limitsNull),
            F.usageCommand(uuid: "r3", ts: F.iso20(t0 + 2_000), shape: .threeLimits),
            F.usageCommand(uuid: "r3", ts: F.iso20(t0 + 2_000), shape: .threeLimits),
        ])
        let reports = batch.events.usageReports
        XCTAssertEqual(reports.map(\.uuid), ["r1", "r2", "r3"])
        XCTAssertEqual(reports.map(\.hasLimits), [false, false, true])
        XCTAssertNil(reports[0].extraEnabled)
        XCTAssertEqual(reports[1].extraEnabled, true)
        XCTAssertEqual(reports[1].extraMonthlyLimit, 0)
        XCTAssertEqual(reports[2].tsMs, t0 + 2_000)
        XCTAssertEqual(reports[2].ccVersion, "2.1.285")
        let limits = reports[2].limits
        XCTAssertEqual(limits.map(\.index), [0, 1, 2])
        XCTAssertEqual(limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(limits.map(\.windowID), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(limits.map(\.percent), [27, 81, 93])
        XCTAssertEqual(limits.map(\.severity), ["normal", "warning", "critical"])
        XCTAssertEqual(limits.map(\.isActive), [false, true, false])
        XCTAssertNil(limits[0].resetsAtMs)
        XCTAssertEqual(limits[1].resetsAtMs, HistoryTime.ms(try XCTUnwrap(CodexRolloutReader.parseISO("2026-10-20T02:09:59.709Z"))))
        XCTAssertEqual(limits[2].resetsAtMs, HistoryTime.ms(try XCTUnwrap(CodexRolloutReader.parseISO("2026-10-20T02:10:00Z"))))
        XCTAssertEqual(limits[2].scopeModel, "Fable")
        XCTAssertTrue(batch.allRequests().isEmpty)
    }

    /// `afterTsMs` is the running MAX of the usage records before the cost
    /// state, not the last one in file order: replays re-append old times.
    func testCostStateIsReadByPrefixWithTheRunningMaxBeforeIt() async throws {
        let (_, batch) = try await scanFile([
            F.costState(start: 1_791_000_000_000, total: 1_000, cost: "0", withModels: false),   // nothing before it
            F.assistant(uuid: "a", ts: F.iso24(t0 + 9_000), mid: "m1", rid: "r1", stop: "end_turn"),
            F.assistant(uuid: "b", ts: F.iso24(t0 + 2_000), mid: "m0", rid: "r0", stop: "end_turn"),   // replayed older request
            F.costState(start: 1_791_000_000_000, total: 5_000),
            F.costState(start: 1_791_000_000_000, total: 5_000),                                      // same snapshot again
            F.title(),
        ])
        let states = batch.events.costStates
        XCTAssertEqual(states.map(\.totalDurationMs), [1_000, 5_000])
        XCTAssertNil(states[0].afterTsMs)
        XCTAssertEqual(states[1].afterTsMs, t0 + 9_000)
        XCTAssertEqual(states[1].sessionID, F.session)
        XCTAssertEqual(states[1].startTimeMs, 1_791_000_000_000)
        XCTAssertEqual(states[1].totalAPIDurationMs, 4_000)
        XCTAssertEqual(states[1].totalCostUSD, 1.5)
        XCTAssertEqual(states[1].hasUnknownModelCost, false)
        XCTAssertEqual(states[1].models.map(\.modelKey), ["claude-opus-5-5", "claude-opus-5-5[1m]"])
        XCTAssertEqual(states[1].models[0], CostStateModel(modelKey: "claude-opus-5-5", input: 10, output: 20, cacheRead: 30,
                                                           cacheCreation: 40, thinking: 5, webSearch: 0, costUSD: 1.25))
        XCTAssertEqual(states[0].totalCostUSD, 0)
        XCTAssertTrue(states[0].models.isEmpty)
    }

    func testCompactBoundaryIsReadOnceAcrossReplays() async throws {
        let compact = F.compactBoundary(uuid: "cb1", ts: F.iso24(t0 + 50))
        XCTAssertLessThan(try XCTUnwrap(compact.range(of: #""subtype":"compact_boundary""#)).upperBound.utf16Offset(in: compact),
                          ClaudeJSONLScanner.compactBoundarySearchLength)
        let (_, batch) = try await scanFile([
            compact,
            F.user(uuid: "u1", ts: F.iso24(t0 + 60)),
            compact,
            F.compactBoundary(uuid: "cb2", ts: F.iso20(t0 + 7_000), trigger: "auto", pre: 1_004_079, post: 32_780),
            compact,
        ])
        XCTAssertEqual(batch.events.compactEvents, [
            CompactEventObservation(uuid: "cb1", tsMs: t0 + 50, trigger: "manual", preTokens: 180_512, postTokens: 9_871),
            CompactEventObservation(uuid: "cb2", tsMs: t0 + 7_000, trigger: "auto", preTokens: 1_004_079, postTokens: 32_780),
        ])
        // Off on request: nothing read, and a usage line is never taken for one.
        let off = F.parse([compact], collectsCompactEvents: false)
        XCTAssertTrue(off.extras.compactEvents.isEmpty)
    }

    func testFirstCwdIgnoresReplaysWithAnotherCwd() async throws {
        let (_, batch) = try await scanFile([
            // A resumed session first replays an older request from another
            // directory: its streaming record, then its final one, which
            // REPLACES it (and is earlier) but is still not first of its key...
            F.assistant(uuid: "a", ts: F.iso24(t0 + 5_000), mid: "m2", rid: "r2",
                        version: "2.1.300", entrypoint: "claude-vscode", cwd: "/Users/dev/project"),
            F.assistant(uuid: "b", ts: F.iso24(t0 + 1_000), mid: "m2", rid: "r2", stop: "end_turn",
                        version: "2.1.301", entrypoint: "cli", cwd: "/Users/dev/elsewhere"),
            // ...then its earliest request of its own, and a tie at the same ms.
            F.assistant(uuid: "c", ts: F.iso24(t0 + 3_000), mid: "m1", rid: "r1", stop: "end_turn",
                        version: "2.1.299", entrypoint: "sdk-ts", cwd: "/Users/dev/zeta"),
            F.assistant(uuid: "d", ts: F.iso24(t0 + 3_000), mid: "m3", rid: "r3", stop: "end_turn",
                        version: "2.1.298", entrypoint: "sdk-cli", cwd: "/Users/dev/alpha"),
        ])
        let e = batch.events
        XCTAssertEqual(e.firstCwd, "/Users/dev/alpha", "earliest first-of-key record, ties to the smaller cwd")
        XCTAssertEqual(e.firstCwdMs, t0 + 3_000)
        XCTAssertEqual(e.firstEntrypoint, "sdk-cli")
        XCTAssertEqual(e.firstCcVersion, "2.1.298")
        // The earlier replay did stand for its key: being counted is not
        // being first of the key.
        let replayed = try XCTUnwrap(batch.allRequests().first { $0.key == DedupKey(messageID: "m2", requestID: "r2") })
        XCTAssertEqual(replayed.finality, .final)
        XCTAssertEqual(replayed.ccVersion, "2.1.301")
        XCTAssertEqual(replayed.firstMs, t0 + 1_000)
    }
}
