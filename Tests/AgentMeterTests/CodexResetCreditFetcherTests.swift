import Foundation
@testable import AgentMeter
import XCTest

final class CodexResetCreditFetcherTests: XCTestCase {
    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func testParsesBareArrayWithEpochDoubleFields() throws {
        let expires = Date().addingTimeInterval(86_400)
        let granted = Date().addingTimeInterval(-86_400)
        let credits = try XCTUnwrap(CodexResetCreditFetcher.parseCredits([
            ["id": "abc", "expires_at": expires.timeIntervalSince1970, "granted_at": granted.timeIntervalSince1970]
        ]))

        XCTAssertEqual(credits.count, 1)
        XCTAssertEqual(credits.first?.id, "abc")
        XCTAssertEqual(credits.first?.expiresAt.timeIntervalSince1970 ?? 0, expires.timeIntervalSince1970, accuracy: 0.01)
    }

    func testParsesWrappedUnderCreditsKey() throws {
        let expires = Date().addingTimeInterval(3_600)
        let credits = try XCTUnwrap(CodexResetCreditFetcher.parseCredits([
            "credits": [["id": "x", "expiresAt": expires.timeIntervalSince1970]]
        ]))

        XCTAssertEqual(credits.count, 1)
    }

    func testParsesWrappedUnderDataKeyWithISOStrings() throws {
        let expires = Date().addingTimeInterval(7_200)
        let granted = Date().addingTimeInterval(-7_200)
        let credits = try XCTUnwrap(CodexResetCreditFetcher.parseCredits([
            "data": [["id": "y", "expiration_date": iso(expires), "created_at": iso(granted)]]
        ]))

        XCTAssertEqual(credits.count, 1)
        XCTAssertEqual(credits.first?.expiresAt.timeIntervalSince1970 ?? 0, expires.timeIntervalSince1970, accuracy: 1.0)
    }

    func testDropsUsedAndExpiredStatusEntriesButKeepsAvailable() throws {
        let future = Date().addingTimeInterval(1_000)
        let credits = try XCTUnwrap(CodexResetCreditFetcher.parseCredits([
            ["id": "used", "status": "used", "expires_at": future.timeIntervalSince1970],
            ["id": "redeemed", "status": "Redeemed", "expires_at": future.timeIntervalSince1970],
            ["id": "available", "status": "available", "expires_at": future.timeIntervalSince1970]
        ]))

        XCTAssertEqual(credits.map(\.id), ["available"])
    }

    func testDropsEntriesWithExpiresAtInThePast() throws {
        let past = Date().addingTimeInterval(-1_000)
        let future = Date().addingTimeInterval(1_000)
        let credits = try XCTUnwrap(CodexResetCreditFetcher.parseCredits([
            ["id": "stale", "expires_at": past.timeIntervalSince1970],
            ["id": "fresh", "expires_at": future.timeIntervalSince1970]
        ]))

        XCTAssertEqual(credits.map(\.id), ["fresh"])
    }

    func testEmptyArrayReturnsEmptyNotNil() {
        let credits = CodexResetCreditFetcher.parseCredits([[String: Any]]())
        XCTAssertEqual(credits, [])
    }

    func testUnrecognizableWrapperReturnsNil() {
        XCTAssertNil(CodexResetCreditFetcher.parseCredits(["status": "ok"] as [String: Any]))
    }

    func testEntriesMissingExpiryAreDroppedWithoutFailingWholeBatch() throws {
        let future = Date().addingTimeInterval(1_000)
        let credits = try XCTUnwrap(CodexResetCreditFetcher.parseCredits([
            ["id": "no-expiry", "status": "available"],
            ["id": "has-expiry", "expires_at": future.timeIntervalSince1970]
        ]))

        XCTAssertEqual(credits.map(\.id), ["has-expiry"])
    }

    func testAllEntriesUnparsableReturnsNil() {
        XCTAssertNil(CodexResetCreditFetcher.parseCredits([
            ["id": "no-expiry-1"],
            ["id": "no-expiry-2"]
        ]))
    }

    func testResultIsCappedAtMaxStoredCredits() throws {
        let now = Date()
        let entries: [[String: Any]] = (0..<30).map { i in
            ["id": "credit-\(i)", "expires_at": now.addingTimeInterval(TimeInterval(i + 1) * 3_600).timeIntervalSince1970]
        }
        let credits = try XCTUnwrap(CodexResetCreditFetcher.parseCredits(entries))

        XCTAssertEqual(credits.count, CodexResetCreditTracker.maxStoredCredits)
        // Keeps the soonest-expiring entries, not an arbitrary prefix of the input.
        XCTAssertEqual(credits.first?.id, "credit-0")
    }
}
