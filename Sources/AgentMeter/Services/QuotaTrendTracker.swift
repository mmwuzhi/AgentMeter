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

    /// `avg` span for short-cycle windows (5-hour). Bounds how far the run-out
    /// estimate can reach, via `maxExtrapolationMultiplier`: 20 minutes of
    /// evidence projects at most 2 hours.
    static let shortAverageSpan: TimeInterval = 20 * 60
    /// `avg` span for long-cycle windows (weekly), plus anything stating no
    /// cycle that resets beyond `longWindowHorizon` (a one-time credit).
    static let longAverageSpan: TimeInterval = 24 * 60 * 60
    /// `now` walks back until this many percentage points have drained. Provider
    /// APIs report whole-percent utilization in practice, so a single tick says
    /// nothing about rate; three ticks bound the quantization error to ~±33%.
    /// Defined in points rather than samples so a fractional API needs no change.
    static let nowTriggerPercent: Double = 3
    /// `now` never reads a span shorter than this, so one refresh can't swing it.
    static let nowMinimumSpan: TimeInterval = 2 * 60
    /// Slice `now` scans for a burst. A drain of `nowTriggerPercent` landing
    /// inside five minutes is a spike worth reading on its own, ahead of the
    /// step anchor every window otherwise uses.
    ///
    /// This was once a hard ceiling on the span `now` could read, on the
    /// argument that a rate averaged over twenty minutes is not "now" but a
    /// second copy of `avg`. At a light pace the ceiling made `now` claim 0
    /// instead: `utilization` arrives as whole integers, so a W-minute span
    /// resolves only 60/W %/h, and a 5-hour window draining at 3%/h drops a
    /// point every twenty minutes — three ticks in four read a flat 0 inside a
    /// five-minute slice. A stale-but-true rate beats a fresh false one, so the
    /// slice now only catches bursts and `nowStepLookback` carries the rest.
    static let nowMaximumSpan: TimeInterval = 5 * 60
    /// Windows move in whole-point steps, so `now` anchors on the latest one:
    /// it reads that step over the time since the step before it landed — the
    /// step's true pace the moment it arrives, fading as the next one fails to.
    /// The anchor never sits further back than the carry-forward sample at this
    /// boundary (itself accepted up to `nowAnchorSlack`x this old), so a window
    /// that has not stepped inside the lookback reads the flat span rather than
    /// an hours-old slope — and a flat span is reported as an upper bound
    /// (`nowResolutionPercent`), never as a zero.
    static let nowStepLookback: TimeInterval = 60 * 60
    /// Smallest drain a provider can report. Utilization arrives as whole
    /// percentage points, so a span with no drop in it does not mean no drain —
    /// it means less than one point across that span. `now` reports that
    /// ceiling (`1 / span` in hours) flagged as an upper bound instead of a 0
    /// that would claim an idleness the samples never showed.
    static let nowResolutionPercent: Double = 1
    /// How long a model-scoped weekly has to sit still before `now` stops
    /// reporting a rate and says how long it has been still instead.
    ///
    /// Shared windows use the longer `nowStepLookback`.
    static let modelScopedFlatThreshold: TimeInterval = 10 * 60
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
    /// Long-cycle windows (read pace-only) need a little absolute history
    /// before we claim an immediate depletion time. A weekly quota can move in
    /// coarse server-side steps, so a few minutes of evidence should stay
    /// informational. Keyed on the pace style, not the reset date, so "long
    /// window" means one thing throughout the tracker.
    static let longWindowMinimumAtRiskEvidence: TimeInterval = 30 * 60
    static let longWindowHorizon: TimeInterval = 24 * 60 * 60
    /// How many of the shortest peer cycles a run-out date may sit ahead before
    /// it stops being something the user can act on. A long window's projection
    /// is already floored at what its shorter peer can hand over per refill
    /// (`pacedByShorterWindow`); past a couple of those refills the date only
    /// says "if you hold this pace through several full peer resets", which no
    /// session does and nothing can be done about now. Beyond it the runway
    /// drops to `.watch`: the pace still shows, the date and its alarm do not.
    static let actionableHorizonCycles: Double = 2
    /// The horizon never drops below this however short a peer claims its cycle
    /// is. The cadence is a provider-reported number on every provider but
    /// Claude, and this rule only ever *removes* a warning, so a single bad
    /// field must not be able to hide a run-out the user could still act on.
    /// Two hours sits far below any real cadence (the shortest is five hours),
    /// so it engages on nonsense input and nothing else.
    static let minimumActionableHorizon: TimeInterval = 2 * 60 * 60

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
        let style = paceStyle(resetsAt: window.resetsAt, cycle: window.cycle, now: now)
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
                nowAnchor: current?.anchor,
                nowIsUpperBound: current?.isUpperBound ?? false
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
        let current = nowDrain(in: pool, current: latest, window: window)
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
               style: style
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
        return withinActionableHorizon(
            pacedByShorterWindow(
                raw,
                provider: provider,
                window: window,
                observations: observations,
                now: now,
                peerWindows: peerWindows
            ),
            window: window,
            peerWindows: peerWindows,
            now: now
        )
    }

    /// Drops the run-out date on a projection too far out to act on. Runs last,
    /// after `pacedByShorterWindow` has had its say, because the floor it
    /// applies can push the date further out than the `avg` projection alone.
    /// The pace line survives; only the date, its alarm colour and the `.atRisk`
    /// verdict go, so a window that later drifts inside the horizon says so
    /// again on its own.
    private static func withinActionableHorizon(
        _ runway: QuotaRunway,
        window: QuotaWindow,
        peerWindows: [QuotaWindow],
        now: Date
    ) -> QuotaRunway {
        guard runway.status == .atRisk,
              let depletion = runway.estimatedDepletionAt,
              let horizon = actionableHorizon(window: window, peerWindows: peerWindows, now: now),
              depletion.timeIntervalSince(now) > horizon
        else { return runway }
        return reverdict(
            runway,
            status: .watch,
            depletion: nil,
            message: message(
                for: .watch,
                depletion: depletion,
                percentPerHour: runway.percentPerHour ?? 0,
                now: now
            )
        )
    }

    /// `actionableHorizonCycles` x the shortest cycle among the peers that can
    /// actually refill this window faster than it refills itself, floored at
    /// `minimumActionableHorizon`. Nil when no peer qualifies: a window nothing
    /// paces has no "couple of refills" to speak of, so the
    /// `maxExtrapolationMultiplier` and evidence rules stay its only guards, and
    /// Copilot's allowances — which name no cadence at all — keep the runway
    /// they had.
    ///
    /// The `cycle < own cycle` test is what keeps a 5-hour window out of this
    /// rule, and it has to be tested rather than assumed: reading the shortest
    /// cycle among *all* peers happens to spare the 5-hour window only because
    /// today every other window is a weekly, so adding one shorter window to a
    /// provider would start suppressing run-out dates on unrelated ones.
    private static func actionableHorizon(
        window: QuotaWindow,
        peerWindows: [QuotaWindow],
        now: Date
    ) -> TimeInterval? {
        guard let own = window.cycle else { return nil }
        return peerWindows
            .filter { $0.id != window.id && statesACredibleCycle($0, now: now) }
            .compactMap(\.cycle)
            .filter { $0 > 0 && $0 < own }
            .min()
            .map { max($0 * actionableHorizonCycles, minimumActionableHorizon) }
    }

    /// Whether a peer's stated cadence is believable enough to shorten another
    /// window's horizon. `resetsAt` is by definition less than one cycle away,
    /// so a window claiming a five-minute cycle while resetting in two hours is
    /// not describing a cadence — and the plausibility band alone cannot catch
    /// it, since five minutes clears `minimumCycle`. Reading it anyway would
    /// pull the horizon down to its floor, and this rule only ever *removes* a
    /// warning. A peer that states no reset keeps the benefit of the doubt;
    /// there is no second field to contradict it.
    private static func statesACredibleCycle(_ peer: QuotaWindow, now: Date) -> Bool {
        guard let cycle = peer.cycle, cycle > 0 else { return false }
        guard let reset = peer.resetsAt else { return true }
        return reset.timeIntervalSince(now) <= cycle
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
    /// `r × peer.remainingPercent` before the peer's reset and `r × 100` at
    /// each peer reset after it. A refill lands whole, so the user spends it
    /// at the `avg` pace and waits only once it is gone: the floor is the
    /// refill that finally covers what is left, plus the time to spend the
    /// rest of it. An `avg` projection sooner than that is a pace the user
    /// cannot hold — the peer's limit would stop them first. A floor landing
    /// at or past this window's own reset means it cannot run out at all,
    /// hence `.safe`.
    ///
    /// Spreading a refill across its cycle can delay the projection too far.
    ///
    /// A peer whose ratio was measured has had its say here: when its floor
    /// does not bite, the `avg` projection stands. Only a peer with no
    /// evidence for a floor falls through to the older "hits first" rule,
    /// which ignores the refill — a 5-hour window running dry seconds before
    /// its reset would otherwise call the weekly safe just before refilling it.
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
              let pace = raw.percentPerHour, pace > 0,
              let reset = window.resetsAt else {
            return raw
        }

        var measuredPeers: Set<String> = []
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
                measuredPeers.insert(peer.id)
                let beforePeerReset = ratio * peer.remainingPercent
                // The peer can still hand over enough to empty this window
                // inside the current cycle, so it paces nothing.
                guard beforePeerReset < window.remainingPercent else { return nil }
                let perRefill = ratio * 100
                let afterPeerReset = window.remainingPercent - beforePeerReset
                let wholeRefills = (afterPeerReset / perRefill).rounded(.up) - 1
                let lastRefill = peerReset.addingTimeInterval(wholeRefills * cycle)
                let rest = afterPeerReset - wholeRefills * perRefill
                return (peer, lastRefill.addingTimeInterval(rest / pace * 3600))
            }
            .max { $0.1 < $1.1 }

        guard let floor, floor.1 > rawDepletion else {
            return constrainedByShorterWindow(
                raw,
                provider: provider,
                window: window,
                observations: observations,
                now: now,
                peerWindows: peerWindows.filter { !measuredPeers.contains($0.id) }
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
    ///
    /// A model-scoped weekly drains only while its own model runs, and the
    /// peer points spent on other models while it sat still say nothing about
    /// what a refill hands it: two hours on another model before twenty
    /// minutes of Fable read 0.10 for a mix that ran at 0.17, and floored a
    /// run-out hours late. Its pairs count only from its first move and while its last move
    /// is within `modelScopedFlatThreshold`. Starting the count at a move
    /// rather than at the stretch's true start reads a little high, which only
    /// lowers the floor — the side that keeps a warning.
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

        let dormancy = window.isModelScoped == true ? modelScopedFlatThreshold : nil
        var lastMove: Date?
        var peerDrain = 0.0
        var windowDrain = 0.0
        var previous = windowValue(atOrBefore: peerSamples[0].observedAt)
        for (earlier, later) in zip(peerSamples, peerSamples.dropFirst()) {
            let current = windowValue(atOrBefore: later.observedAt)
            if let previous, let current, current < previous {
                lastMove = later.observedAt
            }
            let dormant = dormancy.map { threshold in
                lastMove.map { later.observedAt.timeIntervalSince($0) > threshold } ?? true
            } ?? false
            if !dormant, let previous, let current,
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
    /// over are the readings they were and travel unchanged. `pacedBy` travels
    /// too unless a caller names a new one — this composes, and a stage that
    /// silently dropped a previous stage's annotation would be a trap for the
    /// next rule stacked on top.
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
            nowIsUpperBound: raw.nowIsUpperBound,
            pacedBy: pacedBy ?? raw.pacedBy
        )
    }

    /// Decides how the pace line reads a window. Lives here — beside
    /// `longWindowHorizon` and the at-risk downgrade rules — so views never
    /// re-derive window-horizon semantics from reset dates.
    ///
    /// The window's stated refill `cycle` decides, not its time to reset. The
    /// split exists because a week-long window's even-spread rate sits below
    /// any active use however little of the week is left: a weekly at 47% with
    /// 14 h to go budgets 3.4%/h against a working pace of 6-7%/h. Keyed on
    /// time-to-reset, a weekly therefore *gained* a budget segment in its final
    /// day, turned orange whenever `now` cleared that rate, and — through
    /// `averageSpan(for:)` — had its `avg` silently shrink from a 24-hour span
    /// to a 20-minute one. Windows that state no cycle (Copilot allowances,
    /// one-time credits, caches written before `cycle` existed), or whose
    /// stated cycle is not credible, keep the time-to-reset rule. `.hidden`
    /// still comes first: a CLI-scraped Claude window states a cycle but no
    /// reset, and with no reset there is no budget to compare against.
    ///
    /// The cycle is read only when it is credible — the test
    /// `statesACredibleCycle` applies to peers: a reset can never sit more than
    /// one cycle away, so a cycle claiming otherwise is not describing a
    /// cadence, and the time rule takes over. A reset already in the past is
    /// stale data rather than a cadence too — a snapshot kept through an OAuth
    /// failure, or the seconds before the next tick — and falls through the
    /// same way, where the time rule's nil budget keeps the pace line off the
    /// row as it always did. A credible short cycle also
    /// implies a reset inside `longWindowHorizon`, so at the level of the
    /// style this rule can only ever turn `.paceVersusBudget` into
    /// `.paceOnly`, never the reverse. That is not the same as only ever
    /// removing a warning: the style also selects the `avg` span
    /// (`averageSpan(for:)`), and the 24-hour reading can carry a run-out the
    /// 20-minute one had just lost sight of — a weekly that drained hard for
    /// three hours and then sat idle for twenty minutes reads "pace steady" on
    /// the short span and "would run out in 5h" on the long one. For a weekly
    /// that is the intended, consistent reading; it is also why a wrong *long*
    /// cycle on a short window would raise an alarm rather than hide one.
    /// Both are pinned in `QuotaTrendTrackerTests`, so `cycle` here is trusted
    /// exactly as far as the provider's own statement of it (see the `cycle`
    /// rule in docs/agent/providers.md).
    static func paceStyle(resetsAt: Date?, cycle: TimeInterval?, now: Date) -> QuotaPaceStyle {
        guard let resetsAt else { return .hidden }
        let untilReset = resetsAt.timeIntervalSince(now)
        if let cycle, cycle > 0, (0...cycle).contains(untilReset) {
            return cycle > longWindowHorizon ? .paceOnly : .paceVersusBudget
        }
        return untilReset > longWindowHorizon ? .paceOnly : .paceVersusBudget
    }

    // MARK: Per-style policy

    /// What still depends on the horizon, decided by an exhaustive switch on
    /// `QuotaPaceStyle` so the three cases are never told apart by negation in
    /// one place and by a different negation in another. `.hidden` (no reset
    /// date) is read like a long window, which the runway status still uses.
    ///
    /// `now` used to branch here as well — a flat five-minute slice for short
    /// windows, the step anchor for long ones. Every window now takes the step
    /// anchor, so `now` and `avg` differ by how each picks its span rather than
    /// by which window they belong to, and `now` may read further back than
    /// `avg` when the latest step is old. That is the point: the two answer
    /// different questions, and the one `now` answers has no useful reading at
    /// a fixed five minutes when a point lands every twenty.

    /// Span the `avg` rate covers for a window read with `style`.
    static func averageSpan(for style: QuotaPaceStyle) -> TimeInterval {
        switch style {
        case .paceVersusBudget: return shortAverageSpan
        case .paceOnly, .hidden: return longAverageSpan
        }
    }

    /// How long `window` must sit still before `now` reports dormancy rather
    /// than a rate. Keyed on what the provider says the window is, never on its
    /// label or id: `weekly_scoped` is a documented `limits` kind, whereas
    /// matching a model name would be a guess about a field Claude leaves null.
    static func flatThreshold(for window: QuotaWindow) -> TimeInterval {
        window.isModelScoped == true ? modelScopedFlatThreshold : nowStepLookback
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

    /// A `now` reading, how its anchor was chosen (so the runway can tell the
    /// tooltip what `nowSpan` means), and whether the rate is a measurement or
    /// a ceiling.
    private struct NowReading {
        let drain: DrainRate
        let anchor: QuotaNowAnchor
        /// Nothing dropped across the span: the rate is `< drain.percentPerHour`,
        /// not equal to it. See `nowResolutionPercent`.
        let isUpperBound: Bool
    }

    /// Present-tense drain. A burst first: the newest sample inside
    /// `nowMaximumSpan` at least `nowTriggerPercent` above the current value,
    /// so a spike is read on the slice it happened in. Otherwise the latest
    /// whole-point step (`latestStepAnchor`), which is what the reading is
    /// built on at any ordinary pace. The span is widened to `nowMinimumSpan`
    /// when the trigger fired on the very last refresh.
    ///
    /// Nil when nothing recent enough exists — never nil merely for covering as
    /// much history as `avg`. The two are read differently (a step's own
    /// elapsed time against a fixed trailing span) and coincide only by
    /// accident; suppressing `now` on that coincidence used to blank the
    /// segment for a whole hour after a fresh install or a wake.
    private static func nowDrain(
        in pool: [QuotaObservation],
        current: QuotaObservation,
        window: QuotaWindow
    ) -> NowReading? {
        let slackLimit = nowMaximumSpan * nowAnchorSlack
        let earlier = pool.dropLast()
        let inside = earlier.filter { current.observedAt.timeIntervalSince($0.observedAt) <= nowMaximumSpan }

        let picked: (anchor: QuotaObservation, kind: QuotaNowAnchor)?
        if let triggered = inside.last(where: {
            $0.remainingPercent - current.remainingPercent >= nowTriggerPercent - 0.001
        }) {
            picked = (triggered, .burst)
        } else if let dormant = dormantReading(in: pool, current: current, window: window) {
            // Checked before the step anchor, not after: two old steps still
            // yield a measured rate, so a window that stopped an hour ago would
            // otherwise keep printing the pace it held while it was running.
            return dormant
        } else {
            picked = latestStepAnchor(in: pool, current: current)
        }
        guard let picked else { return nil }
        var anchor = picked.anchor
        let kind = picked.kind

        if current.observedAt.timeIntervalSince(anchor.observedAt) < nowMinimumSpan,
           let widened = carryForwardAnchor(
               in: pool,
               atOrBefore: current.observedAt.addingTimeInterval(-nowMinimumSpan)
           ),
           current.observedAt.timeIntervalSince(widened.observedAt) <= slackLimit {
            anchor = widened
        }
        let drain = rate(from: anchor, to: current)
        // Below `nowMinimumSpan` one refresh is the whole reading — the widening
        // above could not find an older sample.
        guard drain.span >= nowMinimumSpan else { return nil }
        guard drain.percentPerHour > 0 else {
            // Flat across the span. Utilization is reported in whole points, so
            // this bounds the rate rather than measuring it: under one point in
            // however long the window has sat still. The bound reads back past
            // `nowStepLookback` — that cap exists to stop an hours-old *slope*
            // being reported as "now", and a longer flat stretch only makes this
            // claim tighter, so an idle window converges toward zero instead of
            // parking at one point per hour forever.
            let still = current.observedAt
                .timeIntervalSince(lastMovement(in: pool, relativeTo: current) ?? pool[0].observedAt)
            let bound = DrainRate(percentPerHour: 0, span: max(still, drain.span))
            return NowReading(
                drain: DrainRate(percentPerHour: nowResolutionPercent / bound.hours, span: bound.span),
                // Not `kind`: that anchor picked a span this branch just
                // replaced, and `nowAnchor` is meant to say how `nowSpan` was
                // chosen. Naming the flat stretch keeps the two fields agreeing.
                anchor: .flat,
                isUpperBound: true
            )
        }
        return NowReading(drain: drain, anchor: kind, isUpperBound: false)
    }

    /// A window still for longer than `flatThreshold(for:)` — no rate at all,
    /// just how long it has been still, as an upper bound like any other flat
    /// span. Nil while the silence is within what this window's shape explains.
    /// The span always clears `nowMinimumSpan`, every threshold being minutes
    /// longer than it.
    private static func dormantReading(
        in pool: [QuotaObservation],
        current: QuotaObservation,
        window: QuotaWindow
    ) -> NowReading? {
        let still = current.observedAt
            .timeIntervalSince(lastMovement(in: pool, relativeTo: current) ?? pool[0].observedAt)
        guard still > flatThreshold(for: window) else { return nil }
        let span = DrainRate(percentPerHour: 0, span: still)
        return NowReading(
            drain: DrainRate(percentPerHour: nowResolutionPercent / span.hours, span: still),
            anchor: .dormant,
            isUpperBound: true
        )
    }

    /// Anchor for `now` when no burst crossed the trigger: the
    /// sample right after the step before the latest one, so the reading is
    /// "the latest whole-point step, over the time it has taken so far". A step
    /// is any drop past the 0.1-point rounding floor between two consecutive
    /// samples. Bounded by `nowStepLookback`: the anchor is never older than
    /// the carry-forward sample at that boundary, which also makes a window
    /// with no step inside the lookback read a flat zero across it. When
    /// sampling was so sparse that this boundary sample sits past
    /// `nowAnchorSlack`x the lookback (hours of gap, not the 5-minute
    /// decimation or the 15-minute background cadence), the floor is the
    /// oldest sample inside the lookback instead — the same rule the burst
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

    /// When the window was last meaningfully above where it is now — the newest
    /// sample more than the rounding floor above `current`. Time since it is how
    /// long the value has effectively stood still.
    ///
    /// Deliberately compares each sample against `current` rather than against
    /// its own predecessor. A step-to-step test assumes whole-point reporting,
    /// and a window draining smoothly in sub-0.1 increments never takes such a
    /// step, so it read as still for the whole of its history while it was in
    /// fact draining steadily. Nil when nothing in the retained history sits
    /// above `current`, which the caller reads as "as long as there are samples
    /// for".
    private static func lastMovement(
        in pool: [QuotaObservation],
        relativeTo current: QuotaObservation
    ) -> Date? {
        guard let above = pool.dropLast()
            .lastIndex(where: { $0.remainingPercent - current.remainingPercent > 0.1 })
        else { return nil }
        // The sample *after* the last high one: the first reading at today's
        // value, which is when it demonstrably settled. Taking the high sample
        // itself would claim the window had been still since before the drop,
        // and across a sampling gap that reads as hours of stillness on a
        // window that in fact drained during the gap.
        return pool[above + 1].observedAt
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
        style: QuotaPaceStyle
    ) -> Bool {
        if hoursToDepletion > evidenceHours * maxExtrapolationMultiplier {
            return true
        }
        // "Long window" means one thing in this file: the classification the
        // pace line already uses, not a second reading of the reset date. So a
        // weekly in its last day, read pace-only on its cycle, is still held
        // to the long-window evidence minimum.
        let isLongWindow: Bool
        switch style {
        case .paceOnly, .hidden: isLongWindow = true
        case .paceVersusBudget: isLongWindow = false
        }
        return isLongWindow && evidenceHours * 3600 < longWindowMinimumAtRiskEvidence
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
