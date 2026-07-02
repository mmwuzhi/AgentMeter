import Foundation
@testable import AgentMeter
import XCTest

final class CodexQuotaParsingTests: XCTestCase {
    func testAppServerQuotaPreservesResetCredits() throws {
        let snapshot = try AppServerSession.parseQuota([
            "rateLimitResetCredits": [
                "availableCount": 3
            ],
            "rateLimits": [
                "planType": "plus",
                "primary": [
                    "usedPercent": 15.0,
                    "windowDurationMins": 300.0,
                    "resetsAt": 1_782_968_577.0
                ],
                "secondary": [
                    "usedPercent": 52.0,
                    "windowDurationMins": 10_080.0,
                    "resetsAt": 1_783_436_871.0
                ]
            ]
        ])

        XCTAssertEqual(snapshot.resetCreditsAvailable, 3)
        XCTAssertNil(snapshot.resetCreditsExpiresAt)
        XCTAssertEqual(snapshot.resetCreditsCountText, "3 resets available")
    }

    func testAppServerQuotaPreservesResetCreditsExpiryWhenExposed() throws {
        let snapshot = try AppServerSession.parseQuota([
            "rateLimitResetCredits": [
                "availableCount": 3,
                "expiresAt": 1_783_436_871.0
            ],
            "rateLimits": [
                "planType": "plus",
                "primary": [
                    "usedPercent": 15.0,
                    "windowDurationMins": 300.0,
                    "resetsAt": 1_782_968_577.0
                ]
            ]
        ])

        XCTAssertEqual(snapshot.resetCreditsExpiresAt, Date(timeIntervalSince1970: 1_783_436_871.0))
    }

    func testResetCreditsSummaryUsesSingular() {
        let snapshot = QuotaSnapshot(
            provider: .codex,
            windows: [],
            source: .appServer,
            planType: "plus",
            resetCreditsAvailable: 1,
            fetchedAt: Date(),
            note: nil
        )

        XCTAssertEqual(snapshot.resetCreditsCountText, "1 reset available")
    }

    func testResetCreditsSummaryIsCodexOnly() {
        let snapshot = QuotaSnapshot(
            provider: .claude,
            windows: [],
            source: .oauth,
            planType: "pro",
            resetCreditsAvailable: 3,
            fetchedAt: Date(),
            note: nil
        )

        XCTAssertNil(snapshot.resetCreditsCountText)
    }
}
