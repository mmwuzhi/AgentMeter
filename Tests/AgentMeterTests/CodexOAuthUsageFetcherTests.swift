import Foundation
@testable import AgentMeter
import XCTest

final class CodexOAuthUsageFetcherTests: XCTestCase {
    func testParsesPrimaryAndSecondaryWindows() throws {
        let resetAt = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let snapshot = try XCTUnwrap(CodexOAuthUsageFetcher.parseQuota([
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": ["used_percent": 42, "reset_at": resetAt, "limit_window_seconds": 5 * 3_600],
                "secondary_window": ["used_percent": 10, "reset_at": resetAt, "limit_window_seconds": 7 * 86_400]
            ]
        ]))

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.source, .oauth)
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "primary" })?.usedPercent, 42)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "secondary" })?.usedPercent, 10)
    }

    func testParsesUsedPercentAndResetAtAsDouble() throws {
        let resetAt = Date().addingTimeInterval(1_800).timeIntervalSince1970
        let snapshot = try XCTUnwrap(CodexOAuthUsageFetcher.parseQuota([
            "rate_limit": [
                "primary_window": ["used_percent": 55.5, "reset_at": resetAt, "limit_window_seconds": 18_000.0]
            ]
        ]))

        XCTAssertEqual(snapshot.windows.first?.usedPercent, 55.5)
        XCTAssertEqual(snapshot.windows.first?.resetsAt?.timeIntervalSince1970 ?? 0, resetAt, accuracy: 0.01)
    }

    func testMissingSecondaryWindowStillReturnsPrimaryOnly() throws {
        let snapshot = try XCTUnwrap(CodexOAuthUsageFetcher.parseQuota([
            "rate_limit": [
                "primary_window": ["used_percent": 5, "reset_at": 0, "limit_window_seconds": 300]
            ]
        ]))

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.id, "primary")
    }

    func testMissingRateLimitKeyReturnsNil() {
        XCTAssertNil(CodexOAuthUsageFetcher.parseQuota(["plan_type": "free"]))
    }

    func testRateLimitPresentButNoUsableWindowsReturnsNil() {
        XCTAssertNil(CodexOAuthUsageFetcher.parseQuota(["rate_limit": [String: Any]()]))
    }

    func testLimitWindowSecondsConvertsToHourLabel() throws {
        let snapshot = try XCTUnwrap(CodexOAuthUsageFetcher.parseQuota([
            "rate_limit": [
                "primary_window": ["used_percent": 0, "reset_at": 0, "limit_window_seconds": 5 * 3_600]
            ]
        ]))

        XCTAssertEqual(snapshot.windows.first?.label, "5-hour")
    }
}
