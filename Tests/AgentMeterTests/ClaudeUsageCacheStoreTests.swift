import CryptoKit
import Foundation
@testable import AgentMeter
import XCTest

/// The entry codec on its own: a round trip is exact, and nothing a damaged
/// or forged file can contain reaches an array allocation or a crash — every
/// such input throws and is treated as no entry.
final class ClaudeUsageCacheStoreTests: XCTestCase {
    private let tag = "gregorian|Asia/Tokyo"

    /// The largest time a parse produces (`ClaudeJSONLScanner.epochMs`).
    private let edgeMs: Int64 = 999_999_999_999_999

    /// A stamp a parse could produce for a record of `finality`, cycling
    /// through: no time / first time only / first+last(+final) / a span far
    /// past 2^32 ms / the widest span a parse can produce; thinking none / 0 /
    /// the largest value; attributes none / set 1 / set 2; flags none / fast
    /// / aborted / both.
    private func sampleStamp(_ i: Int, finality: UsageFinality) -> RecordStamp {
        var stamp = RecordStamp()
        let first: Int64 = 1_792_000_000_000 + Int64(i) * 1_337
        switch i % 5 {
        case 0: break
        case 1: stamp.firstMs = first
        case 2:
            stamp.firstMs = first
            if finality != .zeroed { stamp.latestMs = first + Int64(i * 1_000) }
            if finality == .final { stamp.ownFinalMs = first + Int64(i * 500) }
        case 3:
            stamp.firstMs = -first   // a time before 1970 is still a time
            if finality != .zeroed { stamp.latestMs = first + 400 * 86_400_000 }
            if finality == .final { stamp.ownFinalMs = first + 50 * 86_400_000 }
        default:
            stamp.firstMs = -edgeMs
            if finality != .zeroed { stamp.latestMs = edgeMs }
            if finality == .final { stamp.ownFinalMs = edgeMs }
        }
        stamp.thinking = [RecordStamp.noThinking, 0, RecordStamp.noThinking - 1][i % 3]
        stamp.attributes = UInt16(i % 3)
        stamp.flags = [[], .fast, .abortedMidStream, [.fast, .abortedMidStream]][i % 4]
        return stamp
    }

    /// One of every event kind, every optional both set and nil, a
    /// non-ASCII cwd and a `[1m]` cost-state model key.
    private func sampleExtras() -> HistoryFileEvents {
        var e = HistoryFileEvents()
        e.firstCwd = "/tmp/äöü/project"
        e.firstCwdMs = 1_792_000_000_123
        e.firstEntrypoint = "claude-vscode"
        e.firstCcVersion = "2.1.301"
        e.limitEvents = [
            LimitEventObservation(
                uuid: "6f0c1f9e-0000-4000-8000-000000000001", requestID: "req_011CU1", tsMs: 1_792_000_001_000,
                windowID: "five_hour", status: "rejected", resetsAtMs: 1_792_375_200_000, overageStatus: "rejected",
                overageDisabledReason: "org_level_disabled", isUsingOverage: false, fallbackAvailable: true,
                source: "quotaLimits", apiError: "usage_limit_reached", ccVersion: "2.1.301"),
            LimitEventObservation(
                uuid: "6f0c1f9e-0000-4000-8000-000000000002", requestID: nil, tsMs: -5,
                windowID: "five_hour", status: nil, resetsAtMs: nil, overageStatus: nil,
                overageDisabledReason: nil, isUsingOverage: nil, fallbackAvailable: nil,
                source: "rate_limit_info", apiError: nil, ccVersion: nil),
        ]
        e.usageReports = [
            UsageReportObservation(
                uuid: "6f0c1f9e-0000-4000-8000-000000000003", tsMs: 1_792_000_002_000, ccVersion: "2.1.285",
                hasLimits: true, extraEnabled: true, extraMonthlyLimit: 0, extraUsedCredits: 12,
                limits: [
                    UsageReportLimit(index: 0, kind: "session", group: "session", percent: 41, severity: "normal",
                                     isActive: true, resetsAtMs: nil, scopeModel: nil),
                    UsageReportLimit(index: 1, kind: "weekly_all", group: "weekly", percent: 77.5, severity: "warning",
                                     isActive: false, resetsAtMs: 1_792_400_000_317, scopeModel: nil),
                    UsageReportLimit(index: 2, kind: "weekly_scoped", group: nil, percent: nil, severity: nil,
                                     isActive: nil, resetsAtMs: 1_792_400_001_000, scopeModel: "Fable"),
                ]),
            UsageReportObservation(
                uuid: "6f0c1f9e-0000-4000-8000-000000000004", tsMs: 1_792_000_003_000, ccVersion: nil,
                hasLimits: false, extraEnabled: nil, extraMonthlyLimit: nil, extraUsedCredits: nil, limits: []),
        ]
        e.costStates = [
            CostStateObservation(
                sessionID: "0b3a5c1e-0000-4000-8000-000000000005", startTimeMs: 1_791_000_000_000,
                totalDurationMs: 7_412, totalAPIDurationMs: nil, totalCostUSD: 0, hasUnknownModelCost: false,
                afterTsMs: nil, models: []),
            CostStateObservation(
                sessionID: "0b3a5c1e-0000-4000-8000-000000000005", startTimeMs: 1_791_000_000_000,
                totalDurationMs: 99_412, totalAPIDurationMs: 51_000, totalCostUSD: 12.375, hasUnknownModelCost: true,
                afterTsMs: 1_792_000_004_000,
                models: [
                    CostStateModel(modelKey: "claude-opus-5-5", input: 10, output: 20, cacheRead: 30,
                                   cacheCreation: 40, thinking: 5, webSearch: 0, costUSD: 1.25),
                    CostStateModel(modelKey: "claude-opus-5-5[1m]", input: 1, output: 2, cacheRead: 3,
                                   cacheCreation: 4, thinking: 0, webSearch: 1, costUSD: 11.125),
                ]),
        ]
        e.compactEvents = [
            CompactEventObservation(uuid: "6f0c1f9e-0000-4000-8000-000000000006", tsMs: 1_792_000_005_000,
                                    trigger: "manual", preTokens: 1_004_079, postTokens: 32_780),
            CompactEventObservation(uuid: "6f0c1f9e-0000-4000-8000-000000000007", tsMs: 1_792_000_006_000,
                                    trigger: nil, preTokens: nil, postTokens: nil),
        ]
        return e
    }

    private func sampleEntry(identity: Bool = true) -> ClaudeUsageCacheStore.Entry {
        let day = Calendar.current.startOfDay(for: Date())
        let keyed = (0..<50).map { i in
            let recordDay = day.addingTimeInterval(Double(i % 3) * -86_400)
            // Every tenth request fell back from a Fable attempt, which the
            // record carries as an earlier iteration under its own model.
            let earlier = i % 10 == 0
                ? [DayModelUsage(day: recordDay, model: "claude-fable-5-1",
                                 counts: TokenCounts(input: 1, output: i + 7, cacheWrite5m: 2, cacheWrite1h: 0, cacheRead: 900))]
                : []
            let finality = [UsageFinality.final, .partial, .zeroed][i % 3]
            return KeyedUsage(
                key: DedupKey(messageID: "msg_\(i)", requestID: "req_\(i)"),
                usage: DayModelUsage(
                    day: recordDay,
                    model: ["claude-sonnet-4-5-20250929", "claude-opus-4-1-20250805"][i % 2],
                    counts: TokenCounts(input: i, output: i * 2, cacheWrite5m: i * 3, cacheWrite1h: i * 4, cacheRead: i * 5)),
                earlierIterations: earlier,
                finality: finality,
                stamp: sampleStamp(i, finality: finality))
        }
        let unkeyed = [DayModelUsage(day: day, model: "default", counts: TokenCounts(input: 1, output: 2, cacheWrite5m: 3, cacheWrite1h: 4, cacheRead: 5))]
        var value = ClaudeFileUsage(keyed: keyed, unkeyed: unkeyed,
                                    boundaryDigest: ClaudeUsageCacheStore.boundaryDigest(of: Data("tail".utf8)))
        value.attributeSets = [
            RecordAttributes(version: "2.1.301", effort: "xhigh", entrypoint: "claude-vscode"),
            RecordAttributes(version: nil, effort: nil, entrypoint: "cli"),
        ]
        value.extras = sampleExtras()
        value.usageHighWaterMs = 1_792_000_009_999
        return ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(
                path: "/tmp/projects/-Users-x/äöü session.jsonl", size: 123_456, modifiedAt: 1_760_000_000.123456,
                fileID: identity ? 42 : nil, volumeID: identity ? 7 : nil),
            parsedBytes: 123_000,
            value: value)
    }

    func testRoundTripIsExact() throws {
        for identity in [true, false] {
            let entry = sampleEntry(identity: identity)
            let data = ClaudeUsageCacheStore.encode(entry, calendarTag: tag)
            let decoded = try ClaudeUsageCacheStore.decode(data, calendarTag: tag)
            XCTAssertEqual(decoded, entry)
        }
        let empty = ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(path: "/tmp/empty.jsonl", size: 0, modifiedAt: 0, fileID: 1, volumeID: 1),
            parsedBytes: 0, value: .empty)
        let decodedEmpty = try ClaudeUsageCacheStore.decode(ClaudeUsageCacheStore.encode(empty, calendarTag: tag), calendarTag: tag)
        XCTAssertEqual(decodedEmpty, empty)
    }

    /// The boundary digest fits `Data`'s inline storage, so the one every
    /// cached file carries (one per transcript on a warm launch) is no heap
    /// object of its own; a decoded entry's is the same length.
    func testBoundaryDigestIsHeldInline() throws {
        let tail = Data("tail".utf8)
        let digest = ClaudeUsageCacheStore.boundaryDigest(of: tail)
        XCTAssertEqual(digest.count, 14)
        XCTAssertEqual(digest, Data(CryptoKit.SHA256.hash(data: tail).prefix(14)))
        let decoded = try ClaudeUsageCacheStore.decode(ClaudeUsageCacheStore.encode(sampleEntry(), calendarTag: tag),
                                                       calendarTag: tag)
        XCTAssertEqual(decoded.value.boundaryDigest.count, 14)

        func heapInUse() -> Int64 {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Int64(stats.size_in_use)
        }
        let count = 10_000
        var held: [Data] = []
        held.reserveCapacity(count)
        let before = heapInUse()
        for _ in 0..<count { held.append(ClaudeUsageCacheStore.boundaryDigest(of: tail)) }
        let perDigest = Double(heapInUse() - before) / Double(count)
        // A 16-byte digest costs ~96 bytes of heap each; an inline one none.
        XCTAssertLessThan(perDigest, 32, "heap bytes per digest")
        XCTAssertEqual(held.count, count)
    }

    func testEveryTruncationThrows() {
        let data = ClaudeUsageCacheStore.encode(sampleEntry(), calendarTag: tag)
        for length in 0..<data.count {
            XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(data.prefix(length), calendarTag: tag), "length \(length)")
        }
    }

    func testEveryByteFlipThrows() {
        let data = ClaudeUsageCacheStore.encode(sampleEntry(), calendarTag: tag)
        for offset in stride(from: 0, to: data.count, by: 7) {
            var damaged = data
            damaged[offset] ^= 0x5A
            XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(damaged, calendarTag: tag), "byte \(offset)")
        }
    }

    func testGarbageAndEmptyInputThrow() {
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(Data(), calendarTag: tag))
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(Data(repeating: 0xFF, count: 100), calendarTag: tag))
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(Data("AMCU".utf8) + Data(repeating: 0, count: 60), calendarTag: tag))
    }

    func testOtherVersionAndCalendarAreRejected() {
        var data = ClaudeUsageCacheStore.encode(sampleEntry(), calendarTag: tag)
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(data, calendarTag: "gregorian|Europe/Berlin")) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .calendarTag)
        }
        // Version 3 held the last and final times as u32 offsets; version 2
        // holds no stamps and no extras: both have to be parsed again, not
        // read. Version 1 holds first-wins records with no finality.
        data.replaceSubrange(4..<8, with: [0x03, 0, 0, 0])
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(data, calendarTag: tag)) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .version(3))
        }
        data.replaceSubrange(4..<8, with: [0x02, 0, 0, 0])
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(data, calendarTag: tag)) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .version(2))
        }
        data.replaceSubrange(4..<8, with: [0x01, 0, 0, 0])
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(data, calendarTag: tag)) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .version(1))
        }
    }

    /// Each released format keeps its own directory, so an older build
    /// running beside this one never deletes this one's entries, nor this
    /// one its. Version 4 replaced the unreleased version 3 in place.
    func testEachFormatHasItsOwnDirectory() {
        XCTAssertEqual(ClaudeUsageCacheStore.formatVersion, 4)
        XCTAssertEqual(ClaudeUsageCacheStore.defaultDirectory.lastPathComponent,
                       "claude-usage-cache-v\(ClaudeUsageCacheStore.directoryFormat)")
        XCTAssertEqual(ClaudeUsageCacheStore.defaultDirectory.lastPathComponent, "claude-usage-cache-v3")
        XCTAssertEqual(ClaudeUsageCacheStore.legacyDirectories.map(\.lastPathComponent),
                       ["claude-usage-cache", "claude-usage-cache-v2"])
        XCTAssertFalse(ClaudeUsageCacheStore.legacyDirectories.contains(ClaudeUsageCacheStore.defaultDirectory))
    }

    /// An entry in version 3's layout — the same directory, u32 offsets for
    /// the last and final times, a 93-byte record — with a valid checksum:
    /// the version alone rejects it, before any of its bytes is read as a
    /// record, so it is deleted and its log parsed again.
    func testAnEntryInVersionThreesLayoutIsNeverRead() async throws {
        var stamp = RecordStamp()
        stamp.firstMs = 1_792_000_000_000
        stamp.latestMs = stamp.firstMs + 5
        stamp.ownFinalMs = stamp.firstMs + 5
        stamp.thinking = 7
        let current = ClaudeUsageCacheStore.encode(oneRecordEntry(finality: .final, stamp: stamp), calendarTag: tag)
        // The stamp is the last 31 bytes before the unkeyed count; version 3
        // wrote firstMs i64, lastDelta u32, finalDelta u32, then the same
        // thinking, attributes and flags.
        var body = Data(current.prefix(current.count - 32))
        let stampStart = body.count - 4 - 31
        var oldStamp = Data(body[stampStart..<stampStart + 8])
        oldStamp.append(contentsOf: [5, 0, 0, 0, 5, 0, 0, 0])
        oldStamp.append(body[stampStart + 24..<stampStart + 31])
        body.replaceSubrange(stampStart..<stampStart + 31, with: oldStamp)
        body.replaceSubrange(4..<8, with: [3, 0, 0, 0])
        body.append(contentsOf: Array(SHA256Digest.of(body)))
        XCTAssertEqual(body.count, current.count - 8)
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(body, calendarTag: tag)) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .version(3))
        }

        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-usage-v3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ClaudeUsageCacheStore.entryFileName(for: "/tmp/a.jsonl"))
        try body.write(to: url)
        let store = ClaudeUsageCacheStore(directory: dir, calendarTag: tag)
        let read = await store.entry(for: "/tmp/a.jsonl")
        XCTAssertNil(read)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The codec is lossless on the values a parse produces at their limits:
    /// spans far past 2^32 ms, the widest span, absent stamps, the largest
    /// thinking count, every optional of every event kind nil and set, a
    /// non-ASCII cwd.
    func testExtremeStampsAndEveryEventKindRoundTrip() throws {
        let entry = sampleEntry()
        let u32 = Int64(UInt32.max)
        XCTAssertTrue(entry.value.keyed.contains { ($0.stamp.lastMs ?? 0) - ($0.stamp.first ?? 0) > u32 })
        XCTAssertTrue(entry.value.keyed.contains { ($0.stamp.finalMs ?? 0) - ($0.stamp.first ?? 0) > u32 })
        XCTAssertTrue(entry.value.keyed.contains { $0.stamp.first == -edgeMs && $0.stamp.lastMs == edgeMs })
        XCTAssertTrue(entry.value.keyed.contains { $0.stamp.firstMs == RecordStamp.noTime })
        let decoded = try ClaudeUsageCacheStore.decode(ClaudeUsageCacheStore.encode(entry, calendarTag: tag), calendarTag: tag)
        XCTAssertEqual(decoded.value.extras, entry.value.extras)
        XCTAssertEqual(decoded.value.attributeSets, entry.value.attributeSets)
        XCTAssertEqual(decoded.value.usageHighWaterMs, entry.value.usageHighWaterMs)
        XCTAssertEqual(decoded.value.keyed.map(\.stamp), entry.value.keyed.map(\.stamp))
        XCTAssertEqual(decoded, entry)
        // Encoding the decoded value again gives the same bytes.
        XCTAssertEqual(ClaudeUsageCacheStore.encode(decoded, calendarTag: tag),
                       ClaudeUsageCacheStore.encode(entry, calendarTag: tag))
    }

    /// One keyed record and nothing else, so its stamp sits at fixed
    /// offsets from the end of the body.
    private func oneRecordEntry(finality: UsageFinality, stamp: RecordStamp, cwd: String? = nil) -> ClaudeUsageCacheStore.Entry {
        var value = ClaudeFileUsage(
            keyed: [KeyedUsage(key: DedupKey(hi: 1, lo: 2),
                               usage: DayModelUsage(day: Date(timeIntervalSince1970: 0), model: "m", counts: TokenCounts()),
                               finality: finality, stamp: stamp)],
            unkeyed: [], boundaryDigest: Data())
        value.extras.firstCwd = cwd
        return ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(path: "/tmp/a.jsonl", size: 10, modifiedAt: 1, fileID: 1, volumeID: 1),
            parsedBytes: 10, value: value)
    }

    /// `body` with `bytes` written at `offset` from its end (before the
    /// unkeyed count) and a fresh checksum: damage the checksum cannot see.
    private func forged(_ entry: ClaudeUsageCacheStore.Entry, fromEnd offset: Int, _ bytes: [UInt8]) -> Data {
        let data = ClaudeUsageCacheStore.encode(entry, calendarTag: tag)
        var body = Data(data.prefix(data.count - 32))
        let start = body.count - 4 - offset
        body.replaceSubrange(start..<start + bytes.count, with: bytes)
        body.append(contentsOf: Array(SHA256Digest.of(body)))
        return body
    }

    private func le64(_ v: Int64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    /// Stamps a parse cannot produce are damage, even under a valid checksum.
    func testForgedStampsAreRejected() throws {
        var timed = RecordStamp()
        timed.firstMs = 1_000
        timed.latestMs = 1_005
        let partial = oneRecordEntry(finality: .partial, stamp: timed)
        timed.ownFinalMs = 1_003
        let final = oneRecordEntry(finality: .final, stamp: timed)
        for entry in [partial, final] {
            XCTAssertNoThrow(try ClaudeUsageCacheStore.decode(ClaudeUsageCacheStore.encode(entry, calendarTag: tag), calendarTag: tag))
        }
        // Record tail: firstMs i64 (-31), latestMs i64 (-23), ownFinalMs i64
        // (-15), thinking u32 (-7), attributes u16 (-3), flags u8 (-1).
        let cases: [(String, ClaudeUsageCacheStore.Entry, Int, [UInt8])] = [
            ("unknown flag bit", partial, 1, [0x04]),
            ("attribute set that does not exist", partial, 3, [0x01, 0x00]),
            ("final time on a partial record", partial, 15, le64(1_003)),
            ("first time out of range", partial, 31, [0, 0, 0, 0, 0, 0, 0, 0x7F]),
            ("last time out of range", partial, 23, [0, 0, 0, 0, 0, 0, 0, 0x7F]),
            ("last time before the first", partial, 23, le64(999)),
            ("final time after the last", final, 15, le64(1_006)),
            ("final time before the first", final, 15, le64(999)),
            ("final time without a last time", final, 23, le64(RecordStamp.noTime)),
        ]
        for (name, entry, offset, bytes) in cases {
            XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(forged(entry, fromEnd: offset, bytes), calendarTag: tag), name) { error in
                XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .truncated, name)
            }
        }
        let untimed = oneRecordEntry(finality: .zeroed, stamp: RecordStamp())
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(forged(untimed, fromEnd: 23, le64(1_000)), calendarTag: tag),
                             "a last time without a first time")
        var zeroed = RecordStamp()
        zeroed.firstMs = 1_000
        let zeroedEntry = oneRecordEntry(finality: .zeroed, stamp: zeroed)
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(forged(zeroedEntry, fromEnd: 23, le64(1_000)), calendarTag: tag),
                             "a last time on a zeroed record")
    }

    /// A string that is not valid UTF-8 is damage: decoding it leniently
    /// would hand back a string that encodes to other bytes.
    func testInvalidUTF8IsRejected() throws {
        let entry = oneRecordEntry(finality: .final, stamp: RecordStamp(), cwd: "/cwd-QQQ")
        let data = ClaudeUsageCacheStore.encode(entry, calendarTag: tag)
        var body = Data(data.prefix(data.count - 32))
        let range = try XCTUnwrap(body.range(of: Data("/cwd-QQQ".utf8)))
        body[range.lowerBound + 5] = 0xFF
        body.append(contentsOf: Array(SHA256Digest.of(body)))
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(body, calendarTag: tag)) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .truncated)
        }
    }

    /// A complete scan removes a legacy directory nothing has written for a
    /// week, and leaves one a running older build still writes.
    func testCompleteScanRemovesOnlyIdleLegacyDirectories() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-usage-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let idle = root.appendingPathComponent("claude-usage-cache", isDirectory: true)
        let busy = root.appendingPathComponent("claude-usage-cache-v1b", isDirectory: true)
        for dir in [idle, busy] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.usage"))
        }
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)],
                             ofItemAtPath: idle.appendingPathComponent("a.usage").path)
        let current = root.appendingPathComponent("current", isDirectory: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        let store = ClaudeUsageCacheStore(directory: current, calendarTag: tag, legacyDirectories: [idle, busy])

        await store.prune(keeping: ["/tmp/a.jsonl"], now: now)

        XCTAssertFalse(fm.fileExists(atPath: idle.path))
        XCTAssertTrue(fm.fileExists(atPath: busy.path))
    }

    /// A finality byte the format does not define is damage, not a record.
    func testUnknownFinalityIsRejected() throws {
        let entry = ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(path: "/tmp/a.jsonl", size: 10, modifiedAt: 1, fileID: 1, volumeID: 1),
            parsedBytes: 10,
            value: ClaudeFileUsage(
                keyed: [KeyedUsage(key: DedupKey(hi: 1, lo: 2),
                                   usage: DayModelUsage(day: Date(timeIntervalSince1970: 0), model: "m", counts: TokenCounts()),
                                   finality: .partial)],
                unkeyed: [], boundaryDigest: Data()))
        let data = ClaudeUsageCacheStore.encode(entry, calendarTag: tag)
        // The keyed record is the last `keyedRecordLength` (101) bytes before
        // the unkeyed count and the checksum; its finality byte follows key
        // (16) and day (8).
        var body = Data(data.prefix(data.count - 32))
        let finalityOffset = body.count - 4 - ClaudeUsageCacheStore.keyedRecordLength + 24
        XCTAssertEqual(body[finalityOffset], UsageFinality.partial.rawValue)
        body[finalityOffset] = 9
        body.append(contentsOf: Array(SHA256Digest.of(body)))
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(body, calendarTag: tag)) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .truncated)
        }
    }

    /// A forged body with a valid checksum: the count guard, not the
    /// checksum, has to stop a record count the bytes cannot hold.
    func testForgedRecordCountCannotAllocate() throws {
        let entry = ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(path: "/tmp/a.jsonl", size: 10, modifiedAt: 1, fileID: 1, volumeID: 1),
            parsedBytes: 10, value: .empty)
        let data = ClaudeUsageCacheStore.encode(entry, calendarTag: tag)
        // Layout after the fixed head: ... parsedBytes i64, digest u8+n, models u32 (0),
        // attributeSets u16 (0), facts, four event counts u32 (0), keyed u32 (0), unkeyed u32 (0).
        let body = data.prefix(data.count - 32)
        let keyedCountOffset = body.count - 8
        var forged = Data(body)
        forged.replaceSubrange(keyedCountOffset..<keyedCountOffset + 4, with: [0xFF, 0xFF, 0xFF, 0x7F])
        forged.append(contentsOf: Array(SHA256Digest.of(forged)))
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(forged, calendarTag: tag)) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .truncated)
        }
    }

    /// A boundary past the file, or a negative one, would make a resume seek
    /// outside the file; such an entry is refused however well it checksums.
    func testImpossibleBoundaryIsRejected() throws {
        let entry = ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(path: "/tmp/a.jsonl", size: 10, modifiedAt: 1, fileID: 1, volumeID: 1),
            parsedBytes: 11, value: .empty)
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(
            ClaudeUsageCacheStore.encode(entry, calendarTag: tag), calendarTag: tag))
        let negative = ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(path: "/tmp/a.jsonl", size: 10, modifiedAt: 1, fileID: 1, volumeID: 1),
            parsedBytes: -1, value: .empty)
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(
            ClaudeUsageCacheStore.encode(negative, calendarTag: tag), calendarTag: tag))
    }

    func testStoreDropsAnEntryItCannotDecode() async throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClaudeUsageCacheStore(directory: dir, calendarTag: tag)
        let entry = sampleEntry()
        let saved = await store.save(entry, scan: 1)
        XCTAssertTrue(saved)
        let back = await store.entry(for: entry.fingerprint.path)
        XCTAssertEqual(back, entry)

        let url = dir.appendingPathComponent(ClaudeUsageCacheStore.entryFileName(for: entry.fingerprint.path))
        try Data(repeating: 0x41, count: 200).write(to: url)
        let dropped = await store.entry(for: entry.fingerprint.path)
        XCTAssertNil(dropped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an unreadable entry is removed, not retried forever")
        let stats = await store.statistics()
        XCTAssertEqual(stats.invalidEntries, 1)
    }
}

private enum SHA256Digest {
    static func of(_ data: Data) -> [UInt8] {
        Array(CryptoKit.SHA256.hash(data: data))
    }
}

