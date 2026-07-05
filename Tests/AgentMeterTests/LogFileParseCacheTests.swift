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
}
