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
        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 12.0, accuracy: 0.05)
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

    func testNowStretchesAcrossASamplingGapUpToTheSlackLimit() {
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

        // 7.5 minutes is past the 5-minute ceiling but exactly on the 1.5x
        // slack, so `now` still reports and `nowSpan` tells the tooltip the
        // truth rather than implying the reading is instantaneous.
        let bridged = runway(gapMinutes: 7.5)
        XCTAssertEqual(bridged.nowSpan ?? -1, 450, accuracy: 1)
        XCTAssertEqual(bridged.nowPercentPerHour ?? -1, 40.0, accuracy: 0.01)

        // Half a minute further out and there is no honest "now" left to report.
        let stale = runway(gapMinutes: 8)
        XCTAssertNil(stale.nowPercentPerHour)
        XCTAssertNil(stale.nowSpan)
        XCTAssertNotNil(stale.percentPerHour)
    }

    func testNowNeverReadsBeyondItsCeilingOnLongHorizonWindows() {
        // A weekly window used to get a 60-minute `now`, which is not "now" at
        // all — it was a second copy of `avg` with a different label. When a
        // burst crosses the trigger inside the five-minute slice, a weekly
        // window reads it exactly like a short one; the step anchor below only
        // takes over when that slice is flat.
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

    func testNowIsOmittedWhenItWouldOnlyRepeatTheAverage() {
        // Two minutes of history: the only span `now` could read is the span
        // `avg` already reads, so the row would print the same number twice
        // under two different labels.
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

        XCTAssertNil(runway.nowPercentPerHour)
        XCTAssertNil(runway.nowSpan)
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
        // Horizon semantics have one owner. `.hidden` keeps the readings it had
        // before the policy was written down: long `avg` (the runway status
        // uses it), short-slice `now` (nothing renders it).
        XCTAssertEqual(QuotaTrendTracker.averageSpan(for: .paceVersusBudget), QuotaTrendTracker.shortAverageSpan)
        XCTAssertEqual(QuotaTrendTracker.averageSpan(for: .paceOnly), QuotaTrendTracker.longAverageSpan)
        XCTAssertEqual(QuotaTrendTracker.averageSpan(for: .hidden), QuotaTrendTracker.longAverageSpan)

        XCTAssertTrue(QuotaTrendTracker.nowAnchorsOnLatestStep(for: .paceOnly))
        XCTAssertFalse(QuotaTrendTracker.nowAnchorsOnLatestStep(for: .paceVersusBudget))
        XCTAssertFalse(QuotaTrendTracker.nowAnchorsOnLatestStep(for: .hidden))

        // Only the step anchor is bounded by a lookback, so only it may report
        // a `now` that spans the same young history as `avg`.
        XCTAssertTrue(QuotaTrendTracker.nowMayEqualAverageSpan(for: .paceOnly))
        XCTAssertFalse(QuotaTrendTracker.nowMayEqualAverageSpan(for: .paceVersusBudget))
        XCTAssertFalse(QuotaTrendTracker.nowMayEqualAverageSpan(for: .hidden))
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
        // Flat hour: the lookback floor.
        XCTAssertEqual(weeklyRunway { _ in 80 }.nowAnchor, QuotaNowAnchor.lookback)
        // One step inside the hour, none before it inside the hour: still the floor.
        XCTAssertEqual(weeklyRunway { $0 <= 30 ? 79 : 80 }.nowAnchor, QuotaNowAnchor.lookback)
        // Three points inside two minutes: a burst, read like a short window.
        let burst = weeklyRunway { $0 >= 2 ? 80 : ($0 == 1 ? 78 : 77) }
        XCTAssertEqual(burst.nowAnchor, QuotaNowAnchor.burst)
        XCTAssertEqual(burst.nowSpan ?? -1, 120, accuracy: 1)

        // Short window, one point four minutes ago: the flat five-minute slice.
        let fiveHourReset = now.addingTimeInterval(4 * 3600)
        let fiveHour = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 21, resetsAt: fiveHourReset)
        let slice = QuotaTrendTracker.runway(
            provider: .claude, window: fiveHour,
            observations: (0...120).reversed().map {
                observation("five_hour", remaining: $0 <= 4 ? 79 : 80, minutesAgo: Double($0), from: now, resetsAt: fiveHourReset)
            },
            now: now
        )
        XCTAssertEqual(slice.nowAnchor, QuotaNowAnchor.slice)
        XCTAssertEqual(slice.nowSpan ?? -1, 300, accuracy: 1)
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

        // The 5-hour window keeps hiding a `now` that would duplicate `avg`;
        // its slice is five minutes, so that lasts five minutes, not an hour.
        let short = QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 36, resetsAt: now.addingTimeInterval(4 * 3600))
        let young = (0...3).reversed().map {
            observation("five_hour", remaining: $0 > 1 ? 65 : 64, minutesAgo: Double($0), from: now, resetsAt: short.resetsAt)
        }
        let shortRunway = QuotaTrendTracker.runway(provider: .claude, window: short, observations: young, now: now)
        XCTAssertNil(shortRunway.nowPercentPerHour)
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

        // No step at all inside the hour: a flat zero across the lookback, so
        // the tooltip says how long the window has sat still — not "0 over 5m".
        let idle = runway { $0 <= 90 ? 80 : 81 }
        XCTAssertEqual(idle.nowPercentPerHour ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(idle.nowSpan ?? -1, 3600, accuracy: 1)
        XCTAssertEqual(idle.percentPerHour ?? -1, 0.5, accuracy: 0.01)
    }

    func testShortWindowNowStillReadsTheFlatFiveMinuteSlice() {
        // Same shape as the weekly case, on a 5-hour window: a point of this
        // pool is a few minutes of ordinary use, so "nothing in five minutes"
        // is a real reading and the step anchor must not stretch it.
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

        XCTAssertEqual(runway.nowPercentPerHour ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(runway.nowSpan ?? -1, 300, accuracy: 1)
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
