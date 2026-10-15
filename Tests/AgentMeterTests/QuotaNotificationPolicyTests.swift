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

    func testResetTimeDriftBeforeResetDoesNotRecoverOrRearmCritical() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(5 * 3600)
        let low = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 100,
            resetsAt: reset
        )
        let transientHigh = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 5,
            resetsAt: reset.addingTimeInterval(3 * 60)
        )
        let lowAgain = QuotaWindow(
            id: "primary",
            label: "5-hour",
            usedPercent: 100,
            resetsAt: reset
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
        let recoveryEvents = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [transientHigh],
            now: now.addingTimeInterval(60),
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )
        let repeatedCriticalEvents = QuotaNotificationPolicy.evaluate(
            provider: .codex,
            windows: [lowAgain],
            now: now.addingTimeInterval(120),
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: true,
            canDeliver: true,
            state: &state
        )

        XCTAssertTrue(recoveryEvents.isEmpty)
        XCTAssertTrue(repeatedCriticalEvents.isEmpty)
        XCTAssertFalse(state.criticalNotified.isEmpty)
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

    // MARK: Reset epochs

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func fiveHour(used: Double, resetsAt: Date?) -> QuotaWindow {
        QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: used, resetsAt: resetsAt, cycle: 5 * 3600)
    }

    private func weekly(used: Double, resetsAt: Date?) -> QuotaWindow {
        QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: used, resetsAt: resetsAt, cycle: 7 * 86400)
    }

    private func evaluate(
        _ windows: [QuotaWindow],
        provider: Provider = .claude,
        at now: Date,
        recoveryEnabled: Bool = true,
        state: inout QuotaNotificationState
    ) -> [QuotaNotificationEvent] {
        QuotaNotificationPolicy.evaluate(
            provider: provider,
            windows: windows,
            now: now,
            threshold: 10,
            alertsEnabled: true,
            recoveryEnabled: recoveryEnabled,
            canDeliver: true,
            state: &state
        )
    }

    /// A Claude limit reset spent mid-week refills the window days before
    /// the epoch the alert was posted for would have ended.
    func testLimitResetBeforeWindowEndRecoversAndRearmsCritical() {
        let oldReset = start.addingTimeInterval(3 * 86400)
        let resetSpentAt = start.addingTimeInterval(3600)
        let newReset = resetSpentAt.addingTimeInterval(7 * 86400)
        let low = weekly(used: 95, resetsAt: oldReset)
        let refilled = weekly(used: 0, resetsAt: newReset)
        let lowAgain = weekly(used: 92, resetsAt: newReset)
        var state = QuotaNotificationState()

        let critical = evaluate([low], at: start, state: &state)
        let recovered = evaluate([refilled], at: resetSpentAt.addingTimeInterval(60), state: &state)
        let criticalAgain = evaluate([lowAgain], at: start.addingTimeInterval(2 * 86400), state: &state)
        let stillLow = evaluate(
            [weekly(used: 97, resetsAt: newReset)], at: start.addingTimeInterval(2 * 86400 + 60), state: &state)

        XCTAssertEqual(critical, [.critical(provider: .claude, window: low)])
        XCTAssertEqual(recovered, [.recovered(provider: .claude, window: refilled)])
        XCTAssertEqual(criticalAgain, [.critical(provider: .claude, window: lowAgain)])
        XCTAssertTrue(stillLow.isEmpty)
    }

    func testLimitResetWithRecoveryNotificationsOffStillRearmsCritical() {
        let oldReset = start.addingTimeInterval(3 * 86400)
        let newReset = start.addingTimeInterval(3600 + 7 * 86400)
        let lowAgain = weekly(used: 92, resetsAt: newReset)
        var state = QuotaNotificationState()

        _ = evaluate([weekly(used: 95, resetsAt: oldReset)], at: start, recoveryEnabled: false, state: &state)
        let recovered = evaluate(
            [weekly(used: 0, resetsAt: newReset)], at: start.addingTimeInterval(3600),
            recoveryEnabled: false, state: &state)
        let criticalAgain = evaluate([lowAgain], at: start.addingTimeInterval(86400), recoveryEnabled: false, state: &state)

        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(criticalAgain, [.critical(provider: .claude, window: lowAgain)])
    }

    /// The one redemption on record (2026-10-15) moved Codex's weekly reset
    /// from five days out to the moment of redemption plus seven days.
    func testCodexResetCreditBeforeWindowEndRecovers() {
        let redeemedAt = start.addingTimeInterval(3600)
        let low = QuotaWindow(
            id: "secondary", label: "Weekly", usedPercent: 96, resetsAt: start.addingTimeInterval(5 * 86400))
        let refilled = QuotaWindow(
            id: "secondary", label: "Weekly", usedPercent: 0, resetsAt: redeemedAt.addingTimeInterval(7 * 86400))
        var state = QuotaNotificationState()

        _ = evaluate([low], provider: .codex, at: start, state: &state)
        let events = evaluate([refilled], provider: .codex, at: redeemedAt.addingTimeInterval(300), state: &state)

        XCTAssertEqual(events, [.recovered(provider: .codex, window: refilled)])
    }

    /// No reading above the threshold has to land between two epochs: the
    /// Mac can sleep through a reset, and the next epoch can already be low.
    func testCriticalInLaterEpochNotifiesWithoutAReadingAboveThresholdBetween() {
        let firstReset = start.addingTimeInterval(3600)
        let afterNaturalReset = fiveHour(used: 93, resetsAt: start.addingTimeInterval(4 * 3600))
        var naturalState = QuotaNotificationState()
        _ = evaluate([fiveHour(used: 95, resetsAt: firstReset)], at: start, state: &naturalState)
        let natural = evaluate([afterNaturalReset], at: start.addingTimeInterval(2 * 3600), state: &naturalState)

        let afterLimitReset = weekly(used: 91, resetsAt: start.addingTimeInterval(7 * 86400))
        var limitResetState = QuotaNotificationState()
        _ = evaluate([weekly(used: 95, resetsAt: start.addingTimeInterval(3 * 86400))], at: start, state: &limitResetState)
        let limitReset = evaluate([afterLimitReset], at: start.addingTimeInterval(86400), state: &limitResetState)

        XCTAssertEqual(natural, [.critical(provider: .claude, window: afterNaturalReset)])
        XCTAssertEqual(limitReset, [.critical(provider: .claude, window: afterLimitReset)])
    }

    func testCriticalReadingWithResetDriftWithinToleranceDoesNotRenotify() {
        let reset = start.addingTimeInterval(5 * 3600)
        var state = QuotaNotificationState()

        _ = evaluate([fiveHour(used: 100, resetsAt: reset)], provider: .codex, at: start, state: &state)
        let events = evaluate(
            [fiveHour(used: 100, resetsAt: reset.addingTimeInterval(3 * 60))], provider: .codex,
            at: start.addingTimeInterval(60), state: &state)

        XCTAssertTrue(events.isEmpty)
    }

    /// Drift within tolerance stays one epoch after the alerted reset has
    /// passed too, as long as the reading's own reset is still ahead.
    func testResetDriftAfterAlertedResetPassedDoesNotRenotify() {
        let reset = start.addingTimeInterval(5 * 3600)
        let refilled = fiveHour(used: 0, resetsAt: reset.addingTimeInterval(180 + 5 * 3600))
        var state = QuotaNotificationState()

        _ = evaluate([fiveHour(used: 100, resetsAt: reset)], provider: .codex, at: start, state: &state)
        let drifted = evaluate(
            [fiveHour(used: 100, resetsAt: reset.addingTimeInterval(180))], provider: .codex,
            at: reset.addingTimeInterval(60), state: &state)
        let recovered = evaluate([refilled], provider: .codex, at: reset.addingTimeInterval(240), state: &state)

        XCTAssertTrue(drifted.isEmpty)
        XCTAssertEqual(recovered, [.recovered(provider: .codex, window: refilled)])
    }

    /// Offline after a sleep past the reset, the `claude /usage` scrape can
    /// echo the cached level of the epoch that ended, with no reset time.
    func testLowReadingWithoutResetAfterAlertedResetDoesNotRenotify() {
        let reset = start.addingTimeInterval(2 * 3600)
        let live = fiveHour(used: 3, resetsAt: reset.addingTimeInterval(5 * 3600))
        var state = QuotaNotificationState()

        _ = evaluate([fiveHour(used: 95, resetsAt: reset)], at: start, state: &state)
        let scraped = evaluate([fiveHour(used: 95, resetsAt: nil)], at: reset.addingTimeInterval(600), state: &state)
        let recovered = evaluate([live], at: reset.addingTimeInterval(900), state: &state)

        XCTAssertTrue(scraped.isEmpty)
        XCTAssertEqual(recovered, [.recovered(provider: .claude, window: live)])
    }

    /// Claude drops `resets_at` mid-epoch and later brings the same one back
    /// for the same window. A missing reset time leaves the epoch unchanged.
    func testMissingResetTimeMidEpochDoesNotRecoverOrRenotify() {
        let reset = start.addingTimeInterval(3 * 86400)
        var state = QuotaNotificationState()

        _ = evaluate([weekly(used: 95, resetsAt: reset)], at: start, state: &state)
        let aboveWithoutReset = evaluate([weekly(used: 0, resetsAt: nil)], at: start.addingTimeInterval(60), state: &state)
        let lowWithoutReset = evaluate([weekly(used: 96, resetsAt: nil)], at: start.addingTimeInterval(120), state: &state)
        let sameResetAgain = evaluate([weekly(used: 96, resetsAt: reset)], at: start.addingTimeInterval(180), state: &state)

        XCTAssertTrue(aboveWithoutReset.isEmpty)
        XCTAssertTrue(lowWithoutReset.isEmpty)
        XCTAssertTrue(sameResetAgain.isEmpty)
    }

    /// A crossing read without a reset time (the `claude /usage` scrape never
    /// has one) used to leave the window disarmed until relaunch.
    func testCriticalWithoutResetTimeRecoversOnceAboveThreshold() {
        let refilled = fiveHour(used: 5, resetsAt: nil)
        let lowAgain = fiveHour(used: 95, resetsAt: nil)
        var state = QuotaNotificationState()

        let critical = evaluate([fiveHour(used: 95, resetsAt: nil)], at: start, state: &state)
        let recovered = evaluate([refilled], at: start.addingTimeInterval(3600), state: &state)
        let criticalAgain = evaluate([lowAgain], at: start.addingTimeInterval(2 * 3600), state: &state)

        XCTAssertEqual(critical.count, 1)
        XCTAssertEqual(recovered, [.recovered(provider: .claude, window: refilled)])
        XCTAssertEqual(criticalAgain, [.critical(provider: .claude, window: lowAgain)])
    }

    func testCriticalWithoutResetTimeAdoptsTheFirstOneSeen() {
        let reset = start.addingTimeInterval(3600)
        var state = QuotaNotificationState()

        _ = evaluate([fiveHour(used: 95, resetsAt: nil)], at: start, state: &state)
        let adopted = evaluate([fiveHour(used: 96, resetsAt: reset)], at: start.addingTimeInterval(60), state: &state)
        let drift = evaluate(
            [fiveHour(used: 5, resetsAt: reset.addingTimeInterval(60))], at: start.addingTimeInterval(120), state: &state)

        XCTAssertTrue(adopted.isEmpty)
        XCTAssertTrue(drift.isEmpty)
        XCTAssertEqual(state.criticalResetAt["claude:five_hour"], reset)
    }

    /// Notifications have one level: a rise from critical into the warn band
    /// is a recovery only in a later epoch.
    func testRiseIntoWarnBandRecoversOnlyInALaterEpoch() {
        let oldReset = start.addingTimeInterval(3 * 86400)
        let newReset = start.addingTimeInterval(3600 + 7 * 86400)
        let warnAfterReset = weekly(used: 80, resetsAt: newReset)
        let lowAgain = weekly(used: 91, resetsAt: newReset)
        var state = QuotaNotificationState()

        _ = evaluate([weekly(used: 95, resetsAt: oldReset)], at: start, state: &state)
        let sameEpoch = evaluate([weekly(used: 80, resetsAt: oldReset)], at: start.addingTimeInterval(60), state: &state)
        let laterEpoch = evaluate([warnAfterReset], at: start.addingTimeInterval(2 * 3600), state: &state)
        let criticalAgain = evaluate([lowAgain], at: start.addingTimeInterval(3 * 3600), state: &state)

        XCTAssertTrue(sameEpoch.isEmpty)
        XCTAssertEqual(laterEpoch, [.recovered(provider: .claude, window: warnAfterReset)])
        XCTAssertEqual(criticalAgain, [.critical(provider: .claude, window: lowAgain)])
    }

    /// Launch first evaluates last-state.json, and a failed refresh keeps a
    /// snapshot whole while any one window is live: a window whose reset has
    /// passed describes an epoch that is over.
    func testWindowPastItsResetIsIgnored() {
        var fresh = QuotaNotificationState()
        let cachedAtLaunch = evaluate(
            [fiveHour(used: 95, resetsAt: start.addingTimeInterval(-60))], at: start, state: &fresh)

        let low = fiveHour(used: 95, resetsAt: start.addingTimeInterval(60))
        let refreshed = fiveHour(used: 0, resetsAt: start.addingTimeInterval(5 * 3600))
        var notified = QuotaNotificationState()
        _ = evaluate([low], at: start, state: &notified)
        let carriedAlong = evaluate([low], at: start.addingTimeInterval(120), state: &notified)
        let afterRefresh = evaluate([refreshed], at: start.addingTimeInterval(180), state: &notified)

        XCTAssertTrue(cachedAtLaunch.isEmpty)
        XCTAssertTrue(fresh.criticalNotified.isEmpty)
        XCTAssertTrue(carriedAlong.isEmpty)
        XCTAssertEqual(afterRefresh, [.recovered(provider: .claude, window: refreshed)])
    }

    /// A failed or rate-limited refresh hands over either no windows or the
    /// last live ones unchanged; neither moves the state.
    func testRefreshWithoutNewReadingLeavesStateAlone() {
        let low = weekly(used: 95, resetsAt: start.addingTimeInterval(3 * 86400))
        var state = QuotaNotificationState()

        _ = evaluate([low], at: start, state: &state)
        let before = state
        let unavailable = evaluate([], at: start.addingTimeInterval(60), state: &state)
        let keptLastLive = evaluate([low], at: start.addingTimeInterval(120), state: &state)

        XCTAssertTrue(unavailable.isEmpty)
        XCTAssertTrue(keptLastLive.isEmpty)
        XCTAssertEqual(state, before)
    }

    /// The dedup state lives in memory: after a relaunch a window that is
    /// still critical in its live reading notifies once more.
    func testRelaunchNotifiesStillCriticalWindowOnce() {
        let low = weekly(used: 95, resetsAt: start.addingTimeInterval(3 * 86400))
        var state = QuotaNotificationState()
        _ = evaluate([low], at: start, state: &state)

        var relaunched = QuotaNotificationState()
        let first = evaluate([low], at: start.addingTimeInterval(600), state: &relaunched)
        let second = evaluate([low], at: start.addingTimeInterval(660), state: &relaunched)

        XCTAssertEqual(first, [.critical(provider: .claude, window: low)])
        XCTAssertTrue(second.isEmpty)
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
