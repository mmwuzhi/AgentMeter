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

    /// Replays the report that motivated the floor: a weekly at 43% draining
    /// 8%/h read "would run out in 5h 22m" while the 5-hour window, which
    /// hands it about 23 points per cycle, had 38% left and 24 minutes to its
    /// reset. The floor lands 6h 45m out instead. It once read 7h 43m, when
    /// each refill was fed in evenly across its cycle rather than landing whole.
    func testLongWindowRunOutIsFlooredByShortWindowCapacity() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peerReset = now.addingTimeInterval(24 * 60)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 62, resetsAt: peerReset, cycle: 5 * 3600)
        let window = QuotaWindow(
            id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 57, resetsAt: reset, cycle: 7 * 24 * 3600
        )
        let observations = staircase("seven_day_fable", from: 57, to: 43, steps: 14, overMinutes: 105, now: now, resetsAt: reset)
            + staircase("five_hour", from: 98, to: 38, steps: 15, overMinutes: 105, now: now, resetsAt: peerReset)

        let unconstrained = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )
        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        // avg 8%/h over 1h 45m: 43 / 8 = 5h 22m 30s.
        XCTAssertEqual(unconstrained.status, .atRisk)
        XCTAssertEqual(unconstrained.estimatedDepletionAt!.timeIntervalSince(now), 5.375 * 3600, accuracy: 1)
        XCTAssertNil(unconstrained.pacedBy)

        // r = 14/60: the 38 peer points hand over 8.87 before the reset and
        // each refill 23.33, so the 34.13 left need the refill at 24 min and
        // most of the one at 5h 24m: 10.8 more at 8%/h lands at 6h 45m.
        XCTAssertEqual(paced.status, .atRisk)
        XCTAssertEqual(paced.percentPerHour!, 8, accuracy: 0.01)
        XCTAssertEqual(paced.estimatedDepletionAt!.timeIntervalSince(now), 6.75 * 3600, accuracy: 60)
        XCTAssertEqual(paced.pacedBy, "5-hour")
        XCTAssertTrue(paced.message.hasPrefix("would run out in 6h 4"), paced.message)
    }

    /// The reported case: a Fable weekly at 16% draining 3.6%/h beside a
    /// 5-hour window at 20% that resets in nine minutes and is itself on
    /// course to run dry a few seconds before that. One refill hands the
    /// weekly ~19 points, more than it has left, so nothing paces it and
    /// "would run out in 4h 24m" stands. It read 6h 56m: the two hours of
    /// another model before Fable started diluted the ratio to 0.10, and the
    /// even-pace floor spread what was left over 2%/h. With those fixed, the
    /// peer about to run dry would still have called the weekly safe through
    /// the "hits first" rule, which ignores the refill nine minutes away.
    func testARefillThatCoversTheRemainderLeavesTheProjectionAlone() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peerReset = now.addingTimeInterval(9 * 60)
        let reset = now.addingTimeInterval(19 * 3600)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 80, resetsAt: peerReset, cycle: 5 * 3600)
        let window = QuotaWindow(
            id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 84, resetsAt: reset,
            isModelScoped: true, cycle: 7 * 24 * 3600
        )
        // 112 minutes on another model: the 5-hour drains 32, Fable not at all.
        // Then 20 minutes of Fable: the 5-hour drains 46, Fable 8.
        let observations = [
            observation("seven_day_fable", remaining: 24, minutesAgo: 132, from: now, resetsAt: reset),
            observation("five_hour", remaining: 98, minutesAgo: 132, from: now, resetsAt: peerReset),
        ]
            + staircase("seven_day_fable", from: 24, to: 16, steps: 8, overMinutes: 20, now: now, resetsAt: reset)
            + staircase("five_hour", from: 66, to: 20, steps: 23, overMinutes: 20, now: now, resetsAt: peerReset)

        let unconstrained = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )
        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )
        let peerRunway = QuotaTrendTracker.runway(
            provider: .claude, window: peer, observations: observations, now: now
        )

        // The 5-hour runs dry at 8m 42s, before its own reset.
        XCTAssertEqual(peerRunway.status, .atRisk)
        // 8 points over 2h 12m: 16 / 3.64 = 4h 24m.
        XCTAssertEqual(unconstrained.status, .atRisk)
        XCTAssertEqual(unconstrained.estimatedDepletionAt!.timeIntervalSince(now), 4.4 * 3600, accuracy: 1)
        XCTAssertEqual(paced, unconstrained)
        XCTAssertNil(paced.pacedBy)
        XCTAssertTrue(paced.message.hasPrefix("would run out in 4h 2"), paced.message)
    }

    /// A model-scoped weekly drains only while its model runs. Peer points spent
    /// on other models while it sat still say nothing about what a refill hands
    /// it, so the ratio reads the stretches where it was running. The all-model
    /// weekly counts every model, so the same flat stretch is real evidence of
    /// a slow drain there and stays in.
    func testDrainRatioSkipsAModelScopedWindowsDormantStretch() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 60, resetsAt: nil)
        let scoped = QuotaWindow(id: "fable", label: "Weekly (Fable)", usedPercent: 84, resetsAt: nil, isModelScoped: true)
        let shared = QuotaWindow(id: "fable", label: "Weekly", usedPercent: 84, resetsAt: nil)
        // Two hours flat while the peer drains 30, then 6 points beside 30 more.
        let resumed = now.addingTimeInterval(-30 * 60)
        let observations = staircase("five_hour", from: 100, to: 70, steps: 15, overMinutes: 120, now: resumed, resetsAt: nil)
            + staircase("fable", from: 22, to: 22, steps: 15, overMinutes: 120, now: resumed, resetsAt: nil)
            + staircase("five_hour", from: 70, to: 40, steps: 6, overMinutes: 30, now: now, resetsAt: nil)
            + staircase("fable", from: 22, to: 16, steps: 6, overMinutes: 30, now: now, resetsAt: nil)

        XCTAssertEqual(
            QuotaTrendTracker.drainRatio(of: scoped, per: peer, provider: .claude, observations: observations)!,
            6.0 / 30.0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            QuotaTrendTracker.drainRatio(of: shared, per: peer, provider: .claude, observations: observations)!,
            6.0 / 60.0,
            accuracy: 1e-9
        )
    }

    /// Thursday night: the weekly has 20% and six hours left, the user is
    /// bursting at 12%/h, and the 5-hour window has 10% left with an hour to
    /// its reset. Even a whole 5-hour refill hands the weekly ~13 points, so it
    /// cannot run out before its own reset, whatever the avg projection says.
    func testLongWindowIsSafeWhenShortWindowCapacityCannotReachItsReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peerReset = now.addingTimeInterval(3600)
        let reset = now.addingTimeInterval(6 * 3600)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 90, resetsAt: peerReset, cycle: 5 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 80, resetsAt: reset, cycle: 7 * 24 * 3600)
        let observations = staircase("seven_day", from: 32, to: 20, steps: 6, overMinutes: 60, now: now, resetsAt: reset)
            + staircase("five_hour", from: 100, to: 10, steps: 6, overMinutes: 60, now: now, resetsAt: peerReset)

        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        // r = 12/90: 1.3 points before the peer reset and 13.3 at it, so the
        // last 5.3 wait for the next refill at 6h — the window's own reset.
        XCTAssertEqual(paced.status, .safe)
        XCTAssertNil(paced.estimatedDepletionAt)
        XCTAssertEqual(paced.message, "5-hour limit paces this window")
        XCTAssertEqual(paced.pacedBy, "5-hour")
        XCTAssertEqual(paced.percentPerHour!, 12, accuracy: 0.01)
    }

    /// The observed case: a weekly at 47% left, 14 h from its reset, the user
    /// working at 6-7%/h. Keyed on time-to-reset the row read `now 6.7%/h ·
    /// avg 6%/h · budget 3.4%/h` in orange with no run-out line — a budget
    /// segment and a colour the pace-only split exists to remove — and its
    /// `avg` had quietly dropped from the 24 h span to the 20-minute one. This
    /// fixture sits the reset 6 h out, deeper inside the same last day; the
    /// stated 7-day cycle keeps the window a long one to the end.
    func testWeeklyInsideItsLastDayKeepsThePaceOnlyReading() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(6 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 53, resetsAt: reset, cycle: 7 * 24 * 3600)
        // 6 points over the hour: 47 left at 6%/h lasts 7h 50m, past the reset.
        let observations = staircase("seven_day", from: 53, to: 47, steps: 6, overMinutes: 60, now: now, resetsAt: reset)

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [window]
        )

        XCTAssertEqual(runway.paceStyle, .paceOnly)
        // The long-span policy applied: under a 24 h span the hour of history
        // is all there is, where the short policy would have stopped at 20 min.
        XCTAssertGreaterThan(runway.avgSpan ?? -1, QuotaTrendTracker.shortAverageSpan)
        XCTAssertEqual(runway.percentPerHour ?? -1, 6, accuracy: 0.01)
        XCTAssertNotEqual(runway.status, .atRisk)
        let pace = QuotaRow.pace(runway)
        XCTAssertNotNil(pace)
        XCTAssertFalse(pace?.text.contains("budget") ?? true, pace?.text ?? "")
        XCTAssertEqual(pace?.overBudget, false)
    }

    /// Mirror: the 5-hour window the split was built for keeps its budget
    /// segment and the 20-minute `avg`.
    func testFiveHourWindowKeepsThePaceVersusBudgetReading() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3 * 3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 53, resetsAt: reset, cycle: 5 * 3600)
        let observations = staircase("five_hour", from: 53, to: 47, steps: 6, overMinutes: 60, now: now, resetsAt: reset)

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [window]
        )

        XCTAssertEqual(runway.paceStyle, .paceVersusBudget)
        XCTAssertLessThanOrEqual(runway.avgSpan ?? .infinity, QuotaTrendTracker.shortAverageSpan)
        let pace = QuotaRow.pace(runway)
        XCTAssertTrue(pace?.text.contains("budget") ?? false, pace?.text ?? "")
    }

    /// The reported case: a weekly reading "would run out in 17h 59m" next to a
    /// 5-hour window. That date assumes the pace holds through three full peer
    /// refills, which is not something the user can act on now, so the row
    /// keeps its pace and drops the date. The peer carries no observations
    /// here, so the capacity floor has no evidence and this rule acts alone.
    func testLongWindowRunOutBeyondTwoPeerCyclesDropsTheDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(
            id: "five_hour", label: "5-hour", usedPercent: 85,
            resetsAt: now.addingTimeInterval(2 * 3600), cycle: 5 * 3600
        )
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 58, resetsAt: reset, cycle: 7 * 24 * 3600)
        // 10 points over 4 hours = 2.5%/h; 42 left projects 16h 48m out.
        let observations = staircase("seven_day", from: 52, to: 42, steps: 10, overMinutes: 240, now: now, resetsAt: reset)

        let alone = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )
        XCTAssertEqual(alone.status, .atRisk)
        XCTAssertEqual(alone.estimatedDepletionAt!.timeIntervalSince(now), 16.8 * 3600, accuracy: 60)

        // 16h 48m is past 2 x the 5-hour cycle.
        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )
        XCTAssertEqual(paced.status, .watch)
        XCTAssertNil(paced.estimatedDepletionAt)
        XCTAssertNil(QuotaRow.alertLine(paced))
        // The pace survives, and with it the `now`/`avg` line.
        XCTAssertEqual(paced.percentPerHour!, 2.5, accuracy: 0.01)
        XCTAssertEqual(QuotaRow.pace(paced)?.overBudget, false)
    }

    func testLongWindowRunOutInsideTwoPeerCyclesKeepsTheDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(
            id: "five_hour", label: "5-hour", usedPercent: 85,
            resetsAt: now.addingTimeInterval(2 * 3600), cycle: 5 * 3600
        )
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 58, resetsAt: reset, cycle: 7 * 24 * 3600)
        // 21 points over 4 hours = 5.25%/h; 42 left projects exactly 8h out.
        let observations = staircase("seven_day", from: 63, to: 42, steps: 21, overMinutes: 240, now: now, resetsAt: reset)

        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        XCTAssertEqual(paced.status, .atRisk)
        XCTAssertEqual(paced.estimatedDepletionAt!.timeIntervalSince(now), 8 * 3600, accuracy: 60)
        XCTAssertTrue(paced.message.hasPrefix("would run out in 8h"), paced.message)
    }

    func testRunOutHorizonIsFlooredAgainstAnImplausiblePeerCycle() {
        // `cycle` is provider-reported everywhere but Claude, and this rule only
        // ever takes a warning away, so one bad field must not be able to hide a
        // run-out an hour out. `CodexRolloutReader.cycle(forMinutes:)` rejects a
        // cadence this short as well; this is the second layer.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(
            id: "five_hour", label: "5-hour", usedPercent: 85,
            resetsAt: now.addingTimeInterval(2 * 3600), cycle: 60
        )
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 58, resetsAt: reset, cycle: 7 * 24 * 3600)
        // 42 points over an hour = 42%/h; 42 left projects exactly 1h out.
        let observations = staircase("seven_day", from: 84, to: 42, steps: 42, overMinutes: 60, now: now, resetsAt: reset)

        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        // Unfloored this would be 2 x 60s, hiding everything beyond two minutes.
        XCTAssertEqual(paced.status, .atRisk)
        XCTAssertEqual(paced.estimatedDepletionAt!.timeIntervalSince(now), 3600, accuracy: 60)
    }

    func testRunOutHorizonIgnoresAPeerWhoseCycleContradictsItsOwnReset() {
        // A five-minute cadence clears the plausibility band, so the band alone
        // cannot catch it — but a window resetting two hours out is not on a
        // five-minute cycle, and reading it would drag the horizon to its floor
        // and take a genuine six-hour warning away.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(91 * 3600)
        let liar = QuotaWindow(
            id: "five_hour", label: "5-hour", usedPercent: 85,
            resetsAt: now.addingTimeInterval(2 * 3600), cycle: 5 * 60
        )
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 58, resetsAt: reset, cycle: 7 * 24 * 3600)
        // 7 points an hour over four hours; 42 left projects six hours out.
        let observations = staircase("seven_day", from: 70, to: 42, steps: 28, overMinutes: 240, now: now, resetsAt: reset)

        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [liar, window]
        )

        XCTAssertEqual(paced.status, .atRisk)
        XCTAssertEqual(paced.estimatedDepletionAt!.timeIntervalSince(now), 6 * 3600, accuracy: 60)
    }

    func testRunOutHorizonNeedsTheWindowToNameItsOwnCycle() {
        // Nothing to compare a peer's cadence against, so there is no "couple of
        // refills" to reason about and the rule stays out of it. Copilot's
        // allowances are the real shape here.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(
            id: "five_hour", label: "5-hour", usedPercent: 85,
            resetsAt: now.addingTimeInterval(2 * 3600), cycle: 5 * 3600
        )
        let window = QuotaWindow(id: "premium", label: "Premium", usedPercent: 58, resetsAt: reset)
        let observations = staircase("premium", from: 52, to: 42, steps: 10, overMinutes: 240, now: now, resetsAt: reset)

        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        XCTAssertEqual(paced.status, .atRisk)
        XCTAssertEqual(paced.estimatedDepletionAt!.timeIntervalSince(now), 16.8 * 3600, accuracy: 60)
    }

    func testRunOutHorizonNeedsAPeerThatNamesACycle() {
        // Copilot's allowances name no cadence, so "past a couple of refills"
        // describes nothing and the projection stands on the trust rules alone.
        // (The observation helper stamps `.claude`; what is under test is the
        // missing `cycle`, not which provider reported it.)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(id: "chat", label: "Chat", usedPercent: 85, resetsAt: now.addingTimeInterval(2 * 3600))
        let window = QuotaWindow(id: "premium", label: "Premium", usedPercent: 58, resetsAt: reset)
        let observations = staircase("premium", from: 52, to: 42, steps: 10, overMinutes: 240, now: now, resetsAt: reset)

        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        XCTAssertEqual(paced.status, .atRisk)
        XCTAssertEqual(paced.estimatedDepletionAt!.timeIntervalSince(now), 16.8 * 3600, accuracy: 60)
    }

    /// Two weekly points say nothing about the ratio yet, so the raw
    /// projection stands until a third lands — the same three-tick argument
    /// `nowTriggerPercent` makes.
    func testCapacityFloorNeedsThreeWindowPointsOfEvidence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peerReset = now.addingTimeInterval(24 * 60)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 62, resetsAt: peerReset, cycle: 5 * 3600)
        let window = QuotaWindow(
            id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 95, resetsAt: reset, cycle: 7 * 24 * 3600
        )
        let observations = staircase("seven_day_fable", from: 7, to: 5, steps: 2, overMinutes: 60, now: now, resetsAt: reset)
            + staircase("five_hour", from: 98, to: 38, steps: 15, overMinutes: 60, now: now, resetsAt: peerReset)

        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        // 2%/h over the hour: 5 / 2 = 2h 30m, and no floor to move it.
        XCTAssertEqual(paced.status, .atRisk)
        XCTAssertEqual(paced.estimatedDepletionAt!.timeIntervalSince(now), 2.5 * 3600, accuracy: 1)
        XCTAssertNil(paced.pacedBy)
        XCTAssertEqual(paced.message, "would run out in 2h 30m")
    }

    func testDrainRatioNeedsThreeWindowAndTenPeerPoints() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 50, resetsAt: nil)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 50, resetsAt: nil)
        func ratio(windowPoints: Double, peerPoints: Double) -> Double? {
            QuotaTrendTracker.drainRatio(
                of: window,
                per: peer,
                provider: .claude,
                observations: staircase("seven_day", from: 50 + windowPoints, to: 50, steps: 1, overMinutes: 60, now: now, resetsAt: nil)
                    + staircase("five_hour", from: 50 + peerPoints, to: 50, steps: 1, overMinutes: 60, now: now, resetsAt: nil)
            )
        }

        XCTAssertNil(ratio(windowPoints: 2, peerPoints: 60))
        XCTAssertNil(ratio(windowPoints: 3, peerPoints: 9))
        XCTAssertEqual(ratio(windowPoints: 3, peerPoints: 10)!, 0.3, accuracy: 1e-9)
    }

    /// A rise is a reset. Across a sampling gap the peer may have drained,
    /// reset and drained again while the weekly only shows the sum, so a pair
    /// in which either window rose is left out instead of tilting the ratio.
    func testDrainRatioSkipsPairsWhereEitherWindowRose() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 25, resetsAt: nil)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 54, resetsAt: nil)
        func series(_ windowID: String, _ values: [Double]) -> [QuotaObservation] {
            values.enumerated().map { index, value in
                observation(windowID, remaining: value, minutesAgo: Double(values.count - 1 - index) * 30, from: now)
            }
        }

        // Peer 100→60→20, then a reset seen as 20→95 across a gap, then 95→75.
        // The weekly over the same instants: 80→72→64→50→46 — its 14-point
        // drop beside the peer's rise is the invisible drain and must not count.
        let peerReset = series("five_hour", [100, 60, 20, 95, 75]) + series("seven_day", [80, 72, 64, 50, 46])
        XCTAssertEqual(
            QuotaTrendTracker.drainRatio(of: window, per: peer, provider: .claude, observations: peerReset)!,
            20.0 / 100.0,
            accuracy: 1e-9
        )

        // The weekly's own reset, 64→90, while the peer kept draining 60→40.
        let windowReset = series("five_hour", [100, 80, 60, 40, 20]) + series("seven_day", [80, 72, 64, 90, 86])
        XCTAssertEqual(
            QuotaTrendTracker.drainRatio(of: window, per: peer, provider: .claude, observations: windowReset)!,
            20.0 / 60.0,
            accuracy: 1e-9
        )
    }

    /// The floor only bites when the recent pace outruns what the peer can
    /// hand over across refills. A peer draining 16%/h — under its own 20%/h
    /// refill pace — leaves the avg projection exactly as it was.
    func testCapacityFloorLeavesASlowerAveragePaceAlone() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peerReset = now.addingTimeInterval(24 * 60)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 30, resetsAt: peerReset, cycle: 5 * 3600)
        let window = QuotaWindow(
            id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 57, resetsAt: reset, cycle: 7 * 24 * 3600
        )
        let observations = staircase("seven_day_fable", from: 57, to: 43, steps: 14, overMinutes: 105, now: now, resetsAt: reset)
            + staircase("five_hour", from: 98, to: 70, steps: 14, overMinutes: 105, now: now, resetsAt: peerReset)

        let unconstrained = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )
        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        // r = 14/28: 35 points before the peer reset and 50 at it, so the
        // floor sits 24 min + 8 / 8 h = 1h 24m out — well inside the 5h 22m
        // projection.
        XCTAssertEqual(paced, unconstrained)
        XCTAssertEqual(paced.status, .atRisk)
        XCTAssertNil(paced.pacedBy)
    }

    /// Without a stated cycle the peer's refill capacity is unknown, so it
    /// cannot floor anything; the older rules decide as before.
    func testCapacityFloorIgnoresPeersWithoutACycle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let peerReset = now.addingTimeInterval(24 * 60)
        let reset = now.addingTimeInterval(91 * 3600)
        let peer = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 62, resetsAt: peerReset)
        let window = QuotaWindow(
            id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 57, resetsAt: reset, cycle: 7 * 24 * 3600
        )
        let observations = staircase("seven_day_fable", from: 57, to: 43, steps: 14, overMinutes: 105, now: now, resetsAt: reset)
            + staircase("five_hour", from: 98, to: 38, steps: 15, overMinutes: 105, now: now, resetsAt: peerReset)

        let unconstrained = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )
        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        XCTAssertEqual(paced, unconstrained)
        XCTAssertEqual(paced.estimatedDepletionAt!.timeIntervalSince(now), 5.375 * 3600, accuracy: 1)
        XCTAssertNil(paced.pacedBy)
    }

    /// The all-model and model-scoped weeklies reset together (live responses
    /// put them a second apart), so neither paces the other even when one
    /// drains faster in percent.
    func testCapacityFloorIgnoresPeersSharingTheReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(91 * 3600)
        let peerReset = reset.addingTimeInterval(-0.5)
        let peer = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 60, resetsAt: peerReset, cycle: 7 * 24 * 3600)
        let window = QuotaWindow(
            id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 57, resetsAt: reset, cycle: 7 * 24 * 3600
        )
        let observations = staircase("seven_day_fable", from: 57, to: 43, steps: 14, overMinutes: 105, now: now, resetsAt: reset)
            + staircase("seven_day", from: 66, to: 40, steps: 13, overMinutes: 105, now: now, resetsAt: peerReset)

        let paced = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [peer, window]
        )

        XCTAssertNil(paced.pacedBy)
        XCTAssertNotEqual(paced.message, "Weekly limit paces this window")
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

    func testRunwayDowngradesLongHorizonBurstToWatch() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(90 * 24 * 3600) // ~90-day one-time credit
        let window = QuotaWindow(
            id: "cinder_cove", label: "Included credit", usedPercent: 3, resetsAt: reset,
            isOneTimeCredit: true
        )
        let observations = [
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 98,
                observedAt: now.addingTimeInterval(-600), // a 10-minute burst
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 97,
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

        // Naive linear extrapolation projects depletion ~16h out, which precedes the
        // 90-day reset and would (pre-fix) read as "would run out" — but 10 minutes of
        // burst usage isn't enough evidence to trust a 16-hour projection.
        XCTAssertEqual(runway.status, .watch)
        XCTAssertNil(runway.estimatedDepletionAt)
        XCTAssertTrue(runway.message.contains("%/h"))
    }

    func testLongFlatHistoryDilutesTheAverageWhileNowStaysHonest() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(90 * 24 * 3600)
        let window = QuotaWindow(
            id: "cinder_cove", label: "Included credit", usedPercent: 3, resetsAt: reset,
            isOneTimeCredit: true
        )
        let observations = [
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 98,
                observedAt: now.addingTimeInterval(-24 * 3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 98,
                observedAt: now.addingTimeInterval(-3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 98,
                observedAt: now.addingTimeInterval(-600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 97,
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

        // A day of flat history around a single 1% tick averages to ~0.04%/h,
        // which outlives the 90-day expiry, so nothing is claimed.
        XCTAssertEqual(runway.status, .safe)
        XCTAssertEqual(runway.percentPerHour ?? -1, 1.0 / 24, accuracy: 0.001)
        XCTAssertEqual(runway.avgSpan ?? -1, 24 * 3600, accuracy: 1)
        // A long-horizon window reads its latest whole-point step. There is no
        // earlier step inside the hour, so the anchor is the sample at the
        // lookback boundary: one point in the last hour. Ten-minute sampling
        // is dense against a span that long, unlike against the short slice.
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(runway.nowSpan ?? -1, 3600, accuracy: 1)
    }

    func testLongWindowSuddenDropAfterPlateauDoesNotClaimImmediateDepletion() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval((4 * 24 + 8) * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 32, resetsAt: reset)
        let observations = [
            QuotaObservation(
                provider: .claude,
                windowID: "seven_day",
                remainingPercent: 91,
                observedAt: now.addingTimeInterval(-17 * 3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "seven_day",
                remainingPercent: 90,
                observedAt: now.addingTimeInterval(-16 * 3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "seven_day",
                remainingPercent: 90,
                observedAt: now.addingTimeInterval(-7 * 60),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "seven_day",
                remainingPercent: 68,
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

        // 23 points across 17 hours is real evidence, so the window is at
        // risk — but the estimate lands ~50 hours out, not the 22 minutes the
        // last-tick slope would claim.
        XCTAssertEqual(runway.status, .atRisk)
        XCTAssertEqual(runway.percentPerHour ?? -1, 23.0 / 17, accuracy: 0.01)
        XCTAssertEqual(
            (runway.estimatedDepletionAt ?? now).timeIntervalSince(now) / 3600,
            50.26,
            accuracy: 0.5
        )
        // `now` is allowed to be this spiky: it is what the user can act on,
        // and it never feeds the estimate above. The sample before the drop is
        // seven minutes old, just inside the 7.5-minute carry-forward limit a
        // five-minute `now` allows, so the span it reports is the gap itself.
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 188.6, accuracy: 1)
        XCTAssertEqual(runway.nowSpan ?? -1, 420, accuracy: 1)
    }

    func testRunwaySustainedLongHorizonDrainStillReportsAtRisk() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(90 * 24 * 3600)
        let window = QuotaWindow(
            id: "cinder_cove", label: "Included credit", usedPercent: 50, resetsAt: reset,
            isOneTimeCredit: true
        )
        let observations = [
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 80,
                observedAt: now.addingTimeInterval(-24 * 3600), // a full day of sustained drain
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 70,
                observedAt: now.addingTimeInterval(-16 * 3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 60,
                observedAt: now.addingTimeInterval(-8 * 3600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
                remainingPercent: 51,
                observedAt: now.addingTimeInterval(-600),
                resetsAt: reset
            ),
            QuotaObservation(
                provider: .claude,
                windowID: "cinder_cove",
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
        // 30 points across the full day, not the 6%/h the last ten minutes show.
        XCTAssertEqual(runway.percentPerHour ?? -1, 1.25, accuracy: 0.01)
        // `now` does read those ten minutes: the latest step (one point) over
        // the time since the step before it landed. The eight-hour-old boundary
        // sample is past the lookback's slack, so it cannot become the anchor.
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 6.0, accuracy: 0.01)
        XCTAssertEqual(runway.nowSpan ?? -1, 600, accuracy: 1)
        XCTAssertEqual(
            (runway.estimatedDepletionAt ?? now).timeIntervalSince(now) / 3600,
            40,
            accuracy: 0.01
        )
    }

    func testRunwayAveragesOverTrailingWindowInsteadOfLastTickBurst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(4 * 3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 50, resetsAt: reset)
        // 30 samples at 60s spacing: flat at 51% for ~29 minutes, then a single
        // 1% drop in the last tick. A last-two-sample slope would read this as
        // 60%/h and cry "would run out"; the twenty-minute average sees 3%/h,
        // and `now` reads 12%/h because one integer point is the whole
        // resolution a five-minute window has. The estimate follows the
        // average, so the drop lands past the reset and nothing is claimed.
        var observations: [QuotaObservation] = []
        for k in stride(from: 29, through: 1, by: -1) {
            observations.append(
                QuotaObservation(
                    provider: .codex, windowID: "five_hour", remainingPercent: 51,
                    observedAt: now.addingTimeInterval(-Double(k) * 60), resetsAt: reset
                )
            )
        }
        observations.append(
            QuotaObservation(
                provider: .codex, windowID: "five_hour", remainingPercent: 50,
                observedAt: now, resetsAt: reset
            )
        )

        let runway = QuotaTrendTracker.runway(
            provider: .codex,
            window: window,
            observations: observations,
            now: now
        )

        XCTAssertEqual(runway.status, .safe)
        XCTAssertEqual(runway.percentPerHour ?? -1, 3.0, accuracy: 0.05)
        // One point dropped somewhere in the 29 flat minutes since the pool
        // began, and nothing says where: reading it over the last five would
        // assume the drain belongs to them. `now` spreads it over the span the
        // evidence actually covers.
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 60.0 / 29, accuracy: 0.05)
        XCTAssertEqual(runway.nowSpan ?? -1, 1740, accuracy: 1)
        XCTAssertGreaterThan(runway.estimatedDepletionAt ?? now, reset)
    }

    func testRunwaySubMinuteDepletionReadsUnderAMinute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 99, resetsAt: reset)
        // 3% -> 1% over 60s = 120%/h, so 1% remaining depletes in ~30s.
        let observations = [
            QuotaObservation(
                provider: .codex, windowID: "five_hour", remainingPercent: 3,
                observedAt: now.addingTimeInterval(-60), resetsAt: reset
            ),
            QuotaObservation(
                provider: .codex, windowID: "five_hour", remainingPercent: 1,
                observedAt: now, resetsAt: reset
            )
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .codex,
            window: window,
            observations: observations,
            now: now
        )

        XCTAssertEqual(runway.status, .atRisk)
        XCTAssertEqual(runway.message, "would run out in under a minute")
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

    // MARK: Retention

    func testRetentionBoundsEachWindowIndependently() {
        // Five windows sampled once a minute for 90 minutes. The old global
        // 200-observation cap left each of them ~40 samples — under an hour —
        // so the long average had nothing to read no matter how it was defined.
        let now = bucketAlignedNow
        let ids = ["five_hour", "seven_day", "primary", "secondary", "credit"]
        let history = ids.flatMap { id in
            (0...89).reversed().map { observation(id, remaining: 90, minutesAgo: Double($0), from: now) }
        }

        let kept = QuotaTrendTracker.record(existing: history, states: [], at: now)

        XCTAssertEqual(kept.count, ids.count * 67)
        for id in ids {
            let mine = kept.filter { $0.windowID == id }
            // 61 samples inside the full-fidelity hour + 6 decimated buckets.
            XCTAssertEqual(mine.count, 67, id)
            XCTAssertEqual(
                now.timeIntervalSince(mine.first?.observedAt ?? now) / 60, 89, accuracy: 0.001, id
            )
        }
    }

    func testRetentionKeepsRecentSamplesWholeAndThinsOlderOnesToFiveMinutes() {
        let now = bucketAlignedNow
        let history = (0...175).reversed().map {
            observation("five_hour", remaining: 90, minutesAgo: Double($0), from: now)
        }

        let kept = QuotaTrendTracker.record(existing: history, states: [], at: now)

        let recent = kept.filter { now.timeIntervalSince($0.observedAt) <= 3600 }
        XCTAssertEqual(recent.count, 61, "every sample inside the last hour survives")
        let older = kept.filter { now.timeIntervalSince($0.observedAt) > 3600 }
        XCTAssertEqual(older.count, 23)
        let gaps = zip(older, older.dropFirst()).map { $1.observedAt.timeIntervalSince($0.observedAt) }
        XCTAssertTrue(gaps.allSatisfy { $0 == QuotaTrendTracker.decimationInterval }, "\(gaps)")
    }

    func testRetentionIsIdempotentAcrossRefreshes() {
        let now = bucketAlignedNow
        let history = (0...175).reversed().map {
            observation("five_hour", remaining: 90, minutesAgo: Double($0), from: now)
        }

        let once = QuotaTrendTracker.record(existing: history, states: [], at: now)
        let twice = QuotaTrendTracker.record(existing: once, states: [], at: now)
        let thrice = QuotaTrendTracker.record(existing: twice, states: [], at: now)

        XCTAssertEqual(once, twice, "re-thinning kept history must be a no-op")
        XCTAssertEqual(twice, thrice)

        // Buckets are fixed on the epoch clock, not on `now`, so samples already
        // past the full-fidelity edge are not re-thinned as time moves on.
        let edge = now.addingTimeInterval(-QuotaTrendTracker.fullFidelitySpan)
        let advanced = QuotaTrendTracker.record(existing: once, states: [], at: now.addingTimeInterval(30 * 60))
        XCTAssertEqual(
            advanced.filter { $0.observedAt <= edge },
            once.filter { $0.observedAt <= edge }
        )
    }

    func testRetentionDropsObservationsOlderThanADay() {
        let now = bucketAlignedNow
        let history = [
            observation("five_hour", remaining: 90, minutesAgo: 25 * 60, from: now),
            observation("five_hour", remaining: 89, minutesAgo: 23 * 60, from: now),
            observation("five_hour", remaining: 88, minutesAgo: 0, from: now)
        ]

        let kept = QuotaTrendTracker.record(existing: history, states: [], at: now)

        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.first?.remainingPercent, 89)
    }

    func testRetentionCapsOneWindowAtItsOwnCeilingAndKeepsTheNewest() {
        let now = bucketAlignedNow
        // 500 samples inside the last hour are all full fidelity, so only the
        // per-window hard cap can bound them.
        let history = (0..<500).reversed().map {
            observation("five_hour", remaining: Double($0) / 10, secondsAgo: Double($0) * 7, from: now)
        }

        let kept = QuotaTrendTracker.record(existing: history, states: [], at: now)

        XCTAssertEqual(kept.count, QuotaTrendTracker.maxObservationsPerWindow)
        XCTAssertEqual(kept.last?.observedAt, now)
    }

    // MARK: now vs avg

    func testNowSurfacesABurstTheAverageStillHides() {
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(4 * 3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 16, resetsAt: reset)
        // Flat at 90% for most of the hour, then one point a minute for the last
        // six. This is the case a single averaged number could not distinguish
        // from an idle window: over twenty minutes the burst averages to 18%/h,
        // just under the 21%/h the window can afford, so the estimate stays
        // quiet — while `now` reads 60%/h off the last three minutes and turns
        // the pace line orange. Shortening the average to ten minutes breaks
        // this: it reads 36%/h, over budget, and the separation is lost.
        var observations = (6...60).reversed().map {
            observation("five_hour", remaining: 90, minutesAgo: Double($0), from: now, resetsAt: reset)
        }
        observations += (0...5).reversed().map {
            observation("five_hour", remaining: Double(84 + $0), minutesAgo: Double($0), from: now, resetsAt: reset)
        }

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )

        XCTAssertEqual(runway.percentPerHour ?? -1, 18.0, accuracy: 0.01)
        XCTAssertEqual(runway.avgSpan ?? -1, 1200, accuracy: 1)
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 60.0, accuracy: 0.01)
        XCTAssertEqual(runway.nowSpan ?? -1, 180, accuracy: 1)
        // avg drives the run-out estimate, which stays quiet…
        XCTAssertEqual(runway.status, .safe)
        XCTAssertGreaterThan(runway.estimatedDepletionAt ?? now, reset)
        // …while `now` is ~3x the even-spread budget the pace line compares against.
        XCTAssertEqual(runway.safePercentPerHour ?? -1, 21.0, accuracy: 0.01)
    }

    func testNowIsOmittedWhenNothingRecentEnoughExists() {
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(4 * 3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 30, resetsAt: reset)
        // Three hours between samples — well past the background cadence — says
        // nothing about the present, so the pace line drops the `now` segment
        // rather than pass an hours-old slope off as current.
        let observations = [
            observation("five_hour", remaining: 90, minutesAgo: 180, from: now, resetsAt: reset),
            observation("five_hour", remaining: 70, minutesAgo: 0, from: now, resetsAt: reset)
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )

        XCTAssertNil(runway.nowPercentPerHour)
        XCTAssertNil(runway.nowSpan)
        XCTAssertNotNil(runway.percentPerHour)
    }

    func testNowStretchesAcrossASamplingGapAndSaysHowFar() {
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(4 * 3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 30, resetsAt: reset)
        func runway(gapMinutes: Double) -> QuotaRunway {
            QuotaTrendTracker.runway(
                provider: .claude,
                window: window,
                observations: [
                    observation("five_hour", remaining: 90, minutesAgo: 120, from: now, resetsAt: reset),
                    observation("five_hour", remaining: 75, minutesAgo: gapMinutes, from: now, resetsAt: reset),
                    observation("five_hour", remaining: 70, minutesAgo: 0, from: now, resetsAt: reset)
                ],
                now: now
            )
        }

        // Both sit inside `nowStepLookback`, so both report, and `nowSpan`
        // tells the tooltip the truth rather than implying the reading is
        // instantaneous. The five-minute slice used to cut the second one off
        // as "too stale"; the bound that remains is the lookback hour, which
        // `testLongWindowNowIsOmittedWhenAGapLeavesOnlyTheCurrentSample`
        // exercises on the far side.
        let bridged = runway(gapMinutes: 7.5)
        XCTAssertEqual(bridged.nowSpan ?? -1, 450, accuracy: 1)
        XCTAssertEqual(bridged.nowPercentPerHour ?? -1, 40.0, accuracy: 0.01)

        let wider = runway(gapMinutes: 8)
        XCTAssertEqual(wider.nowSpan ?? -1, 480, accuracy: 1)
        XCTAssertEqual(wider.nowPercentPerHour ?? -1, 37.5, accuracy: 0.01)
        XCTAssertNotNil(wider.percentPerHour)
    }

    func testBurstInsideTheSliceIsReadOnTheSlice() {
        // `nowMaximumSpan` is no longer a ceiling on what `now` may read, but a
        // burst crossing `nowTriggerPercent` inside it still wins over the step
        // anchor, so a spike is reported on the few minutes it happened in
        // rather than smeared across the span between the last two steps.
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 25, resetsAt: reset)
        var observations: [QuotaObservation] = []
        for k in stride(from: 120, through: 5, by: -1) {
            observations.append(
                observation("seven_day", remaining: 80, minutesAgo: Double(k), from: now, resetsAt: reset)
            )
        }
        for (offset, remaining) in [(4.0, 79.0), (3.0, 78.0), (2.0, 77.0), (1.0, 76.0), (0.0, 75.0)] {
            observations.append(
                observation("seven_day", remaining: remaining, minutesAgo: offset, from: now, resetsAt: reset)
            )
        }

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )

        XCTAssertLessThanOrEqual(runway.nowSpan ?? .infinity, QuotaTrendTracker.nowMaximumSpan)
        XCTAssertEqual(runway.nowSpan ?? -1, 180, accuracy: 1)
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 60.0, accuracy: 0.01)
        // Two hours of history against a 24-hour average span: 5 points / 2h.
        XCTAssertEqual(runway.percentPerHour ?? -1, 2.5, accuracy: 0.01)
        XCTAssertEqual(runway.avgSpan ?? -1, 7200, accuracy: 1)
    }

    func testNowStillReportsWhenItCanOnlyRepeatTheAverage() {
        // Two minutes of history: the only span `now` can read is the span
        // `avg` already reads. The row prints the same number twice, which is
        // honest for a history this young — hiding it instead read as the
        // segment having been removed, for the whole first hour after an
        // install or a wake.
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(4 * 3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 10, resetsAt: reset)
        let observations = [
            observation("five_hour", remaining: 91, minutesAgo: 2, from: now, resetsAt: reset),
            observation("five_hour", remaining: 90, minutesAgo: 0, from: now, resetsAt: reset)
        ]

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )

        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 30.0, accuracy: 0.01)
        XCTAssertEqual(runway.nowSpan ?? -1, 120, accuracy: 1)
        XCTAssertEqual(runway.percentPerHour ?? -1, 30.0, accuracy: 0.01)
        XCTAssertEqual(runway.avgSpan ?? -1, 120, accuracy: 1)
    }

    func testLongWindowNowReadsTheLatestWholePointStepWhenFiveMinutesShowNothing() {
        // The weekly integer moves once every twenty-odd minutes at an ordinary
        // pace, so a five-minute slice is flat almost always. Reading it gave
        // `now 0%/h` for a window that is plainly draining. Instead: the latest
        // step, over the time since the one before it landed.
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 22, resetsAt: reset)
        func remaining(_ minutesAgo: Int, stepsAt: [Int]) -> Double {
            80 - Double(stepsAt.filter { minutesAgo <= $0 }.count)
        }
        func runway(stepsAt: [Int]) -> QuotaRunway {
            let observations = (0...120).reversed().map {
                observation(
                    "seven_day", remaining: remaining($0, stepsAt: stepsAt), minutesAgo: Double($0),
                    from: now, resetsAt: reset
                )
            }
            return QuotaTrendTracker.runway(provider: .claude, window: window, observations: observations, now: now)
        }

        // Steps landed 40 and 16 minutes ago. The anchor is the sample right
        // after the earlier one, so the later step (one point) is read over the
        // 40 minutes it has had so far: 1.5%/h, fading from the 2.5%/h it read
        // the moment it landed.
        let faded = runway(stepsAt: [40, 16])
        XCTAssertEqual(faded.nowPercentPerHour ?? -1, 1.5, accuracy: 0.01)
        XCTAssertEqual(faded.nowSpan ?? -1, 2400, accuracy: 1)
        // avg still covers the whole two hours: 2 points / 2h.
        XCTAssertEqual(faded.percentPerHour ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(faded.avgSpan ?? -1, 7200, accuracy: 1)

        // The step lands on this very refresh: the five-minute slice holds one
        // point, which the old reading turned into a 12%/h spike for the next
        // five minutes. The step anchor reads the step's actual pace instead.
        let fresh = runway(stepsAt: [24, 0])
        XCTAssertEqual(fresh.nowPercentPerHour ?? -1, 2.5, accuracy: 0.01)
        XCTAssertEqual(fresh.nowSpan ?? -1, 1440, accuracy: 1)
    }

    func testPerStylePolicyIsDecidedInOnePlace() {
        // `avg` is the only rate whose span still depends on the horizon, and
        // that decision has one owner. `.hidden` reads long, which the runway
        // status uses. `now` no longer branches on style at all — every window
        // anchors on its latest whole-point step.
        XCTAssertEqual(QuotaTrendTracker.averageSpan(for: .paceVersusBudget), QuotaTrendTracker.shortAverageSpan)
        XCTAssertEqual(QuotaTrendTracker.averageSpan(for: .paceOnly), QuotaTrendTracker.longAverageSpan)
        XCTAssertEqual(QuotaTrendTracker.averageSpan(for: .hidden), QuotaTrendTracker.longAverageSpan)
    }

    func testLongWindowNowIsOmittedWhenAGapLeavesOnlyTheCurrentSample() {
        // First refresh after a lid-closed gap of 90 min to a day: the pool
        // has old samples and this one. The step anchor's sparse floor used to
        // be `current` itself, reading `now 0%/h` over a zero-second span —
        // five points fell across the gap and 0 is not a reading of anything.
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 25, resetsAt: reset)
        func runway(_ shape: [(minutesAgo: Double, remaining: Double)]) -> QuotaRunway {
            let observations = shape.map {
                observation("seven_day", remaining: $0.remaining, minutesAgo: $0.minutesAgo, from: now, resetsAt: reset)
            }
            return QuotaTrendTracker.runway(provider: .claude, window: window, observations: observations, now: now)
        }

        let single = runway([(180, 80), (0, 75)])
        XCTAssertNil(single.nowPercentPerHour)
        XCTAssertNil(single.nowSpan)
        XCTAssertNil(single.nowAnchor)
        XCTAssertNotNil(single.percentPerHour, "avg still reads the gap")

        // An old step before the gap does not rescue it: the step before the
        // latest one is hours back, and nothing inside the hour anchors a span.
        let stepped = runway([(180, 80), (170, 79), (0, 75)])
        XCTAssertNil(stepped.nowPercentPerHour)

        // One earlier sample inside the hour is enough to read from.
        let bridged = runway([(180, 80), (30, 79), (0, 78)])
        XCTAssertEqual(bridged.nowPercentPerHour ?? -1, 2.0, accuracy: 0.01)
        XCTAssertEqual(bridged.nowSpan ?? -1, 1800, accuracy: 1)
    }

    func testNowNeverReadsASpanShorterThanTheMinimumOnAnyWindow() {
        // The young-history escape for step-anchored windows must not let one
        // refresh be the whole reading: a point landing a minute into a fresh
        // pool would print 60%/h on the weekly row.
        let now = bucketAlignedNow
        let weekly = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 36, resetsAt: now.addingTimeInterval(6 * 24 * 3600))
        let oneMinute = QuotaTrendTracker.runway(
            provider: .claude, window: weekly,
            observations: [
                observation("seven_day", remaining: 65, minutesAgo: 1, from: now, resetsAt: weekly.resetsAt),
                observation("seven_day", remaining: 64, minutesAgo: 0, from: now, resetsAt: weekly.resetsAt)
            ],
            now: now
        )
        XCTAssertNil(oneMinute.nowPercentPerHour)
        XCTAssertNotNil(oneMinute.percentPerHour)

        let twoMinutes = QuotaTrendTracker.runway(
            provider: .claude, window: weekly,
            observations: [
                observation("seven_day", remaining: 65, minutesAgo: 2, from: now, resetsAt: weekly.resetsAt),
                observation("seven_day", remaining: 65, minutesAgo: 1, from: now, resetsAt: weekly.resetsAt),
                observation("seven_day", remaining: 64, minutesAgo: 0, from: now, resetsAt: weekly.resetsAt)
            ],
            now: now
        )
        XCTAssertEqual(twoMinutes.nowPercentPerHour ?? -1, 30.0, accuracy: 0.01, "exactly the minimum span reads")
        XCTAssertEqual(twoMinutes.nowSpan ?? -1, 120, accuracy: 1)
    }

    func testNowAnchorKindNamesHowTheSpanWasChosen() {
        let now = bucketAlignedNow
        let weeklyReset = now.addingTimeInterval(6 * 24 * 3600)
        let weekly = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 22, resetsAt: weeklyReset)
        func weeklyRunway(_ remaining: (Int) -> Double) -> QuotaRunway {
            let observations = (0...120).reversed().map {
                observation("seven_day", remaining: remaining($0), minutesAgo: Double($0), from: now, resetsAt: weeklyReset)
            }
            return QuotaTrendTracker.runway(provider: .claude, window: weekly, observations: observations, now: now)
        }

        // Steps 40 and 16 minutes ago: the span runs back to the earlier step.
        XCTAssertEqual(
            weeklyRunway { minute in 80 - Double([40, 16].filter { minute <= $0 }.count) }.nowAnchor,
            QuotaNowAnchor.step
        )
        // Flat for the whole two hours of history: past what a shared window's
        // shape explains, so the reading is dormancy rather than a rate.
        XCTAssertEqual(weeklyRunway { _ in 80 }.nowAnchor, QuotaNowAnchor.dormant)
        // One step inside the hour, none before it inside the hour: still the floor.
        XCTAssertEqual(weeklyRunway { $0 <= 30 ? 79 : 80 }.nowAnchor, QuotaNowAnchor.lookback)
        // Three points inside two minutes: a burst, read like a short window.
        let burst = weeklyRunway { $0 >= 2 ? 80 : ($0 == 1 ? 78 : 77) }
        XCTAssertEqual(burst.nowAnchor, QuotaNowAnchor.burst)
        XCTAssertEqual(burst.nowSpan ?? -1, 120, accuracy: 1)

        // Short window, one point four minutes ago and nothing before it inside
        // the hour: the same lookback floor a weekly gets. A 5-hour window reads
        // `now` by the same rule as every other window.
        let fiveHourReset = now.addingTimeInterval(4 * 3600)
        let fiveHour = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 21, resetsAt: fiveHourReset)
        let slice = QuotaTrendTracker.runway(
            provider: .claude, window: fiveHour,
            observations: (0...120).reversed().map {
                observation("five_hour", remaining: $0 <= 4 ? 79 : 80, minutesAgo: Double($0), from: now, resetsAt: fiveHourReset)
            },
            now: now
        )
        XCTAssertEqual(slice.nowAnchor, QuotaNowAnchor.lookback)
        XCTAssertEqual(slice.nowSpan ?? -1, 3600, accuracy: 1)
        XCTAssertEqual(slice.nowPercentPerHour ?? -1, 1.0, accuracy: 0.01)
    }

    func testSteadyIntegerDrainSurvivesADayOfDecimatedHistory() {
        // The fractional sibling above exercises the no-step floor; live data
        // is whole integers, so here a point lands once an hour and `now`
        // has to come through the thinning by the step path's floor: the
        // latest step landed 59 minutes ago, the one before it two hours ago,
        // so the reading is one point over the lookback hour.
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(90 * 24 * 3600)
        let window = QuotaWindow(
            id: "credit", label: "Included credit", usedPercent: 27, resetsAt: reset,
            isOneTimeCredit: true
        )
        let raw = (0...(23 * 60)).reversed().map {
            observation("credit", remaining: 73 + Double($0 / 60), minutesAgo: Double($0), from: now, resetsAt: reset)
        }
        let history = QuotaTrendTracker.record(existing: raw, states: [], at: now)
        XCTAssertLessThan(history.count, raw.count)

        let runway = QuotaTrendTracker.runway(provider: .claude, window: window, observations: history, now: now)

        XCTAssertEqual(runway.percentPerHour ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(runway.nowSpan ?? -1, 3600, accuracy: 1)
        XCTAssertEqual(runway.nowAnchor, QuotaNowAnchor.lookback)
    }

    func testLongWindowNowStaysWhileHistoryIsShorterThanTheStepLookback() {
        // After a weekend closed-lid gap the 24-hour age cap had emptied the
        // pool, and for the next hour the weekly rows showed only `avg`: the
        // step anchor's floor was the whole pool, which is also what `avg`
        // read, and the short-window "same span twice" rule hid it. A `now`
        // that equals `avg` is honest for a young history; a missing one read
        // as the segment having been removed.
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 36, resetsAt: reset)
        let observations = (0...40).reversed().map {
            observation("seven_day", remaining: $0 > 10 ? 65 : 64, minutesAgo: Double($0), from: now, resetsAt: reset)
        }

        let runway = QuotaTrendTracker.runway(provider: .claude, window: window, observations: observations, now: now)

        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 1.5, accuracy: 0.01, "one point over the 40 minutes there are")
        XCTAssertEqual(runway.nowSpan ?? -1, 2400, accuracy: 1)
        XCTAssertEqual(runway.percentPerHour ?? -1, 1.5, accuracy: 0.01)
        XCTAssertEqual(runway.avgSpan ?? -1, 2400, accuracy: 1)

        // The 5-hour window reads the same way on a history just as young:
        // one point across the three minutes there are.
        let short = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 36, resetsAt: now.addingTimeInterval(4 * 3600))
        let young = (0...3).reversed().map {
            observation("five_hour", remaining: $0 > 1 ? 65 : 64, minutesAgo: Double($0), from: now, resetsAt: short.resetsAt)
        }
        let shortRunway = QuotaTrendTracker.runway(provider: .claude, window: short, observations: young, now: now)
        XCTAssertEqual(shortRunway.nowPercentPerHour ?? -1, 20.0, accuracy: 0.01)
        XCTAssertEqual(shortRunway.nowSpan ?? -1, 180, accuracy: 1)
        XCTAssertNotNil(shortRunway.percentPerHour)
    }

    func testLongWindowNowIsFlooredAtTheStepLookback() {
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 21, resetsAt: reset)
        func runway(_ remaining: (Int) -> Double) -> QuotaRunway {
            let observations = (0...120).reversed().map {
                observation("seven_day", remaining: remaining($0), minutesAgo: Double($0), from: now, resetsAt: reset)
            }
            return QuotaTrendTracker.runway(provider: .claude, window: window, observations: observations, now: now)
        }

        // Steps 99 and 30 minutes ago: the earlier one sits outside the hour,
        // so the anchor is the carry-forward sample at the lookback boundary and
        // the reading is "one point in the last hour".
        let sparse = runway { $0 <= 99 ? ($0 <= 30 ? 79 : 80) : 81 }
        XCTAssertEqual(sparse.nowPercentPerHour ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(sparse.nowSpan ?? -1, 3600, accuracy: 1)

        XCTAssertFalse(sparse.nowIsUpperBound)

        // No step at all inside the hour. Utilization is whole points, so this
        // is not "0%/h" — it is "under one point in the 90 minutes since the
        // window last moved", and the row renders the figure with a `<`. The
        // bound reads past the lookback on purpose: a longer flat stretch is a
        // tighter claim, so an idle window keeps converging toward zero instead
        // of parking at one point per hour.
        let idle = runway { $0 <= 90 ? 80 : 81 }
        XCTAssertEqual(idle.nowPercentPerHour ?? -1, 1 / 1.5, accuracy: 0.01)
        XCTAssertEqual(idle.nowSpan ?? -1, 5400, accuracy: 1)
        XCTAssertTrue(idle.nowIsUpperBound)
        XCTAssertEqual(idle.percentPerHour ?? -1, 0.5, accuracy: 0.01)
    }

    func testFlatButYoungHistoryIsABoundRatherThanDormancy() {
        // Half an hour of samples, nothing moved. That is inside what a shared
        // window's shape explains, so it stays a ceiling on the rate instead of
        // claiming the window has stopped.
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 20, resetsAt: reset)
        let observations = (0...29).reversed().map {
            observation("seven_day", remaining: 80, minutesAgo: Double($0), from: now, resetsAt: reset)
        }

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )

        XCTAssertEqual(runway.nowAnchor, QuotaNowAnchor.flat)
        XCTAssertTrue(runway.nowIsUpperBound)
        XCTAssertEqual(runway.nowSpan ?? -1, 29 * 60, accuracy: 1)
    }

    func testModelScopedWindowGoesDormantWhereASharedOneStillReadsARate() {
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        // Steps at minute 17 and minute 12, then twelve minutes of silence.
        func history(_ id: String) -> [QuotaObservation] {
            (0...60).reversed().map { minute in
                let remaining: Double = minute <= 12 ? 80 : (minute <= 17 ? 81 : 82)
                return observation(id, remaining: remaining, minutesAgo: Double(minute), from: now, resetsAt: reset)
            }
        }

        let scoped = QuotaWindow(
            id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 20,
            resetsAt: reset, isModelScoped: true, cycle: 7 * 24 * 3600
        )
        let dormant = QuotaTrendTracker.runway(
            provider: .claude, window: scoped, observations: history("seven_day_fable"), now: now
        )
        XCTAssertEqual(dormant.nowAnchor, QuotaNowAnchor.dormant)
        XCTAssertEqual(dormant.nowSpan ?? -1, 12 * 60, accuracy: 1)
        XCTAssertTrue(dormant.nowIsUpperBound)
        XCTAssertEqual(QuotaRow.pace(dormant)?.text.hasPrefix("now flat 12m"), true,
                       QuotaRow.pace(dormant)?.text ?? "no pace line")

        let shared = QuotaWindow(
            id: "seven_day", label: "Weekly", usedPercent: 20,
            resetsAt: reset, cycle: 7 * 24 * 3600
        )
        let measured = QuotaTrendTracker.runway(
            provider: .claude, window: shared, observations: history("seven_day"), now: now
        )
        XCTAssertEqual(measured.nowAnchor, QuotaNowAnchor.step)
        XCTAssertFalse(measured.nowIsUpperBound)
        // One point over the seventeen minutes since the step before the latest.
        XCTAssertEqual(measured.nowPercentPerHour ?? -1, 60.0 / 17, accuracy: 0.01)
    }

    func testFlatThresholdFollowsWhetherTheProviderScopedTheWindow() {
        let scoped = QuotaWindow(id: "seven_day_fable", label: "Weekly (Fable)", usedPercent: 20,
                                 resetsAt: nil, isModelScoped: true)
        let shared = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 20, resetsAt: nil)
        let unstated = QuotaWindow(id: "premium", label: "Premium", usedPercent: 20, resetsAt: nil)
        XCTAssertEqual(QuotaTrendTracker.flatThreshold(for: scoped), QuotaTrendTracker.modelScopedFlatThreshold)
        XCTAssertEqual(QuotaTrendTracker.flatThreshold(for: shared), QuotaTrendTracker.nowStepLookback)
        // Not stated reads as not scoped, so an unknown provider never gets the
        // shorter threshold by accident.
        XCTAssertEqual(QuotaTrendTracker.flatThreshold(for: unstated), QuotaTrendTracker.nowStepLookback)
    }

    func testShortWindowNowReadsTheLatestStepInsteadOfAFlatSlice() {
        // The reported case. A 5-hour window draining ~3%/h drops a point every
        // twenty minutes, so the five-minute slice this used to read was flat
        // three ticks in four and the row said `now 0%/h` through an active
        // session. The step anchor reads the span the points actually span.
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(4 * 3600)
        let window = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 22, resetsAt: reset)
        let observations = (0...120).reversed().map {
            observation(
                "five_hour", remaining: $0 <= 40 ? ($0 <= 16 ? 78 : 79) : 80, minutesAgo: Double($0),
                from: now, resetsAt: reset
            )
        }

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now
        )

        // Steps 40 and 16 minutes ago: one point over the 40 minutes since the
        // earlier one, measured rather than bounded.
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 1.5, accuracy: 0.01)
        XCTAssertEqual(runway.nowSpan ?? -1, 2400, accuracy: 1)
        XCTAssertEqual(runway.nowAnchor, QuotaNowAnchor.step)
        XCTAssertFalse(runway.nowIsUpperBound)
        // avg over its 20 minutes: the 16-minute-old step.
        XCTAssertEqual(runway.percentPerHour ?? -1, 3.0, accuracy: 0.01)
    }

    func testSteadyDrainSurvivesADayOfDecimatedHistory() {
        let now = bucketAlignedNow
        let reset = now.addingTimeInterval(90 * 24 * 3600)
        let window = QuotaWindow(
            id: "credit", label: "Included credit", usedPercent: 27, resetsAt: reset,
            isOneTimeCredit: true
        )
        // 23 hours of once-a-minute samples draining a steady 1%/h. Retention
        // thins everything past the last hour to one sample per five minutes;
        // both rates have to come through that intact.
        let raw = (0...(23 * 60)).reversed().map {
            observation("credit", remaining: 73 + Double($0) / 60, minutesAgo: Double($0), from: now, resetsAt: reset)
        }
        let history = QuotaTrendTracker.record(existing: raw, states: [], at: now)
        XCTAssertLessThan(history.count, raw.count)

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: history, now: now
        )

        XCTAssertEqual(runway.percentPerHour ?? -1, 1.0, accuracy: 0.01)
        // A steady 1%/h drain moves 0.08 points in five minutes, under the
        // 0.1-point floor that separates real drain from rounding, and never
        // takes a whole-point step between two samples either. On this
        // long-horizon window `now` therefore falls back to the step lookback
        // floor and reads the hour: the one span here long enough to see the
        // movement, and the same number `avg` reads.
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(runway.nowSpan ?? -1, 3600, accuracy: 1)
        XCTAssertEqual(runway.status, .atRisk)
        XCTAssertEqual(
            (runway.estimatedDepletionAt ?? now).timeIntervalSince(now) / 3600, 73, accuracy: 0.5
        )
    }

    func testTrackerClassifiesPaceStyleByCycleThenResetHorizon() {
        let now = Date(timeIntervalSince1970: 1_000)
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour
        func style(resetIn: TimeInterval?, cycle: TimeInterval?) -> QuotaPaceStyle {
            QuotaTrendTracker.paceStyle(
                resetsAt: resetIn.map { now.addingTimeInterval($0) }, cycle: cycle, now: now
            )
        }

        // No stated cycle: time-to-reset decides, as it always did.
        XCTAssertEqual(style(resetIn: nil, cycle: nil), .hidden)
        XCTAssertEqual(style(resetIn: 3 * hour, cycle: nil), .paceVersusBudget)
        XCTAssertEqual(
            style(resetIn: QuotaTrendTracker.longWindowHorizon, cycle: nil),
            .paceVersusBudget,
            "exactly at the horizon still counts as a short window"
        )
        XCTAssertEqual(style(resetIn: 6 * day, cycle: nil), .paceOnly)

        // A credible cycle decides ahead of the time to reset.
        XCTAssertEqual(
            style(resetIn: 6 * hour, cycle: 7 * day),
            .paceOnly,
            "a weekly inside its last day must not grow a budget segment — the case this rule exists for"
        )
        XCTAssertEqual(
            style(resetIn: 7 * day, cycle: 7 * day),
            .paceOnly,
            "a reset exactly one cycle away is still credible"
        )
        XCTAssertEqual(style(resetIn: 3 * hour, cycle: 5 * hour), .paceVersusBudget)
        XCTAssertEqual(
            style(resetIn: 3 * hour, cycle: 7 * day),
            .paceOnly,
            "credible, so the cycle wins over a reset inside the horizon"
        )
        XCTAssertEqual(style(resetIn: nil, cycle: 7 * day), .hidden, "no reset means no budget, whatever the cycle")

        // A reset further out than one cycle is not describing a cadence, so
        // the time rule takes over.
        XCTAssertEqual(style(resetIn: 30 * hour, cycle: 5 * hour), .paceOnly)
        XCTAssertEqual(style(resetIn: 8 * day, cycle: 7 * day), .paceOnly)

        // A reset already in the past is stale data, not a cadence: the time
        // rule takes over and its nil budget keeps the line off the row.
        XCTAssertEqual(style(resetIn: -1 * hour, cycle: 7 * day), .paceVersusBudget)
    }

    /// Keying the style on the cycle is not purely warning-suppressing: the
    /// style also picks the `avg` span, and the 24 h span can carry a run-out
    /// the 20-minute span had just lost. A weekly in its last day that drained
    /// 75 → 45 over three hours and then idled for twenty minutes reads "pace
    /// steady" with no cycle (the old time-to-reset rule, still the fallback)
    /// and "would run out" with its 7-day cycle — the intended, consistent
    /// weekly reading, pinned here so the docs can say exactly that.
    func testWeeklyInItsLastDayKeepsTheLongSpanRunOut() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(6 * 3600)
        var history = staircase(
            "seven_day", from: 75, to: 45, steps: 30, overMinutes: 180,
            now: now.addingTimeInterval(-20 * 60), resetsAt: reset
        )
        for minutesAgo in [15.0, 10, 5, 0] {
            history.append(observation("seven_day", remaining: 45, minutesAgo: minutesAgo, from: now, resetsAt: reset))
        }
        let timeRuled = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 55, resetsAt: reset, cycle: nil)
        let cycleRuled = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 55, resetsAt: reset, cycle: 7 * 24 * 3600)

        let short = QuotaTrendTracker.runway(
            provider: .claude, window: timeRuled, observations: history, now: now, peerWindows: [timeRuled]
        )
        let long = QuotaTrendTracker.runway(
            provider: .claude, window: cycleRuled, observations: history, now: now, peerWindows: [cycleRuled]
        )

        XCTAssertEqual(short.paceStyle, .paceVersusBudget)
        XCTAssertNotEqual(short.status, .atRisk, "the 20-minute span saw only the idle tail")
        XCTAssertNil(QuotaRow.alertLine(short, now: now))
        XCTAssertEqual(long.paceStyle, .paceOnly)
        XCTAssertEqual(long.status, .atRisk, "the 24 h span still carries the three-hour drain")
        XCTAssertNotNil(QuotaRow.alertLine(long, now: now))
    }

    /// The other side of the same coin: a wrong *long* cycle on a short window
    /// raises an alarm rather than hiding one. A 5-hour window draining 50 → 30
    /// over two hours with 3.5 h to reset reads `.watch` on its true cycle
    /// (twenty minutes of evidence cannot project three hours) and `.atRisk`
    /// with a date once the cycle claims a week. Pinned so the `cycle` rule in
    /// providers.md can say what this rule adds instead of claiming it only
    /// suppresses.
    func testAnInflatedCycleRaisesRatherThanHidesARunOut() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3.5 * 3600)
        let history = staircase("five_hour", from: 50, to: 30, steps: 20, overMinutes: 120, now: now, resetsAt: reset)
        let trueCycle = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 70, resetsAt: reset, cycle: 5 * 3600)
        let inflated = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 70, resetsAt: reset, cycle: 7 * 24 * 3600)

        let honest = QuotaTrendTracker.runway(
            provider: .claude, window: trueCycle, observations: history, now: now, peerWindows: [trueCycle]
        )
        let lying = QuotaTrendTracker.runway(
            provider: .claude, window: inflated, observations: history, now: now, peerWindows: [inflated]
        )

        XCTAssertEqual(honest.status, .watch)
        XCTAssertNil(honest.estimatedDepletionAt)
        XCTAssertEqual(lying.status, .atRisk)
        XCTAssertNotNil(lying.estimatedDepletionAt)
    }

    /// A weekly whose reset has already passed — a snapshot kept through an
    /// OAuth failure, or the seconds between the reset and the next tick — is
    /// stale data, not a cadence. Without a lower bound on the credibility
    /// test, `untilReset <= cycle` held for a negative `untilReset`, and the
    /// row grew an "avg" line beside "resets now" where the time rule's nil
    /// budget had always kept it clean.
    func testWeeklyPastItsResetShowsNoPaceLine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(-3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 53, resetsAt: reset, cycle: 7 * 24 * 3600)
        let observations = staircase("seven_day", from: 53, to: 47, steps: 6, overMinutes: 60, now: now, resetsAt: reset)

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [window]
        )

        XCTAssertEqual(runway.paceStyle, .paceVersusBudget)
        XCTAssertNil(QuotaRow.pace(runway))
    }

    /// The evidence gate follows the pace style, so a weekly in its last day
    /// is still held to the long-window minimum: twenty minutes of a fast
    /// drain project a run-out inside the 6x extrapolation limit, but stay
    /// informational until half an hour of history backs them. Keyed on the
    /// reset date, this fixture read `.atRisk` with a date.
    func testLongCycleWindowInItsLastDayStillNeedsEvidenceForARunOut() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(6 * 3600)
        let window = QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 80, resetsAt: reset, cycle: 7 * 24 * 3600)
        let observations = staircase("seven_day", from: 30, to: 20, steps: 4, overMinutes: 20, now: now, resetsAt: reset)

        let runway = QuotaTrendTracker.runway(
            provider: .claude, window: window, observations: observations, now: now, peerWindows: [window]
        )

        XCTAssertEqual(runway.paceStyle, .paceOnly)
        XCTAssertEqual(runway.status, .watch)
        XCTAssertNil(runway.estimatedDepletionAt)
    }

    // MARK: Helpers

    /// Sits exactly on a `decimationInterval` boundary so bucket arithmetic in
    /// the retention tests is exact rather than dependent on epoch alignment.
    private var bucketAlignedNow: Date { Date(timeIntervalSince1970: 1_800_000) }

    private func observation(
        _ windowID: String,
        remaining: Double,
        minutesAgo: Double,
        from now: Date,
        resetsAt: Date? = nil
    ) -> QuotaObservation {
        observation(windowID, remaining: remaining, secondsAgo: minutesAgo * 60, from: now, resetsAt: resetsAt)
    }

    /// Whole-point staircase the way live utilization arrives: `steps` equal
    /// drops from `start` to `end`, spread evenly across `minutes` and ending
    /// at `now`. Pick `steps` so each drop is a whole number of points.
    private func staircase(
        _ windowID: String,
        from start: Double,
        to end: Double,
        steps: Int,
        overMinutes minutes: Double,
        now: Date,
        resetsAt: Date?
    ) -> [QuotaObservation] {
        (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            return observation(
                windowID,
                remaining: start - (start - end) * fraction,
                minutesAgo: minutes * (1 - fraction),
                from: now,
                resetsAt: resetsAt
            )
        }
    }

    private func observation(
        _ windowID: String,
        remaining: Double,
        secondsAgo: Double,
        from now: Date,
        resetsAt: Date? = nil
    ) -> QuotaObservation {
        QuotaObservation(
            provider: .claude,
            windowID: windowID,
            remainingPercent: remaining,
            observedAt: now.addingTimeInterval(-secondsAgo),
            resetsAt: resetsAt
        )
    }
}
