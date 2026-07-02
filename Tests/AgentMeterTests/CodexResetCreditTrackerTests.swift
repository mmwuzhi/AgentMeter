import Foundation
@testable import AgentMeter
import XCTest

final class CodexResetCreditTrackerTests: XCTestCase {
    func testFirstObservationDoesNotInventExpiryForExistingCredits() {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let quota = QuotaSnapshot(
            provider: .codex,
            windows: [],
            source: .appServer,
            planType: "plus",
            resetCreditsAvailable: 3,
            fetchedAt: now,
            note: nil
        )

        let state = CodexResetCreditTracker.reconcile(
            existing: CodexResetCreditState(),
            quota: quota,
            at: now
        )

        XCTAssertEqual(state.lastObservedCount, 3)
        XCTAssertTrue(state.credits.isEmpty)
        XCTAssertNil(state.nearestExpiry)
    }

    func testIncreaseCreatesInferredThirtyDayExpiry() {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let quota = QuotaSnapshot(
            provider: .codex,
            windows: [],
            source: .appServer,
            planType: "plus",
            resetCreditsAvailable: 3,
            fetchedAt: now,
            note: nil
        )

        let state = CodexResetCreditTracker.reconcile(
            existing: CodexResetCreditState(lastObservedCount: 2),
            quota: quota,
            at: now
        )

        XCTAssertEqual(state.lastObservedCount, 3)
        XCTAssertEqual(state.credits.count, 1)
        XCTAssertEqual(state.nearestExpiry, now.addingTimeInterval(CodexResetCreditTracker.inferredLifetime))
    }

    func testDecreaseDropsEarliestKnownExpiry() {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let early = CodexResetCreditExpiry(
            id: "early",
            grantedAt: now,
            expiresAt: now.addingTimeInterval(10)
        )
        let late = CodexResetCreditExpiry(
            id: "late",
            grantedAt: now,
            expiresAt: now.addingTimeInterval(20)
        )
        let quota = QuotaSnapshot(
            provider: .codex,
            windows: [],
            source: .appServer,
            planType: "plus",
            resetCreditsAvailable: 1,
            fetchedAt: now,
            note: nil
        )

        let state = CodexResetCreditTracker.reconcile(
            existing: CodexResetCreditState(lastObservedCount: 2, credits: [early, late]),
            quota: quota,
            at: now
        )

        XCTAssertEqual(state.credits, [late])
    }

    func testExpiredKnownCreditDoesNotDoubleCountDecrease() {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let expired = CodexResetCreditExpiry(
            id: "expired",
            grantedAt: now.addingTimeInterval(-CodexResetCreditTracker.inferredLifetime),
            expiresAt: now.addingTimeInterval(-1)
        )
        let stillValid = CodexResetCreditExpiry(
            id: "valid",
            grantedAt: now,
            expiresAt: now.addingTimeInterval(20)
        )
        let quota = QuotaSnapshot(
            provider: .codex,
            windows: [],
            source: .appServer,
            planType: "plus",
            resetCreditsAvailable: 1,
            fetchedAt: now,
            note: nil
        )

        let state = CodexResetCreditTracker.reconcile(
            existing: CodexResetCreditState(lastObservedCount: 2, credits: [expired, stillValid]),
            quota: quota,
            at: now
        )

        XCTAssertEqual(state.credits, [stillValid])
    }
}
