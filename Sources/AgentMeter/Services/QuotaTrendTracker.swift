import Foundation

/// Keeps recent quota observations bounded and derives per-window runway.
enum QuotaTrendTracker {
    static let maxObservationAge: TimeInterval = 60 * 60 * 24
    static let maxObservationCount = 200
    /// A 2-sample instantaneous drain rate is only trusted to extrapolate up to this
    /// many multiples of the timespan it was actually observed over. A short burst
    /// (e.g. a few minutes of heavy use) should not be linearly projected for days —
    /// that produces "would run out" alarms no sustained usage pattern would ever hit,
    /// especially on long-horizon windows (weekly, or a months-long one-time credit).
    static let maxExtrapolationMultiplier: Double = 6
    /// Drain rate is averaged over the most recent observations within this
    /// trailing window rather than the last two adjacent samples, so a single
    /// tick's burst (or lull) can't swing the projection. Falls back to the full
    /// same-reset-epoch span when the window is too sparse to hold two samples.
    static let runwayLookback: TimeInterval = 10 * 60

    private struct DrainSignal {
        let rateAnchor: QuotaObservation
        let evidenceStart: QuotaObservation
    }

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

    private static func bounded(_ observations: [QuotaObservation], at now: Date) -> [QuotaObservation] {
        let cutoff = now.addingTimeInterval(-maxObservationAge)
        let recent = observations
            .filter { $0.observedAt >= cutoff }
            .sorted { $0.observedAt < $1.observedAt }
        if recent.count <= maxObservationCount { return recent }
        return Array(recent.suffix(maxObservationCount))
    }

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

        guard samples.count >= 2 else {
            return QuotaRunway(
                provider: provider,
                windowID: window.id,
                status: .insufficientData,
                percentPerHour: nil,
                estimatedDepletionAt: nil,
                safePercentPerHour: safePercentPerHour(window: window, now: now),
                message: "needs another refresh"
            )
        }

        let current = samples.last!
        guard let signal = drainSignal(for: current, in: samples) else {
            return QuotaRunway(
                provider: provider,
                windowID: window.id,
                status: .steady,
                percentPerHour: 0,
                estimatedDepletionAt: nil,
                safePercentPerHour: safePercentPerHour(window: window, now: now),
                message: "pace steady"
            )
        }

        let elapsedHours = max(current.observedAt.timeIntervalSince(signal.rateAnchor.observedAt) / 3600, 1 / 120)
        let evidenceHours = max(current.observedAt.timeIntervalSince(signal.evidenceStart.observedAt) / 3600, elapsedHours)
        let percentPerHour = (signal.rateAnchor.remainingPercent - current.remainingPercent) / elapsedHours
        guard percentPerHour > 0 else {
            return QuotaRunway(
                provider: provider,
                windowID: window.id,
                status: .steady,
                percentPerHour: 0,
                estimatedDepletionAt: nil,
                safePercentPerHour: safePercentPerHour(window: window, now: now),
                message: "pace steady"
            )
        }

        let hoursToDepletion = current.remainingPercent / percentPerHour
        let depletion = current.observedAt.addingTimeInterval(hoursToDepletion * 3600)
        let safeRate = safePercentPerHour(window: window, now: now)
        var status = statusFor(depletion: depletion, reset: window.resetsAt)
        var reportedDepletion: Date? = depletion
        if status == .atRisk, hoursToDepletion > evidenceHours * maxExtrapolationMultiplier {
            // Not enough sustained history to trust a projection this far out — report
            // the pace without the "would run out" alarm or a specific depletion date.
            status = .watch
            reportedDepletion = nil
        }
        let raw = QuotaRunway(
            provider: provider,
            windowID: window.id,
            status: status,
            percentPerHour: percentPerHour,
            estimatedDepletionAt: reportedDepletion,
            safePercentPerHour: safeRate,
            message: message(for: status, depletion: depletion, percentPerHour: percentPerHour, now: now)
        )
        return constrainedByShorterWindow(
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
        return QuotaRunway(
            provider: raw.provider,
            windowID: raw.windowID,
            status: .safe,
            percentPerHour: raw.percentPerHour,
            estimatedDepletionAt: nil,
            safePercentPerHour: raw.safePercentPerHour,
            message: "\(blocker.0.label) limit hits first"
        )
    }

    /// Signal for the average drain rate plus the span of sustained drain evidence.
    /// Rate uses the oldest observation within the trailing lookback (or the full
    /// same-epoch span when the lookback is too sparse), while extrapolation trust
    /// uses the start of the current monotonic drain run. Returns nil — reported as
    /// steady — when quota rose inside the same reset epoch or when there is no net
    /// drain from the rate anchor to now.
    private static func drainSignal(
        for current: QuotaObservation,
        in samples: [QuotaObservation]
    ) -> DrainSignal? {
        guard let evidenceStart = sustainedDrainStart(in: samples) else { return nil }
        let cutoff = current.observedAt.addingTimeInterval(-runwayLookback)
        let within = samples.filter { $0.observedAt >= cutoff }
        let pool = within.count >= 2 ? within : samples
        guard let rateAnchor = pool.first,
              rateAnchor.observedAt < current.observedAt,
              rateAnchor.remainingPercent > current.remainingPercent + 0.1 else {
            return nil
        }
        return DrainSignal(rateAnchor: rateAnchor, evidenceStart: evidenceStart)
    }

    private static func sustainedDrainStart(in samples: [QuotaObservation]) -> QuotaObservation? {
        guard samples.count >= 2 else { return nil }
        var start: QuotaObservation?
        for (previous, next) in zip(samples.dropLast(), samples.dropFirst()) {
            if next.remainingPercent > previous.remainingPercent + 0.1 {
                return nil
            }
            if previous.remainingPercent > next.remainingPercent + 0.1, start == nil {
                start = previous
            }
        }
        return start
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
