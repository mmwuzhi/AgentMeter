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
        XCTAssertFalse(state.alerts.isEmpty)
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
        XCTAssertTrue(state.alerts.isEmpty)
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
        XCTAssertTrue(state.alerts.isEmpty)
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
        threshold: Double = 10,
        recoveryEnabled: Bool = true,
        state: inout QuotaNotificationState
    ) -> [QuotaNotificationEvent] {
        QuotaNotificationPolicy.evaluate(
            provider: provider,
            windows: windows,
            now: now,
            threshold: threshold,
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
        XCTAssertEqual(state.alerts["claude:five_hour"]?.resetsAt, reset)
    }

    /// Review 2026-10-30: the scrape alerts (no reset), the Mac sleeps across
    /// the reset, and the first stated reset is of the next epoch, already
    /// low. Taken as the alert's own, it went unalerted, and the persisted
    /// state kept it so after a relaunch too.
    func testAnAlertWithoutAResetDoesNotHideALaterEpoch() {
        var state = QuotaNotificationState()
        _ = evaluate([fiveHour(used: 95, resetsAt: nil)], at: start, state: &state)

        let nextEpoch = fiveHour(used: 93, resetsAt: start.addingTimeInterval(8 * 3600))
        XCTAssertEqual(evaluate([nextEpoch], at: start.addingTimeInterval(6 * 3600), state: &state),
                       [.critical(provider: .claude, window: nextEpoch)])
        var relaunched = state.kept(at: start.addingTimeInterval(6 * 3600 + 60))
        XCTAssertTrue(evaluate([nextEpoch], at: start.addingTimeInterval(6 * 3600 + 60), state: &relaunched).isEmpty)

        // Within drift of the epoch's start it counts as begun: once more.
        var nearStart = QuotaNotificationState()
        _ = evaluate([fiveHour(used: 95, resetsAt: nil)], at: start, state: &nearStart)
        let begunJustBefore = fiveHour(used: 95, resetsAt: start.addingTimeInterval(5 * 3600 - 120))
        XCTAssertEqual(evaluate([begunJustBefore], at: start.addingTimeInterval(60), state: &nearStart),
                       [.critical(provider: .claude, window: begunJustBefore)])
    }

    /// The reset an alert took stays alerted when another login's window
    /// alerts in between.
    func testATakenResetStaysAlertedAfterAnotherLogin() {
        let reset = start.addingTimeInterval(3600)
        let otherLogin = fiveHour(used: 94, resetsAt: start.addingTimeInterval(3 * 3600))
        var state = QuotaNotificationState()

        var events = evaluate([fiveHour(used: 95, resetsAt: nil)], at: start, state: &state)
        for (step, window) in [fiveHour(used: 96, resetsAt: reset), otherLogin, fiveHour(used: 97, resetsAt: reset)].enumerated() {
            events += evaluate([window], at: start.addingTimeInterval(Double(step + 1) * 60), state: &state)
        }

        XCTAssertEqual(events, [.critical(provider: .claude, window: fiveHour(used: 95, resetsAt: nil)),
                                .critical(provider: .claude, window: otherLogin)])
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
        XCTAssertTrue(fresh.alerts.isEmpty)
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

    /// 2026-10-29: the weekly alert went out at 16:51 and again right after
    /// the 18:22 relaunch, one `resetsAt`. The state now outlives a launch:
    /// the same epoch stays alerted.
    func testARelaunchInTheSameEpochDoesNotAlertAgain() throws {
        let low = weekly(used: 96, resetsAt: start.addingTimeInterval(3 * 86400))
        let suite = "agentmeter.tests.quota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuotaNotificationStateStore.defaults(defaults)

        var state = store.load()
        XCTAssertEqual(evaluate([low], at: start, state: &state), [.critical(provider: .claude, window: low)])
        store.save(state)

        var relaunched = store.load().kept(at: start.addingTimeInterval(5400))
        XCTAssertEqual(relaunched, state, "an epoch still running is kept whole")
        XCTAssertTrue(evaluate([low], at: start.addingTimeInterval(5400), state: &relaunched).isEmpty)
        // The scrape's reading without a reset is the same epoch too.
        XCTAssertTrue(evaluate([weekly(used: 97, resetsAt: nil)], at: start.addingTimeInterval(5460), state: &relaunched).isEmpty)
    }

    /// An alert whose epoch ended while AgentMeter was not running is
    /// dropped at launch: the new epoch alerts as any new epoch does, and no
    /// recovery banner goes out for an end nobody saw.
    func testALaunchAfterTheResetDropsTheAlert() {
        let reset = start.addingTimeInterval(3600)
        var state = QuotaNotificationState()
        _ = evaluate([fiveHour(used: 95, resetsAt: reset)], at: start, state: &state)

        let launch = reset.addingTimeInterval(QuotaWindow.sameEpochTolerance + 1)
        var relaunched = state.kept(at: launch)
        XCTAssertTrue(relaunched.alerts.isEmpty)
        let refilled = fiveHour(used: 20, resetsAt: reset.addingTimeInterval(5 * 3600))
        XCTAssertTrue(evaluate([refilled], at: launch, state: &relaunched).isEmpty, "no recovery for an unseen end")
        let lowAgain = fiveHour(used: 95, resetsAt: reset.addingTimeInterval(5 * 3600))
        XCTAssertEqual(evaluate([lowAgain], at: launch.addingTimeInterval(60), state: &relaunched),
                       [.critical(provider: .claude, window: lowAgain)])

        // Within drift of its reset the epoch may still be the one alerted.
        XCTAssertEqual(state.kept(at: reset.addingTimeInterval(60)), state)
    }

    /// Without a stated reset nothing shows the epoch is still running:
    /// dropped at launch, so it can alert once more but never miss one.
    func testAnAlertWithoutAResetDoesNotOutliveALaunch() {
        var state = QuotaNotificationState()
        _ = evaluate([fiveHour(used: 95, resetsAt: nil)], at: start, state: &state)
        XCTAssertEqual(state.alerts.count, 1)
        XCTAssertTrue(state.kept(at: start.addingTimeInterval(60)).alerts.isEmpty)
    }

    /// "Critical notifications fire once" (Settings): a threshold changed
    /// within the epoch, raised or lowered (the field writes on each edit),
    /// never alerts it twice; one raised before the crossing alerts as the
    /// reading meets it.
    func testThresholdChangesDoNotAlertAnEpochTwice() {
        let reset = start.addingTimeInterval(3 * 86400)
        var state = QuotaNotificationState()
        let eight = weekly(used: 92, resetsAt: reset)
        let four = weekly(used: 96, resetsAt: reset)

        XCTAssertEqual(evaluate([eight], at: start, threshold: 10, state: &state), [.critical(provider: .claude, window: eight)])
        for (step, threshold) in [20.0, 9, 8, 7, 6, 5].enumerated() {
            XCTAssertTrue(evaluate([four], at: start.addingTimeInterval(Double(step + 1) * 60), threshold: threshold,
                                   state: &state).isEmpty, "threshold \(threshold)")
        }

        var untouched = QuotaNotificationState()
        let fifteen = weekly(used: 85, resetsAt: reset)
        XCTAssertTrue(evaluate([fifteen], at: start, threshold: 10, state: &untouched).isEmpty)
        XCTAssertEqual(evaluate([fifteen], at: start.addingTimeInterval(60), threshold: 20, state: &untouched),
                       [.critical(provider: .claude, window: fifteen)])
    }

    /// Readings carry no account. Another login's window has its own reset,
    /// earlier as well as later: an epoch not yet alerted, so it alerts once;
    /// switching back and forth alerts neither again, and an earlier reset
    /// never counts as a recovery.
    func testAnotherLoginsWindowAlertsOnceAndAlternatingStaysQuiet() {
        let resetA = start.addingTimeInterval(4 * 86400)
        let resetB = start.addingTimeInterval(2 * 86400)
        var state = QuotaNotificationState()
        let lowA = weekly(used: 95, resetsAt: resetA)
        let lowB = weekly(used: 93, resetsAt: resetB)
        let fineB = weekly(used: 40, resetsAt: resetB)

        var events: [QuotaNotificationEvent] = []
        for (step, window) in [lowA, fineB, lowA, lowB, lowA, lowB, fineB, lowA].enumerated() {
            events += evaluate([window], at: start.addingTimeInterval(Double(step) * 60), state: &state)
        }
        XCTAssertEqual(events, [.critical(provider: .claude, window: lowA), .critical(provider: .claude, window: lowB)])

        let drifted = weekly(used: 96, resetsAt: resetA.addingTimeInterval(-3 * 60))
        XCTAssertTrue(evaluate([drifted], at: start.addingTimeInterval(600), state: &state).isEmpty, "drift: same epoch")
    }

    /// Review 2026-10-29: a Codex reset credit spent mid-epoch, then a wake
    /// before the network is up, and the rollout log's fallback reading
    /// still carries the epoch before (an earlier reset, still ahead). The
    /// alternation used to post low, low, recovered, low.
    func testAStaleFallbackOfAnAlertedEpochStaysQuiet() {
        let r1 = start.addingTimeInterval(2 * 86400)
        let r2 = start.addingTimeInterval(7 * 86400)
        var state = QuotaNotificationState()
        let lowR1 = weekly(used: 95, resetsAt: r1)
        let refilledR2 = weekly(used: 0, resetsAt: r2)
        let lowR2 = weekly(used: 95, resetsAt: r2)
        let halfR1 = weekly(used: 50, resetsAt: r1)

        var events: [QuotaNotificationEvent] = []
        for (step, window) in [lowR1, refilledR2, lowR2, lowR1, lowR2, halfR1, lowR2].enumerated() {
            events += evaluate([window], provider: .codex, at: start.addingTimeInterval(Double(step) * 600), state: &state)
        }
        XCTAssertEqual(events, [.critical(provider: .codex, window: lowR1), .recovered(provider: .codex, window: refilledR2),
                                .critical(provider: .codex, window: lowR2)])
    }

    /// Alerted resets go once they pass, so the state holds only epochs that
    /// still run.
    func testAlertedResetsAreForgottenOnceTheyPass() {
        var state = QuotaNotificationState()
        let reset = start.addingTimeInterval(3600)
        _ = evaluate([fiveHour(used: 95, resetsAt: reset)], at: start, state: &state)
        XCTAssertEqual(state.alertedResets["claude:five_hour"], [reset])
        let next = fiveHour(used: 20, resetsAt: reset.addingTimeInterval(5 * 3600))
        XCTAssertEqual(evaluate([next], at: reset.addingTimeInterval(QuotaWindow.sameEpochTolerance + 1), state: &state),
                       [.recovered(provider: .claude, window: next)])
        XCTAssertTrue(state.alerts.isEmpty)
        XCTAssertTrue(state.alertedResets.isEmpty)
    }

    /// One key beside the alert settings; a value that does not decode
    /// reads as empty, as before the key existed.
    func testTheStoreKeepsOneKeyAndReadsGarbageAsEmpty() throws {
        let suite = "agentmeter.tests.quota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(QuotaNotificationStateStore.defaultsKey, "quotaAlertState")
        let store = QuotaNotificationStateStore.defaults(defaults)
        XCTAssertEqual(store.load(), QuotaNotificationState())
        defaults.set(Data("{not json".utf8), forKey: QuotaNotificationStateStore.defaultsKey)
        XCTAssertEqual(store.load(), QuotaNotificationState())
        defaults.set("a string", forKey: QuotaNotificationStateStore.defaultsKey)
        XCTAssertEqual(store.load(), QuotaNotificationState())
    }

    /// Through the manager, as the app runs it: a second instance on the
    /// same defaults (the relaunch) posts nothing for the same epoch, and the
    /// state it writes is what the next one reads.
    @MainActor
    func testTheManagerDoesNotRepostAfterARelaunch() async throws {
        let suite = "agentmeter.tests.quota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = UserDefaults.standard
        let saved = ["alertsEnabled", "alertThresholdPercent"].map { ($0, settings.object(forKey: $0)) }
        settings.set(true, forKey: "alertsEnabled")
        settings.set(10.0, forKey: "alertThresholdPercent")
        defer { for (key, value) in saved { if let value { settings.set(value, forKey: key) } else { settings.removeObject(forKey: key) } } }

        let clock = EventTestClock(start)
        func launch() async -> (NotificationManager, AuthorizationCenterStub) {
            let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
            let manager = NotificationManager(authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" },
                                              now: { clock.now }, quotaStateStore: .defaults(defaults))
            await manager.requestAuthorizationIfNeeded()
            return (manager, center)
        }
        let low = [weekly(used: 96, resetsAt: start.addingTimeInterval(3 * 86400))]

        let (first, firstCenter) = await launch()
        first.evaluate(provider: .claude, windows: low)
        first.evaluate(provider: .claude, windows: low)
        XCTAssertEqual(firstCenter.posted.map(\.content.title), ["Claude quota low"])

        clock.advance(5400)
        let (second, secondCenter) = await launch()
        second.evaluate(provider: .claude, windows: low)
        XCTAssertTrue(secondCenter.posted.isEmpty, "same epoch after a relaunch")
        second.evaluate(provider: .codex, windows: [fiveHour(used: 95, resetsAt: start.addingTimeInterval(7200))])
        XCTAssertEqual(secondCenter.posted.map(\.content.title), ["Codex quota low"], "another provider is its own window")

        clock.advance(3 * 86400)
        let (third, thirdCenter) = await launch()
        let nextWeek = [weekly(used: 97, resetsAt: start.addingTimeInterval(10 * 86400))]
        third.evaluate(provider: .claude, windows: nextWeek)
        XCTAssertEqual(thirdCenter.posted.map(\.content.title), ["Claude quota low"], "a new epoch alerts")
        // Both earlier epochs ended before this launch: dropped, not kept.
        let kept = QuotaNotificationStateStore.defaults(defaults).load()
        XCTAssertEqual(Set(kept.alerts.keys), ["claude:seven_day"])
        XCTAssertEqual(kept.alerts["claude:seven_day"]?.resetsAt, start.addingTimeInterval(10 * 86400))
        XCTAssertEqual(kept.alertedResets, ["claude:seven_day": [start.addingTimeInterval(10 * 86400)]])
    }

    /// A launch writes back what it dropped, so ended epochs do not pile up
    /// in the key however long nothing changes.
    @MainActor
    func testALaunchWritesBackWhatItDropped() throws {
        let suite = "agentmeter.tests.quota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuotaNotificationStateStore.defaults(defaults)
        var state = QuotaNotificationState()
        _ = evaluate([fiveHour(used: 95, resetsAt: start.addingTimeInterval(3600))], at: start, state: &state)
        _ = evaluate([weekly(used: 95, resetsAt: start.addingTimeInterval(3 * 86400))], at: start, state: &state)
        _ = evaluate([fiveHour(used: 95, resetsAt: nil)], provider: .codex, at: start, state: &state)
        store.save(state)

        let clock = EventTestClock(start.addingTimeInterval(2 * 3600))
        _ = NotificationManager(authorizationCenter: AuthorizationCenterStub(result: .success(true)),
                                bundleIdentifier: { "com.shu.agentmeter.tests" }, now: { clock.now }, quotaStateStore: store)
        let written = store.load()
        XCTAssertEqual(Set(written.alerts.keys), ["claude:seven_day"])
        XCTAssertEqual(Set(written.alertedResets.keys), ["claude:seven_day"])
    }

    /// Two instances on one defaults domain (a development build beside the
    /// installed app) each read the key when they evaluate: neither drops
    /// the other's alert.
    @MainActor
    func testTwoInstancesKeepEachOthersAlerts() async throws {
        let suite = "agentmeter.tests.quota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = UserDefaults.standard
        let saved = ["alertsEnabled", "alertThresholdPercent"].map { ($0, settings.object(forKey: $0)) }
        settings.set(true, forKey: "alertsEnabled")
        settings.set(10.0, forKey: "alertThresholdPercent")
        defer { for (key, value) in saved { if let value { settings.set(value, forKey: key) } else { settings.removeObject(forKey: key) } } }

        let clock = EventTestClock(start)
        func instance() async -> (NotificationManager, AuthorizationCenterStub) {
            let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
            let manager = NotificationManager(authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" },
                                              now: { clock.now }, quotaStateStore: .defaults(defaults))
            await manager.requestAuthorizationIfNeeded()
            return (manager, center)
        }
        let codex = [fiveHour(used: 95, resetsAt: start.addingTimeInterval(7200))]
        let claude = [weekly(used: 96, resetsAt: start.addingTimeInterval(3 * 86400))]
        let (a, aCenter) = await instance()
        let (b, bCenter) = await instance()
        a.evaluate(provider: .codex, windows: codex)
        b.evaluate(provider: .claude, windows: claude)
        b.evaluate(provider: .codex, windows: codex)
        a.evaluate(provider: .claude, windows: claude)
        XCTAssertEqual(aCenter.posted.map(\.content.title), ["Codex quota low"])
        XCTAssertEqual(bCenter.posted.map(\.content.title), ["Claude quota low"])

        let (c, cCenter) = await instance()
        c.evaluate(provider: .codex, windows: codex)
        c.evaluate(provider: .claude, windows: claude)
        XCTAssertTrue(cCenter.posted.isEmpty)
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
