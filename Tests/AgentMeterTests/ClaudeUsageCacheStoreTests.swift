import CryptoKit
import Foundation
@testable import AgentMeter
import XCTest

/// The entry codec on its own: a round trip is exact, and nothing a damaged
/// or forged file can contain reaches an array allocation or a crash — every
/// such input throws and is treated as no entry.
final class ClaudeUsageCacheStoreTests: XCTestCase {
    private let tag = "gregorian|Asia/Tokyo"

    private func sampleEntry(identity: Bool = true) -> ClaudeUsageCacheStore.Entry {
        let day = Calendar.current.startOfDay(for: Date())
        let keyed = (0..<50).map { i in
            KeyedUsage(
                key: DedupKey(messageID: "msg_\(i)", requestID: "req_\(i)"),
                usage: DayModelUsage(
                    day: day.addingTimeInterval(Double(i % 3) * -86_400),
                    model: ["claude-sonnet-4-5-20250929", "claude-opus-4-1-20250805"][i % 2],
                    counts: TokenCounts(input: i, output: i * 2, cacheWrite5m: i * 3, cacheWrite1h: i * 4, cacheRead: i * 5)))
        }
        let unkeyed = [DayModelUsage(day: day, model: "default", counts: TokenCounts(input: 1, output: 2, cacheWrite5m: 3, cacheWrite1h: 4, cacheRead: 5))]
        return ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(
                path: "/tmp/projects/-Users-x/äöü session.jsonl", size: 123_456, modifiedAt: 1_760_000_000.123456,
                fileID: identity ? 42 : nil, volumeID: identity ? 7 : nil),
            parsedBytes: 123_000,
            value: ClaudeFileUsage(keyed: keyed, unkeyed: unkeyed,
                                   boundaryDigest: ClaudeUsageCacheStore.boundaryDigest(of: Data("tail".utf8))))
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
        data.replaceSubrange(4..<8, with: [0x02, 0, 0, 0])
        XCTAssertThrowsError(try ClaudeUsageCacheStore.decode(data, calendarTag: tag)) { error in
            XCTAssertEqual(error as? ClaudeUsageCacheStore.DecodeError, .version(2))
        }
    }

    /// A forged body with a valid checksum: the count guard, not the
    /// checksum, has to stop a record count the bytes cannot hold.
    func testForgedRecordCountCannotAllocate() throws {
        let entry = ClaudeUsageCacheStore.Entry(
            fingerprint: LogFileFingerprint(path: "/tmp/a.jsonl", size: 10, modifiedAt: 1, fileID: 1, volumeID: 1),
            parsedBytes: 10, value: .empty)
        let data = ClaudeUsageCacheStore.encode(entry, calendarTag: tag)
        // Layout after the fixed head: ... parsedBytes i64, digest u8+16, models u32 (0), keyed u32 (0), unkeyed u32 (0).
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

