import Foundation
@testable import AgentMeter
import XCTest

final class QuotaNotificationPolicyTests: XCTestCase {
    func testCriticalNotificationFiresOncePerWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = QuotaWindow(
            id: "five_hour",
            label: "5-hour",
            usedPercent: 95,
            resetsAt: now.addingTimeInterval(300)
        )
        var state = QuotaNotificationState()

        let first = QuotaNotificationPolicy.evaluate(
            provider: .claude,
            windows: [window],
            now: now,
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )
        let second = QuotaNotificationPolicy.evaluate(
            provider: .claude,
            windows: [window],
            now: now.addingTimeInterval(60),
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )

        XCTAssertEqual(first, [.critical(provider: .claude, window: window)])
        XCTAssertTrue(second.isEmpty)
    }

    func testRecoveryNotificationFiresAfterCriticalWindowReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let low = QuotaWindow(
            id: "five_hour",
            label: "5-hour",
            usedPercent: 95,
            resetsAt: now.addingTimeInterval(60)
        )
        let recovered = QuotaWindow(
            id: "five_hour",
            label: "5-hour",
            usedPercent: 5,
            resetsAt: now.addingTimeInterval(5 * 3600)
        )
        var state = QuotaNotificationState()

        _ = QuotaNotificationPolicy.evaluate(
            provider: .claude,
            windows: [low],
            now: now,
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )
        let events = QuotaNotificationPolicy.evaluate(
            provider: .claude,
            windows: [recovered],
            now: now.addingTimeInterval(120),
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )

        XCTAssertEqual(events, [.recovered(provider: .claude, window: recovered)])
    }

    func testNonCriticalResetDoesNotNotify() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 5,
            resetsAt: now.addingTimeInterval(3600)
        )
        var state = QuotaNotificationState()

        let events = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [window],
            now: now,
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testAlertsDisabledSuppressesCriticalAndRecoveryState() {
        let now = Date(timeIntervalSince1970: 1_000)
        let low = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 95,
            resetsAt: now.addingTimeInterval(60)
        )
        let recovered = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 5,
            resetsAt: now.addingTimeInterval(5 * 3600)
        )
        var state = QuotaNotificationState()

        let lowEvents = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [low],
            now: now,
            threshold: 10,
            alertsEnabled: false,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )
        let recoveryEvents = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [recovered],
            now: now.addingTimeInterval(120),
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )

        XCTAssertTrue(lowEvents.isEmpty)
        XCTAssertTrue(recoveryEvents.isEmpty)
    }

    func testAlertsDisabledClearsExistingCriticalState() {
        let now = Date(timeIntervalSince1970: 1_000)
        let low = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 95,
            resetsAt: now.addingTimeInterval(60)
        )
        let recovered = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 5,
            resetsAt: now.addingTimeInterval(5 * 3600)
        )
        var state = QuotaNotificationState()

        _ = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [low],
            now: now,
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )
        let disabledEvents = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [recovered],
            now: now.addingTimeInterval(120),
            threshold: 10,
            alertsEnabled: false,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )
        let reenabledEvents = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [recovered],
            now: now.addingTimeInterval(180),
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )

        XCTAssertTrue(disabledEvents.isEmpty)
        XCTAssertTrue(reenabledEvents.isEmpty)
        XCTAssertTrue(state.criticalNotified.isEmpty)
    }

    func testRecoveryToggleSuppressesRecoveryButRearmsCritical() {
        let now = Date(timeIntervalSince1970: 1_000)
        let low = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 95,
            resetsAt: now.addingTimeInterval(60)
        )
        let recovered = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 5,
            resetsAt: now.addingTimeInterval(5 * 3600)
        )
        var state = QuotaNotificationState()

        _ = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [low],
            now: now,
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )
        let events = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [recovered],
            now: now.addingTimeInterval(120),
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: false,
            canDeliver: true,
            state: &state
        )

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(state.criticalNotified.isEmpty)
    }

    func testCriticalNotificationBodyUsesExpiresForOneTimeCredit() {
        let window = QuotaWindow(
            id: "cinder_cove",
            label: "Included credit",
            usedPercent: 95,
            resetsAt: Date().addingTimeInterval(3600),
            isOneTimeCredit: true
        )

        let body = NotificationManager.criticalBody(for: window)

        XCTAssertTrue(body.contains("expires"))
        XCTAssertFalse(body.contains("resets"))
    }

    func testRecoveredNotificationBodyUsesExpiresForOneTimeCredit() {
        let window = QuotaWindow(
            id: "cinder_cove",
            label: "Included credit",
            usedPercent: 5,
            resetsAt: Date().addingTimeInterval(3600),
            isOneTimeCredit: true
        )

        let body = NotificationManager.recoveredBody(for: window)

        XCTAssertTrue(body.contains("expires"))
        XCTAssertFalse(body.contains("next reset"))
    }
}
