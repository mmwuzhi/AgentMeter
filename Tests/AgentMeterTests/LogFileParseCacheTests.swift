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

    /// The same length under a newer modification date is a rewrite, not an
    /// append: resuming would read nothing and keep the old contents.
    func testSameSizeUnderANewerDateIsNotResumed() async {
        let first = LogFileFingerprint(path: "/tmp/session.jsonl", size: 8, modifiedAt: 1, fileID: 100, volumeID: 200)
        let cache = LogFileParseCache<[String]>()
        await cache.store(["cached"], for: first, parsedBytes: 8)

        let rewritten = LogFileFingerprint(path: first.path, size: 8, modifiedAt: 2, fileID: 100, volumeID: 200)

        let exact = await cache.value(for: rewritten)
        XCTAssertNil(exact)
        let base = await cache.incrementalBase(for: rewritten)
        XCTAssertNil(base, "nothing was appended, so there is nothing to resume from")
    }

    /// A file dated earlier than the cached read was restored or replaced,
    /// not appended to.
    func testOlderModificationDateIsNotResumed() async {
        let first = LogFileFingerprint(path: "/tmp/session.jsonl", size: 4, modifiedAt: 5, fileID: 100, volumeID: 200)
        let cache = LogFileParseCache<[String]>()
        await cache.store(["cached"], for: first, parsedBytes: 4)

        let restored = LogFileFingerprint(path: first.path, size: 8, modifiedAt: 3, fileID: 100, volumeID: 200)

        let base = await cache.incrementalBase(for: restored)
        XCTAssertNil(base)
    }

    /// A refresh stalled past 30 s lets another start beside it; the scan that
    /// started later fingerprinted every file later, so what it stores must
    /// stand when the earlier one finally finishes.
    func testAnEarlierScanDoesNotOverwriteALaterScansEntry() async {
        let cache = LogFileParseCache<[String]>()
        let earlier = await cache.beginScan()
        let later = await cache.beginScan()
        let seenByEarlier = LogFileFingerprint(path: "/tmp/session.jsonl", size: 4, modifiedAt: 1, fileID: 100, volumeID: 200)
        let seenByLater = LogFileFingerprint(path: seenByEarlier.path, size: 8, modifiedAt: 2, fileID: 100, volumeID: 200)

        await cache.store(["later"], for: seenByLater, parsedBytes: 8, scan: later)
        await cache.store(["earlier"], for: seenByEarlier, parsedBytes: 4, scan: earlier)

        let kept = await cache.value(for: seenByLater)
        XCTAssertEqual(kept, ["later"])
        let overwritten = await cache.value(for: seenByEarlier)
        XCTAssertNil(overwritten)
    }

    /// Callers that do not order their scans keep the old last-writer-wins.
    func testUnorderedStoresStillReplace() async {
        let cache = LogFileParseCache<[String]>()
        let first = LogFileFingerprint(path: "/tmp/session.jsonl", size: 4, modifiedAt: 1)
        let second = LogFileFingerprint(path: first.path, size: 8, modifiedAt: 2)
        await cache.store(["first"], for: first)
        await cache.store(["second"], for: second)

        let kept = await cache.value(for: second)
        XCTAssertEqual(kept, ["second"])
    }
}
