import Foundation
@testable import AgentMeter
import XCTest

final class QuotaTrendTrackerTests: XCTestCase {
    func testRunwayNeedsAtLeastTwoSamplesInCurrentResetEpoch() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 20, resetsAt: reset)
        let observations = [
            QuotaObservation(
                provider: .claude,
                windowID: "five_hour",
                remainingPercent: 80,
                observedAt: now,
                resetsAt: reset
            )
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .claude,
            window: window,
            observations: observations,
            now: now
        )

        XCTAssertEqual(runway.status, .insufficientData)
    }

    func testRunwayReportsSafeWhenDrainIsBelowResetBudget() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(10 * 3600)
        let window = QuotaWindow(id: "primary", label: "5-hour", usedPercent: 5, resetsAt: reset)
        let observations = [
            QuotaObservation(
                provider: .codex,
                windowID: "primary",
                remainingPercent: 100,
                observedAt: now.addingTimeInterval(-2 * 3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .codex,
                windowID: "primary",
                remainingPercent: 95,
                observedAt: now,
                resetsAt: reset
            )
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .codex,
            window: window,
            observations: observations,
            now: now
        )

        XCTAssertEqual(runway.status, .safe)
        XCTAssertEqual(runway.percentPerHour ?? -1, 2.5, accuracy: 0.001)
    }

    func testRunwayDoesNotWarnWhenDepletionIsAfterReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(10 * 3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 10, resetsAt: reset)
        let observations = [
            QuotaObservation(
                provider: .codex,
                windowID: "five_hour",
                remainingPercent: 98,
                observedAt: now.addingTimeInterval(-3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .codex,
                windowID: "five_hour",
                remainingPercent: 90,
                observedAt: now,
                resetsAt: reset
            )
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .codex,
            window: window,
            observations: observations,
            now: now
        )

        XCTAssertEqual(runway.status, .safe)
        XCTAssertGreaterThan(runway.estimatedDepletionAt ?? now, reset)
    }

    func testRunwayReportsAtRiskWhenDepletionPrecedesReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(10 * 3600)
        let window = QuotaWindow(id: "weekly", label: "Weekly", usedPercent: 50, resetsAt: reset)
        let observations = [
            QuotaObservation(
                provider: .claude,
                windowID: "weekly",
                remainingPercent: 100,
                observedAt: now.addingTimeInterval(-3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "weekly",
                remainingPercent: 50,
                observedAt: now,
                resetsAt: reset
            )
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .claude,
            window: window,
            observations: observations,
            now: now
        )

        XCTAssertEqual(runway.status, .atRisk)
        XCTAssertEqual(runway.estimatedDepletionAt, now.addingTimeInterval(3600))
    }

    func testLongWindowRunwayIsConstrainedByShortWindowHardLimit() {
        let now = Date(timeIntervalSince1970: 1_000)
        let shortReset = now.addingTimeInterval(4 * 3600)
        let longReset = now.addingTimeInterval(7 * 24 * 3600)
        let shortWindow = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 76, resetsAt: shortReset)
        let longWindow = QuotaWindow(id: "weekly", label: "7-day", usedPercent: 41, resetsAt: longReset)
        let observations = [
            QuotaObservation(
                provider: .codex,
                windowID: "five_hour",
                remainingPercent: 100,
                observedAt: now.addingTimeInterval(-4 * 3600),
                resetsAt: shortReset
            ),
            QuotaObservation(
                provider: .codex,
                windowID: "five_hour",
                remainingPercent: 24,
                observedAt: now,
                resetsAt: shortReset
            ),
            QuotaObservation(
                provider: .codex,
                windowID: "weekly",
                remainingPercent: 100,
                observedAt: now.addingTimeInterval(-10 * 3600),
                resetsAt: longReset
            ),
            QuotaObservation(
                provider: .codex,
                windowID: "weekly",
                remainingPercent: 59,
                observedAt: now,
                resetsAt: longReset
            )
        ]

        let unconstrained = QuotaTrendTracker.runway(
            provider: .codex,
            window: longWindow,
            observations: observations,
            now: now
        )
        let constrained = QuotaTrendTracker.runway(
            provider: .codex,
            window: longWindow,
            observations: observations,
            now: now,
            peerWindows: [shortWindow, longWindow]
        )

        XCTAssertEqual(unconstrained.status, .atRisk)
        XCTAssertEqual(constrained.status, .safe)
        XCTAssertNil(constrained.estimatedDepletionAt)
        XCTAssertEqual(constrained.message, "5-hour limit hits first")
    }

    func testRunwayDoesNotMixResetEpochs() {
        let now = Date(timeIntervalSince1970: 1_000)
        let oldReset = now.addingTimeInterval(3600)
        let newReset = now.addingTimeInterval(6 * 3600)
        let window = QuotaWindow(id: "primary", label: "5-hour", usedPercent: 10, resetsAt: newReset)
        let observations = [
            QuotaObservation(
                provider: .codex,
                windowID: "primary",
                remainingPercent: 5,
                observedAt: now.addingTimeInterval(-300),
                resetsAt: oldReset
            ),
            QuotaObservation(
                provider: .codex,
                windowID: "primary",
                remainingPercent: 90,
                observedAt: now,
                resetsAt: newReset
            )
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .codex,
            window: window,
            observations: observations,
            now: now
        )

        XCTAssertEqual(runway.status, .insufficientData)
    }

    func testRunwayIgnoresIncreaseInsideSameResetEpoch() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(6 * 3600)
        let window = QuotaWindow(id: "primary", label: "5-hour", usedPercent: 20, resetsAt: reset)
        let observations = [
            QuotaObservation(
                provider: .codex,
                windowID: "primary",
                remainingPercent: 100,
                observedAt: now.addingTimeInterval(-2 * 3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .codex,
                windowID: "primary",
                remainingPercent: 40,
                observedAt: now.addingTimeInterval(-3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .codex,
                windowID: "primary",
                remainingPercent: 80,
                observedAt: now,
                resetsAt: reset
            )
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .codex,
            window: window,
            observations: observations,
            now: now
        )

        XCTAssertEqual(runway.status, .steady)
        XCTAssertEqual(runway.percentPerHour, 0)
    }

    func testRecordIgnoresUnavailableQuota() {
        let now = Date(timeIntervalSince1970: 1_000)
        let existing = [
            QuotaObservation(
                provider: .codex,
                windowID: "primary",
                remainingPercent: 50,
                observedAt: now,
                resetsAt: nil
            )
        ]
        let state = ProviderState(
            provider: .claude,
            quota: .unavailable(.claude, note: "offline"),
            usage: .empty(.claude)
        )

        let result = QuotaTrendTracker.record(existing: existing, states: [state], at: now)

        XCTAssertEqual(result, existing)
    }
}
