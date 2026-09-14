import Foundation

/// Keeps recent quota observations bounded and derives per-window runway.
///
/// Two drain rates come out of the same history, because one number cannot
/// answer both questions the popover is asked:
/// - `now` — a short adaptive span that answers "how fast am I burning right
///   now?", so the user can react in the moment.
/// - `avg` — a long fixed span that answers "at the recent pace, how long will
///   this last?", and is the only rate that drives the run-out estimate.
enum QuotaTrendTracker {
    // MARK: Retention

    /// Observations older than this are dropped.
    static let maxObservationAge: TimeInterval = 60 * 60 * 24
    /// Every sample inside this trailing span is kept, so the `now` rate keeps
    /// refresh-level (about one per minute) resolution.
    static let fullFidelitySpan: TimeInterval = 60 * 60
    /// Beyond `fullFidelitySpan`, one sample per bucket of this size survives.
    /// A day of history stays at a few hundred rows per window — small enough to
    /// rewrite into `last-state.json` on every refresh.
    static let decimationInterval: TimeInterval = 5 * 60
    /// Hard cap per (provider, window). A full day at one sample per five
    /// minutes plus an hour at full fidelity is ~340 rows; this is headroom.
    static let maxObservationsPerWindow = 400

    // MARK: Rates

    /// `avg` span for windows that reset within `longWindowHorizon`. Bounds how
    /// far the run-out estimate can reach, via `maxExtrapolationMultiplier`:
    /// 20 minutes of evidence projects at most 2 hours.
    static let shortAverageSpan: TimeInterval = 20 * 60
    /// `avg` span for longer-horizon windows (weekly, one-time credits).
    static let longAverageSpan: TimeInterval = 24 * 60 * 60
    /// `now` walks back until this many percentage points have drained. Provider
    /// APIs report whole-percent utilization in practice, so a single tick says
    /// nothing about rate; three ticks bound the quantization error to ~±33%.
    /// Defined in points rather than samples so a fractional API needs no change.
    static let nowTriggerPercent: Double = 3
    /// `now` never reads a span shorter than this, so one refresh can't swing it.
    static let nowMinimumSpan: TimeInterval = 2 * 60
    /// Hard ceiling on the slice `now` reads on short-horizon windows. When
    /// `nowTriggerPercent` has not drained inside it, `now` reports the
    /// (near-zero) drain across the slice rather than widening: a rate averaged
    /// over twenty minutes or an hour is not "now", it is a second copy of `avg`.
    ///
    /// Five minutes is a trade against resolution: `utilization` arrives as
    /// whole integers, so a W-minute span resolves only 60/W %/h. Measured
    /// against a real day of samples, a 2-minute span reads a flat 0 for ~42%
    /// of the ticks of an actively draining 5-hour window (~89% for a weekly
    /// one) because the integer has not moved yet in that slice; five minutes
    /// drops that to ~17% at a 12%/h resolution, which is readable against a
    /// short window's 20-50%/h budget. Long-horizon windows do not read this
    /// slice at all unless a burst crosses the trigger inside it; see
    /// `nowStepLookback`.
    static let nowMaximumSpan: TimeInterval = 5 * 60
    /// Long-horizon windows (weekly, one-time credits) move in whole-point
    /// steps that are each a large slice of the pool: at an ordinary pace the
    /// weekly integer ticks every twenty to forty minutes, so a five-minute
    /// slice reads a flat 0 nearly always and 12%/h the rest of the time, and
    /// neither is the pace. Their `now` instead reads the latest step over the
    /// time since the step before it landed: the step's true pace the moment it
    /// arrives, fading as the next one fails to. The anchor never sits further
    /// back than the carry-forward sample at this boundary (itself accepted up
    /// to `nowAnchorSlack`x this old), so a window that has not stepped inside
    /// the lookback reads a flat zero across it rather than an hours-old slope.
    static let nowStepLookback: TimeInterval = 60 * 60
    /// The `now` anchor may sit before `nowMaximumSpan` (carry-forward across a
    /// sampling gap) only up to this multiple of it; beyond that the recent
    /// history is too sparse to call anything "now" and the rate is omitted.
    /// Keep the product short — 15 minutes is already the outer edge of "now".
    static let nowAnchorSlack: Double = 1.5

    // MARK: Projection trust

    /// The `avg` drain rate is only trusted to extrapolate up to this many
    /// multiples of the span it was actually averaged over. A young reset epoch
    /// (a few minutes of history) should not be linearly projected for hours —
    /// that produces "would run out" alarms no sustained usage pattern would hit.
    static let maxExtrapolationMultiplier: Double = 6
    /// Long reset windows need a little absolute history before we claim an
    /// immediate depletion time. A weekly quota can move in coarse server-side
    /// steps, so a few minutes of evidence should stay informational.
    static let longWindowMinimumAtRiskEvidence: TimeInterval = 30 * 60
    static let longWindowHorizon: TimeInterval = 24 * 60 * 60

    // MARK: Peer capacity

    /// A shorter peer window refills on a cycle, so it caps how fast a longer
    /// window counting the same tokens can drain: at most the drain ratio ×
    /// 100 points per peer cycle. Reading that ratio needs both windows to
    /// have moved by whole points. A long window's step is a large slice of
    /// its pool, so three of them bound the quantisation error to ~±33% (the
    /// `nowTriggerPercent` argument); ten peer points keep the denominator's
    /// own rounding under ±10%. Small changes make the ratio unstable.
    static let capacityMinimumWindowDrain: Double = 3
    static let capacityMinimumPeerDrain: Double = 10

    private struct WindowKey: Hashable {
        let provider: Provider
        let windowID: String
    }

    private struct DrainRate {
        let percentPerHour: Double
        let span: TimeInterval
        var hours: Double { max(span / 3600, 1 / 120) }
    }

    // MARK: Recording

    static func record(
        existing: [QuotaObservation],
        states: [ProviderState],
        at now: Date = Date()
    ) -> [QuotaObservation] {
        let newest = states.flatMap { state in
            observations(from: state.quota, at: now)
        }
        return bounded(existing + newest, at: now)
    }

    private static func observations(from quota: QuotaSnapshot, at now: Date) -> [QuotaObservation] {
        guard quota.source != .unavailable else { return [] }
        return quota.windows.map { window in
            QuotaObservation(
                provider: quota.provider,
                windowID: window.id,
                remainingPercent: window.remainingPercent,
                observedAt: now,
                resetsAt: window.resetsAt
            )
        }
    }

    /// Bounds history per (provider, window) so one provider with several windows
    /// cannot starve another — a global cap used to leave every window with
    /// well under an hour of samples. Output is sorted by time, then provider and
    /// window, so the persisted array is deterministic.
    private static func bounded(_ observations: [QuotaObservation], at now: Date) -> [QuotaObservation] {
        let ageCutoff = now.addingTimeInterval(-maxObservationAge)
        var grouped: [WindowKey: [QuotaObservation]] = [:]
        for observation in observations where observation.observedAt >= ageCutoff {
            let key = WindowKey(provider: observation.provider, windowID: observation.windowID)
            grouped[key, default: []].append(observation)
        }
        return grouped.values
            .flatMap { thinned($0.sorted { $0.observedAt < $1.observedAt }, at: now) }
            .sorted { lhs, rhs in
                if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
                if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
                return lhs.windowID < rhs.windowID
            }
    }

    /// Keeps every sample inside `fullFidelitySpan`; older samples thin to the
    /// oldest one per `decimationInterval` bucket. Buckets are fixed on the epoch
    /// clock (not relative to `now`) and the oldest sample per bucket wins, so
    /// re-running this on every refresh is idempotent: once a sample survives
    /// thinning it keeps surviving until it ages out. Zero-delta samples survive
    /// like any other, so plateaus older than an hour stay visible to the rates.
    private static func thinned(_ sorted: [QuotaObservation], at now: Date) -> [QuotaObservation] {
        let fullCutoff = now.addingTimeInterval(-fullFidelitySpan)
        var kept: [QuotaObservation] = []
        var lastBucket: Int?
        for observation in sorted {
            if observation.observedAt >= fullCutoff {
                kept.append(observation)
                continue
            }
            let bucket = Int((observation.observedAt.timeIntervalSince1970 / decimationInterval).rounded(.down))
            if bucket != lastBucket {
                kept.append(observation)
                lastBucket = bucket
            }
        }
        if kept.count > maxObservationsPerWindow {
            kept = Array(kept.suffix(maxObservationsPerWindow))
        }
        return kept
    }

    // MARK: Runway

    static func runway(
        provider: Provider,
        window: QuotaWindow,
        observations: [QuotaObservation],
        now: Date = Date(),
        peerWindows: [QuotaWindow] = []
    ) -> QuotaRunway {
        let samples = observations
            .filter { observation in
                observation.provider == provider
                    && observation.windowID == window.id
                    && sameResetEpoch(observation.resetsAt, window.resetsAt)
            }
            .sorted { $0.observedAt < $1.observedAt }
        let style = paceStyle(resetsAt: window.resetsAt, now: now)
        let budget = safePercentPerHour(window: window, now: now)

        func make(
            status: QuotaRunwayStatus,
            average: DrainRate?,
            current: NowReading?,
            depletion: Date?,
            message: String
        ) -> QuotaRunway {
            QuotaRunway(
                provider: provider,
                windowID: window.id,
                status: status,
                percentPerHour: average?.percentPerHour,
                estimatedDepletionAt: depletion,
                safePercentPerHour: budget,
                paceStyle: style,
                message: message,
                nowPercentPerHour: current?.drain.percentPerHour,
                nowSpan: current?.drain.span,
                avgSpan: average?.span,
                nowAnchor: current?.anchor
            )
        }

        guard samples.count >= 2 else {
            return make(status: .insufficientData, average: nil, current: nil, depletion: nil, message: "needs another refresh")
        }

        // A rise inside one reset epoch (a nil-reset window rolling over, or a
        // server-side correction) invalidates everything before it.
        let pool = sinceLastRise(samples)
        let latest = pool[pool.count - 1]
        guard pool.count >= 2 else {
            return make(
                status: .steady,
                average: DrainRate(percentPerHour: 0, span: 0),
                current: nil,
                depletion: nil,
                message: "pace steady"
            )
        }

        let average = averageDrain(in: pool, current: latest, style: style)
        let current = nowDrain(in: pool, current: latest, averageSpan: average.span, style: style)
        guard average.percentPerHour > 0 else {
            return make(status: .steady, average: average, current: current, depletion: nil, message: "pace steady")
        }

        let hoursToDepletion = latest.remainingPercent / average.percentPerHour
        let depletion = latest.observedAt.addingTimeInterval(hoursToDepletion * 3600)
        var status = statusFor(depletion: depletion, reset: window.resetsAt)
        var reportedDepletion: Date? = depletion
        if status == .atRisk,
           shouldDowngradeAtRisk(
               hoursToDepletion: hoursToDepletion,
               evidenceHours: average.hours,
               reset: window.resetsAt,
               observedAt: latest.observedAt
           ) {
            // Not enough averaged history to trust a projection this far out — report
            // the pace without the "would run out" alarm or a specific depletion date.
            status = .watch
            reportedDepletion = nil
        }
        let raw = make(
            status: status,
            average: average,
            current: current,
            depletion: reportedDepletion,
            message: message(for: status, depletion: depletion, percentPerHour: average.percentPerHour, now: now)
        )
        return pacedByShorterWindow(
            raw,
            provider: provider,
            window: window,
            observations: observations,
            now: now,
            peerWindows: peerWindows
        )
    }

    private static func sameResetEpoch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l.timeIntervalSince(r)) < 1
        default: return false
        }
    }

    private static func safePercentPerHour(window: QuotaWindow, now: Date) -> Double? {
        guard let reset = window.resetsAt else { return nil }
        let hours = reset.timeIntervalSince(now) / 3600
        guard hours > 0 else { return nil }
        return window.remainingPercent / hours
    }

    private static func constrainedByShorterWindow(
        _ raw: QuotaRunway,
        provider: Provider,
        window: QuotaWindow,
        observations: [QuotaObservation],
        now: Date,
        peerWindows: [QuotaWindow]
    ) -> QuotaRunway {
        guard raw.status == .atRisk,
              let rawDepletion = raw.estimatedDepletionAt,
              let reset = window.resetsAt else {
            return raw
        }

        let blocker = peerWindows
            .filter { peer in
                guard peer.id != window.id, let peerReset = peer.resetsAt else { return false }
                return peerReset < reset
            }
            .compactMap { peer -> (QuotaWindow, Date)? in
                let peerRunway = runway(
                    provider: provider,
                    window: peer,
                    observations: observations,
                    now: now
                )
                guard peerRunway.status == .atRisk,
                      let peerDepletion = peerRunway.estimatedDepletionAt,
                      peerDepletion < rawDepletion else {
                    return nil
                }
                return (peer, peerDepletion)
            }
            .min { $0.1 < $1.1 }

        guard let blocker else { return raw }
        return reverdict(raw, status: .safe, depletion: nil, message: "\(blocker.0.label) limit hits first")
    }

    /// Floors an at-risk projection at the pace a shorter peer window can
    /// physically allow. Both windows count the same tokens, so their drains
    /// keep a near-constant ratio `r` (per plan; per model mix for a
    /// model-scoped weekly): the peer hands this window at most
    /// `r × peer.remainingPercent` before the peer's reset and `r × 100` per
    /// peer cycle after it. An `avg` projection sooner than that is a pace the
    /// user cannot hold — the peer's limit would stop them first — so the
    /// estimate becomes the floor: the even-pace reading of the peer refilling
    /// and draining fully, cycle after cycle. A floor landing at or past this
    /// window's own reset means it cannot run out at all, hence `.safe`. When the floor does
    /// not bite, or no peer has the evidence for one, the older "hits first"
    /// rule still applies.
    private static func pacedByShorterWindow(
        _ raw: QuotaRunway,
        provider: Provider,
        window: QuotaWindow,
        observations: [QuotaObservation],
        now: Date,
        peerWindows: [QuotaWindow]
    ) -> QuotaRunway {
        guard raw.status == .atRisk,
              let rawDepletion = raw.estimatedDepletionAt,
              let reset = window.resetsAt else {
            return raw
        }

        let floor = peerWindows
            .compactMap { peer -> (QuotaWindow, Date)? in
                // A peer already past its reset is stale data, and one sharing
                // this window's reset (the all-model and model-scoped weeklies)
                // refills together with it rather than pacing it.
                guard peer.id != window.id,
                      let peerReset = peer.resetsAt,
                      peerReset > now,
                      peerReset < reset,
                      !sameResetEpoch(peerReset, reset),
                      let cycle = peer.cycle, cycle > 0,
                      let ratio = drainRatio(of: window, per: peer, provider: provider, observations: observations)
                else { return nil }
                let beforePeerReset = ratio * peer.remainingPercent
                // The peer can still hand over enough to empty this window
                // inside the current cycle, so it paces nothing.
                guard beforePeerReset < window.remainingPercent else { return nil }
                let ceilingPerHour = ratio * 100 / (cycle / 3600)
                let hoursAfterPeerReset = (window.remainingPercent - beforePeerReset) / ceilingPerHour
                return (peer, peerReset.addingTimeInterval(hoursAfterPeerReset * 3600))
            }
            .max { $0.1 < $1.1 }

        guard let floor, floor.1 > rawDepletion else {
            return constrainedByShorterWindow(
                raw,
                provider: provider,
                window: window,
                observations: observations,
                now: now,
                peerWindows: peerWindows
            )
        }
        if floor.1 >= reset {
            return reverdict(
                raw,
                status: .safe,
                depletion: nil,
                message: "\(floor.0.label) limit paces this window",
                pacedBy: floor.0.label
            )
        }
        return reverdict(
            raw,
            status: .atRisk,
            depletion: floor.1,
            message: message(for: .atRisk, depletion: floor.1, percentPerHour: raw.percentPerHour ?? 0, now: now),
            pacedBy: floor.0.label
        )
    }

    /// Points this window loses per point `peer` loses, summed over every pair
    /// of consecutive peer samples in which neither window rose. A rise is a
    /// reset, and a reset inside a sampling gap hides the peer's drain on that
    /// pair while this window's stays visible, so such pairs are skipped rather
    /// than let one gap tilt the ratio. Reads the raw per-window history —
    /// every epoch, not the current pool — because the peer's own epoch is at
    /// most a few hours old and would starve the evidence right after each
    /// reset. Nil until both windows have moved enough whole points
    /// (`capacityMinimumWindowDrain`, `capacityMinimumPeerDrain`) for integer
    /// quantisation to stop dominating.
    static func drainRatio(
        of window: QuotaWindow,
        per peer: QuotaWindow,
        provider: Provider,
        observations: [QuotaObservation]
    ) -> Double? {
        let peerSamples = observations
            .filter { $0.provider == provider && $0.windowID == peer.id }
            .sorted { $0.observedAt < $1.observedAt }
        let windowSamples = observations
            .filter { $0.provider == provider && $0.windowID == window.id }
            .sorted { $0.observedAt < $1.observedAt }
        guard peerSamples.count >= 2, !windowSamples.isEmpty else { return nil }

        // Both histories are sampled on the same refreshes, so this window's
        // carry-forward value at each peer sample is found by walking forward
        // once rather than searching from the start for every pair.
        var windowIndex = 0
        func windowValue(atOrBefore date: Date) -> Double? {
            while windowIndex + 1 < windowSamples.count,
                  windowSamples[windowIndex + 1].observedAt <= date {
                windowIndex += 1
            }
            let sample = windowSamples[windowIndex]
            return sample.observedAt <= date ? sample.remainingPercent : nil
        }

        var peerDrain = 0.0
        var windowDrain = 0.0
        var previous = windowValue(atOrBefore: peerSamples[0].observedAt)
        for (earlier, later) in zip(peerSamples, peerSamples.dropFirst()) {
            let current = windowValue(atOrBefore: later.observedAt)
            if let previous, let current,
               later.remainingPercent <= earlier.remainingPercent + 0.1,
               current <= previous + 0.1 {
                peerDrain += earlier.remainingPercent - later.remainingPercent
                windowDrain += previous - current
            }
            previous = current
        }
        guard windowDrain >= capacityMinimumWindowDrain,
              peerDrain >= capacityMinimumPeerDrain else { return nil }
        return windowDrain / peerDrain
    }

    /// `raw` under a different verdict; the rates and the spans they were read
    /// over are the readings they were and travel unchanged.
    private static func reverdict(
        _ raw: QuotaRunway,
        status: QuotaRunwayStatus,
        depletion: Date?,
        message: String,
        pacedBy: String? = nil
    ) -> QuotaRunway {
        QuotaRunway(
            provider: raw.provider,
            windowID: raw.windowID,
            status: status,
            percentPerHour: raw.percentPerHour,
            estimatedDepletionAt: depletion,
            safePercentPerHour: raw.safePercentPerHour,
            paceStyle: raw.paceStyle,
            message: message,
            nowPercentPerHour: raw.nowPercentPerHour,
            nowSpan: raw.nowSpan,
            avgSpan: raw.avgSpan,
            nowAnchor: raw.nowAnchor,
            pacedBy: pacedBy
        )
    }

    /// Decides how the pace line reads a window. Lives here — beside
    /// `longWindowHorizon` and the at-risk downgrade rules — so views never
    /// re-derive window-horizon semantics from reset dates.
    static func paceStyle(resetsAt: Date?, now: Date) -> QuotaPaceStyle {
        guard let resetsAt else { return .hidden }
        return resetsAt.timeIntervalSince(now) > longWindowHorizon ? .paceOnly : .paceVersusBudget
    }

    // MARK: Per-style policy

    /// Everything that depends on the horizon, decided by exhaustive switches
    /// on `QuotaPaceStyle` so the three cases are never told apart by negation
    /// in one place and by a different negation in another. `.hidden` (no
    /// reset date) is read like a long window for `avg`, which the runway
    /// status still uses, and like a short window for `now`, which nothing
    /// renders for it; both are the readings it had before this was written down.

    /// Span the `avg` rate covers for a window read with `style`.
    static func averageSpan(for style: QuotaPaceStyle) -> TimeInterval {
        switch style {
        case .paceVersusBudget: return shortAverageSpan
        case .paceOnly, .hidden: return longAverageSpan
        }
    }

    /// Whether `now` anchors on the latest whole-point step (`latestStepAnchor`)
    /// instead of the flat `nowMaximumSpan` slice.
    static func nowAnchorsOnLatestStep(for style: QuotaPaceStyle) -> Bool {
        switch style {
        case .paceOnly: return true
        case .paceVersusBudget, .hidden: return false
        }
    }

    /// Whether `now` is still reported when it covers the same span as `avg`.
    /// The step anchor is bounded by `nowStepLookback`, so its span only
    /// coincides with `avg`'s while history is younger than that hour, and
    /// hiding `now` for that hour read as the segment having been removed. The
    /// flat slice coincides with `avg` for the five minutes after a reset,
    /// where one number under two labels is the worse reading.
    static func nowMayEqualAverageSpan(for style: QuotaPaceStyle) -> Bool {
        nowAnchorsOnLatestStep(for: style)
    }

    // MARK: Drain rates

    /// Drops every sample before the last rise, so a nil-reset window that rolled
    /// over (or a server-side correction) restarts the evidence at the rise.
    private static func sinceLastRise(_ samples: [QuotaObservation]) -> [QuotaObservation] {
        var start = 0
        for index in 1..<samples.count
        where samples[index].remainingPercent > samples[index - 1].remainingPercent + 0.1 {
            start = index
        }
        return Array(samples[start...])
    }

    /// Trailing drain averaged across `averageSpan(for:)`, anchored on the value
    /// the window still held when that span began (carry-forward), so the
    /// measured span is never shorter than the nominal one. Falls back to the
    /// full same-epoch span when history does not reach that far — the reported
    /// `span` says which, and the trust rules use it as evidence.
    private static func averageDrain(
        in pool: [QuotaObservation],
        current: QuotaObservation,
        style: QuotaPaceStyle
    ) -> DrainRate {
        let boundary = current.observedAt.addingTimeInterval(-averageSpan(for: style))
        let anchor = carryForwardAnchor(in: pool, atOrBefore: boundary) ?? pool[0]
        return rate(from: anchor, to: current)
    }

    /// Short-window drain. Walks back through the samples inside
    /// `nowMaximumSpan` to the newest one at least `nowTriggerPercent` above the
    /// current value; when no such sample exists, reads the drain across the
    /// whole maximum span (carry-forward anchor, allowed `nowAnchorSlack`× older
    /// to bridge a sampling gap), or across whatever samples do sit inside the
    /// span. Long-horizon windows (`.paceOnly`) skip that flat slice and anchor
    /// on the latest whole-point step instead (`latestStepAnchor`). The span is
    /// widened to `nowMinimumSpan` when the trigger fired on the very last
    /// refresh. Nil when nothing recent enough exists, and nil when the span it
    /// could read is no shorter than `averageSpan` unless the style's policy
    /// allows that (`nowMayEqualAverageSpan(for:)`): a `now` that covers the
    /// same history as `avg` is the same number twice, except while a
    /// step-anchored window's history is younger than its lookback (a fresh
    /// install, a wake after the 24-hour age cap emptied the pool, the sample
    /// after a rise), where hiding it read as the segment having been removed.
    /// A `now` reading together with how its anchor was chosen, so the runway
    /// can tell the tooltip what `nowSpan` means.
    private struct NowReading {
        let drain: DrainRate
        let anchor: QuotaNowAnchor
    }

    private static func nowDrain(
        in pool: [QuotaObservation],
        current: QuotaObservation,
        averageSpan: TimeInterval,
        style: QuotaPaceStyle
    ) -> NowReading? {
        let maximumSpan = nowMaximumSpan
        let slackLimit = maximumSpan * nowAnchorSlack
        let earlier = pool.dropLast()
        let inside = earlier.filter { current.observedAt.timeIntervalSince($0.observedAt) <= maximumSpan }

        var anchor: QuotaObservation?
        var kind = QuotaNowAnchor.slice
        if let triggered = inside.last(where: {
            $0.remainingPercent - current.remainingPercent >= nowTriggerPercent - 0.001
        }) {
            anchor = triggered
            kind = .burst
        } else if nowAnchorsOnLatestStep(for: style) {
            if let stepped = latestStepAnchor(in: pool, current: current) {
                anchor = stepped.anchor
                kind = stepped.kind
            }
        } else if let carried = carryForwardAnchor(
            in: pool,
            atOrBefore: current.observedAt.addingTimeInterval(-maximumSpan)
        ), current.observedAt.timeIntervalSince(carried.observedAt) <= slackLimit {
            anchor = carried
        } else {
            anchor = inside.first
        }
        guard var anchor else { return nil }

        if current.observedAt.timeIntervalSince(anchor.observedAt) < nowMinimumSpan,
           let widened = carryForwardAnchor(
               in: pool,
               atOrBefore: current.observedAt.addingTimeInterval(-nowMinimumSpan)
           ),
           current.observedAt.timeIntervalSince(widened.observedAt) <= slackLimit {
            anchor = widened
        }
        let drain = rate(from: anchor, to: current)
        // Below `nowMinimumSpan` one refresh is the whole reading (the widening
        // above could not find an older sample), and a `now` that covers the
        // same history as `avg` is the same number twice unless the style's
        // policy says otherwise.
        guard drain.span >= nowMinimumSpan,
              nowMayEqualAverageSpan(for: style) || drain.span < averageSpan else { return nil }
        return NowReading(drain: drain, anchor: kind)
    }

    /// Anchor for a long-horizon `now` when no burst crossed the trigger: the
    /// sample right after the step before the latest one, so the reading is
    /// "the latest whole-point step, over the time it has taken so far". A step
    /// is any drop past the 0.1-point rounding floor between two consecutive
    /// samples. Bounded by `nowStepLookback`: the anchor is never older than
    /// the carry-forward sample at that boundary, which also makes a window
    /// with no step inside the lookback read a flat zero across it. When
    /// sampling was so sparse that this boundary sample sits past
    /// `nowAnchorSlack`x the lookback (hours of gap, not the 5-minute
    /// decimation or the 15-minute background cadence), the floor is the
    /// oldest sample inside the lookback instead — the same rule the short
    /// slice applies at its own scale.
    private static func latestStepAnchor(
        in pool: [QuotaObservation],
        current: QuotaObservation
    ) -> (anchor: QuotaObservation, kind: QuotaNowAnchor)? {
        let boundary = current.observedAt.addingTimeInterval(-nowStepLookback)
        let floor: QuotaObservation?
        if let carried = carryForwardAnchor(in: pool, atOrBefore: boundary),
           current.observedAt.timeIntervalSince(carried.observedAt) <= nowStepLookback * nowAnchorSlack {
            floor = carried
        } else {
            // Sparse history: the oldest earlier sample inside the lookback.
            // Nil when `current` is the only one — hours of gap ending in a
            // single fresh sample say nothing about the present, so `now` is
            // omitted rather than read as 0 over no time at all.
            floor = pool.dropLast().first { $0.observedAt > boundary }
        }
        guard let floor else { return nil }
        let steps = pool.indices.dropFirst().filter {
            pool[$0 - 1].remainingPercent - pool[$0].remainingPercent > 0.1
        }
        guard let latest = steps.last, pool[latest].observedAt >= boundary,
              let previous = steps.dropLast().last else { return (floor, .lookback) }
        let afterPrevious = pool[previous]
        return afterPrevious.observedAt > floor.observedAt ? (afterPrevious, .step) : (floor, .lookback)
    }

    /// Newest sample observed at or before `boundary`: the value the window still
    /// held when a span starting there began. Nil when history is shorter.
    private static func carryForwardAnchor(
        in pool: [QuotaObservation],
        atOrBefore boundary: Date
    ) -> QuotaObservation? {
        pool.last { $0.observedAt <= boundary }
    }

    private static func rate(from anchor: QuotaObservation, to current: QuotaObservation) -> DrainRate {
        let span = current.observedAt.timeIntervalSince(anchor.observedAt)
        let drop = anchor.remainingPercent - current.remainingPercent
        let hours = max(span / 3600, 1 / 120)
        return DrainRate(percentPerHour: drop > 0.1 ? drop / hours : 0, span: span)
    }

    // MARK: Status

    private static func shouldDowngradeAtRisk(
        hoursToDepletion: Double,
        evidenceHours: Double,
        reset: Date?,
        observedAt: Date
    ) -> Bool {
        if hoursToDepletion > evidenceHours * maxExtrapolationMultiplier {
            return true
        }
        guard let reset else { return false }
        let remainingWindow = reset.timeIntervalSince(observedAt)
        let evidenceSeconds = evidenceHours * 3600
        return remainingWindow > longWindowHorizon
            && evidenceSeconds < longWindowMinimumAtRiskEvidence
    }

    private static func statusFor(
        depletion: Date,
        reset: Date?
    ) -> QuotaRunwayStatus {
        guard let reset else { return .watch }
        if depletion < reset { return .atRisk }
        return .safe
    }

    private static func message(
        for status: QuotaRunwayStatus,
        depletion: Date,
        percentPerHour: Double,
        now: Date
    ) -> String {
        switch status {
        case .insufficientData:
            return "needs another refresh"
        case .steady:
            return "pace steady"
        case .safe:
            return "pace safe"
        case .watch:
            return String(format: "using %.1f%%/h", percentPerHour)
        case .atRisk:
            return "would run out \(relative(depletion, now: now))"
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "now" }
        // The formatter's smallest unit is a minute, so anything under 60s renders
        // as "in 0 min"; say "in under a minute" instead.
        if interval < 60 { return "in under a minute" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return "in " + (f.string(from: interval) ?? "?")
    }
}
