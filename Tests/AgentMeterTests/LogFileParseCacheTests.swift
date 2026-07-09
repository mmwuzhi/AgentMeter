import Foundation
@testable import AgentMeter
import XCTest

final class LogFileParseCacheTests: XCTestCase {
    func testChangedFingerprintInvalidatesCacheForSamePath() async {
        let first = LogFileFingerprint(path: "/tmp/session.jsonl", size: 4, modifiedAt: 1)
        let cache = LogFileParseCache<[String]>()
        await cache.store(["cached"], for: first)
        let cached = await cache.value(for: first)
        XCTAssertEqual(cached, ["cached"])

        let second = LogFileFingerprint(path: first.path, size: 8, modifiedAt: first.modifiedAt)

        XCTAssertNotEqual(first, second)
        let stale = await cache.value(for: second)
        XCTAssertNil(stale)
    }

    func testExactFingerprintDoesNotReturnCacheWhenTrailingBytesWereNotCached() async {
        let fingerprint = LogFileFingerprint(
            path: "/tmp/session.jsonl",
            size: 8,
            modifiedAt: 1,
            fileID: 100,
            volumeID: 200
        )
        let cache = LogFileParseCache<[String]>()
        await cache.store(["line-terminated"], for: fingerprint, parsedBytes: 4)

        let cached = await cache.value(for: fingerprint)

        XCTAssertNil(cached, "uncommitted trailing bytes must be re-read and folded into the display value")
    }

    func testIncrementalBaseRequiresStableFileIdentity() async {
        let first = LogFileFingerprint(
            path: "/tmp/session.jsonl",
            size: 4,
            modifiedAt: 1,
            fileID: 100,
            volumeID: 200
        )
        let cache = LogFileParseCache<[String]>()
        await cache.store(["cached"], for: first, parsedBytes: 4)

        let sameFileGrew = LogFileFingerprint(
            path: first.path,
            size: 8,
            modifiedAt: 2,
            fileID: 100,
            volumeID: 200
        )
        let base = await cache.incrementalBase(for: sameFileGrew)
        XCTAssertEqual(base?.value, ["cached"])
        XCTAssertEqual(base?.parsedBytes, 4)

        let replacedAtSamePath = LogFileFingerprint(
            path: first.path,
            size: 12,
            modifiedAt: 3,
            fileID: 101,
            volumeID: 200
        )
        let unsafeBase = await cache.incrementalBase(for: replacedAtSamePath)
        XCTAssertNil(unsafeBase, "same-path file replacement must re-parse from the top")
    }

    func testIncrementalBaseRejectsFingerprintsWithoutStableIdentity() async {
        let first = LogFileFingerprint(path: "/tmp/session.jsonl", size: 4, modifiedAt: 1)
        let cache = LogFileParseCache<[String]>()
        await cache.store(["cached"], for: first, parsedBytes: 4)

        let grew = LogFileFingerprint(path: first.path, size: 8, modifiedAt: 2)
        let base = await cache.incrementalBase(for: grew)

        XCTAssertNil(base)
    }
}
