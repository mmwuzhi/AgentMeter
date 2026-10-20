import Foundation

// The quota side of the history, as pure functions: which snapshots become
// `quota_sample` rows and how, how a legacy observation maps, the value the
// store's thinning rule compares, and the reset detector. No SQLite here and
// nothing isolated, so the whole of it runs in a unit test and on the store's
// executor alike.

/// What the history may record. One place, so turning a provider on later is a
/// one-line change.
enum QuotaHistoryPolicy {
    /// Claude only in Phase 0B. Codex's `.rolloutFile` stamps old numbers with
    /// `Date()` and its `primary` reset moves with wall time while idle, so it
    /// needs its own rules first; Copilot is one monthly window nobody
    /// calibrates against. The schema and `QuotaSampleRow` hold any provider.
    static let ingestedProviders: Set<Provider> = [.claude]

    /// A window id longer than this (or with a control character) is not
    /// stored. Ids are built from a response's model display name, so this
    /// bounds what a database key can be; the id the screen uses is untouched.
    static let maxWindowIDLength = 96
}

// MARK: - Snapshot -> rows

extension QuotaSampleRow {
    /// The rows one landed provider snapshot stands for: one per window, all
    /// with the same `readingMs`. Empty when the history must not record it:
    /// a provider outside `QuotaHistoryPolicy.ingestedProviders`; a source
    /// that is no reading (`.unavailable`) or whose time is wrong
    /// (`.rolloutFile` stamps `Date()` on whatever the newest log line says);
    /// a scrape that only echoed a cache older than
    /// `QuotaSnapshot.staleCacheTolerance`.
    ///
    /// `readingMs` is when the numbers were measured (`readingTime`), not
    /// `fetchedAt`: one fetch has one `fetchedAt` for N windows, and a stale
    /// echo repeats one reading under many of them. It is never rewritten: a
    /// reading later than the landing (the clock was set back between fetch and
    /// landing) keeps its raw time and gets `.futureReading`, because moving it
    /// would change the natural key and store one joined flight twice.
    ///
    /// A window whose response stated no utilization has `usedPercent == nil`
    /// and `.valueNotStated`: the 0 the screen shows for it is a placeholder,
    /// not stored as a reading.
    nonisolated static func rows(from snapshot: QuotaSnapshot, recordedAt: Date) -> [QuotaSampleRow] {
        guard QuotaHistoryPolicy.ingestedProviders.contains(snapshot.provider),
              !snapshot.echoesStaleCache,
              let source = QuotaSampleSource(snapshot.source),
              let recordedMs = Self.milliseconds(recordedAt),
              let readingMs = Self.milliseconds(snapshot.readingTime) else { return [] }
        var flags: Flags = []
        if readingMs > recordedMs { flags.insert(.futureReading) }
        let fetchedMs = Self.milliseconds(snapshot.fetchedAt)
        let cachedMs = snapshot.cachedAt.flatMap(Self.milliseconds)

        var seen = Set<String>()
        var rows: [QuotaSampleRow] = []
        for window in snapshot.windows {
            // The natural key has one row per window and reading; a repeated id
            // inside one snapshot would only count as a conflict in the store.
            let detail = window.detail
            let stated = detail?.utilizationStated != false
            guard !stated || window.usedPercent.isFinite,
                  isStorableWindowID(window.id),
                  seen.insert(window.id).inserted else { continue }
            var rowFlags = flags
            if !stated { rowFlags.insert(.valueNotStated) }
            rows.append(QuotaSampleRow(
                provider: snapshot.provider,
                windowID: window.id,
                source: source,
                readingMs: readingMs,
                fetchedMs: fetchedMs,
                cachedMs: cachedMs,
                recordedMs: recordedMs,
                usedPercent: stated ? window.usedPercent : nil,
                resetsAtMs: window.resetsAt.flatMap(Self.milliseconds),
                cycleSeconds: Self.wholeSeconds(window.cycle),
                isModelScoped: window.isModelScoped,
                isOneTimeCredit: window.isOneTimeCredit,
                isActive: detail?.isActive,
                severity: detail?.severity,
                lockedReason: detail?.lockedReason,
                scopeName: detail?.scopeName,
                shareUsedOfWeekly: detail?.shareUsedOfWeekly,
                shareAllowanceOfWeekly: detail?.shareAllowanceOfWeekly,
                plan: snapshot.planType,
                tier: snapshot.rateLimitTier,
                flags: rowFlags
            ))
        }
        return rows
    }

    /// The rows of the observations an earlier build kept in `last-state.json`
    /// (24 h, thinned to 5 minutes). Claude only, like `rows(from:)`.
    ///
    /// `usedPercent` is `100 - remainingPercent`; `remainingPercent` was
    /// clamped to 0...100 when recorded, so a reading above 100% is not
    /// recoverable. An observation with no `source` came from a build that did
    /// not record it, and some of those are CLI echoes stamped with the landing
    /// time: it becomes `.unknown`, never `.oauth`. `readingMs` is `observedAt`
    /// and `recordedMs` the same, since the landing time was not kept. Every
    /// row is flagged `.legacy`; plan, tier, cycle and every detail are nil.
    nonisolated static func legacyRows(from observations: [QuotaObservation]) -> [QuotaSampleRow] {
        var seen = Set<String>()
        var rows: [QuotaSampleRow] = []
        for observation in observations {
            guard QuotaHistoryPolicy.ingestedProviders.contains(observation.provider),
                  observation.remainingPercent.isFinite,
                  isStorableWindowID(observation.windowID),
                  let observedMs = Self.milliseconds(observation.observedAt) else { continue }
            let source: QuotaSampleSource
            if let recorded = observation.source {
                guard let mapped = QuotaSampleSource(recorded) else { continue }
                source = mapped
            } else {
                source = .unknown
            }
            guard seen.insert("\(observation.provider.rawValue)|\(observation.windowID)|\(source.rawValue)|\(observedMs)").inserted
            else { continue }
            rows.append(QuotaSampleRow(
                provider: observation.provider,
                windowID: observation.windowID,
                source: source,
                readingMs: observedMs,
                fetchedMs: nil,
                cachedMs: nil,
                recordedMs: observedMs,
                usedPercent: 100 - observation.remainingPercent,
                resetsAtMs: observation.resetsAt.flatMap(Self.milliseconds),
                cycleSeconds: nil,
                isModelScoped: nil,
                isOneTimeCredit: nil,
                isActive: nil,
                severity: nil,
                lockedReason: nil,
                scopeName: nil,
                shareUsedOfWeekly: nil,
                shareAllowanceOfWeekly: nil,
                plan: nil,
                tier: nil,
                flags: [.legacy]
            ))
        }
        return rows
    }

    nonisolated private static func isStorableWindowID(_ id: String) -> Bool {
        guard !id.isEmpty, id.unicodeScalars.count <= QuotaHistoryPolicy.maxWindowIDLength else { return false }
        return !id.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// `HistoryTime.ms` traps on a date that is not finite; a snapshot is
    /// untrusted enough that this is checked first.
    nonisolated static func historyMilliseconds(_ date: Date) -> Int64? { milliseconds(date) }

    nonisolated private static func milliseconds(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 1e12 else { return nil }
        return HistoryTime.ms(date)
    }

    nonisolated private static func wholeSeconds(_ interval: TimeInterval?) -> Int? {
        guard let interval, interval.isFinite, interval > 0, interval < 1e9 else { return nil }
        return Int(interval.rounded())
    }
}

extension QuotaSampleSource {
    /// The source a snapshot's kind is stored as; nil for the two kinds that
    /// are never stored.
    nonisolated init?(_ kind: QuotaSnapshot.SourceKind) {
        switch kind {
        case .oauth: self = .oauth
        case .cli: self = .cli
        case .appServer: self = .appServer
        case .rolloutFile, .unavailable: return nil
        }
    }
}

// MARK: - Reset grants

extension ResetGrantObservation {
    /// The grants of a landed `ClaudeResetState` as the history stores them.
    /// The whole current set: the store keeps it only when it differs from the
    /// last stored one. An empty state (no grants, ineligible, never any) maps
    /// to an empty set, which is a real answer.
    ///
    /// Sorted by id (then deadline, count and `clears`) so equal sets map to
    /// equal arrays whatever order the response listed them in. `clears` is the
    /// grant's window keys sorted and comma-joined; `endsAtMs` is nil when the
    /// response stated no deadline.
    nonisolated static func observations(from state: ClaudeResetState) -> [ResetGrantObservation] {
        state.grants.map { grant in
            ResetGrantObservation(
                id: grant.id,
                resetsLeft: grant.resetsLeft,
                endsAtMs: grant.endsAt.flatMap(QuotaSampleRow.historyMilliseconds),
                clears: grant.clears.sorted().joined(separator: ",")
            )
        }
        .sorted {
            ($0.id, $0.endsAtMs ?? .max, $0.resetsLeft ?? .min, $0.clears)
                < ($1.id, $1.endsAtMs ?? .max, $1.resetsLeft ?? .min, $1.clears)
        }
    }
}

// MARK: - Thinning fingerprint

/// What the store compares to decide that a new reading of a window adds
/// nothing: the thinning rule skips a reading that is newer than the last one
/// stored, has an equal fingerprint and comes less than the heartbeat after
/// it. Everything a consumer of the history could tell apart goes in; times
/// do not (the rule reads those itself).
struct QuotaSampleFingerprint: Hashable, Sendable {
    /// nil for a window whose utilization was not stated, so one that stops
    /// stating it differs from one that read 0.
    let usedPercent: Double?
    let resetEpochSeconds: Int64?
    let isActive: Bool?
    let severity: String?
    let shareUsed: Double?
    let shareAllowance: Double?
    let lockedReason: String?

    nonisolated init(_ row: QuotaSampleRow) {
        usedPercent = row.usedPercent
        resetEpochSeconds = row.resetEpochSeconds
        isActive = row.isActive
        severity = row.severity
        shareUsed = row.shareUsedOfWeekly
        shareAllowance = row.shareAllowanceOfWeekly
        lockedReason = row.lockedReason
    }
}

// MARK: - Reset detection

/// The `kind` column of `reset_event`: the raw values are what the table stores.
enum ResetEventKind: String, Sendable, Equatable, CaseIterable {
    /// The reset instant moved on and the percentage dropped: the window
    /// refilled on its own schedule (or, when `detectedMs` is well before the
    /// previous epoch, a reset was spent and gave the window a new epoch; the
    /// draft carries both epochs so a reader can tell).
    case epochRollover = "epoch_rollover"
    /// The percentage fell by at least `ResetDetector.earlyDropMinPoints` while
    /// the reset instant stayed or moved earlier: usage was given back inside
    /// an epoch.
    case earlyDrop = "early_drop"
}

/// A detected reset, before it is stored. `detectedMs` is the reading time of
/// the first sample that shows it.
struct ResetEventDraft: Sendable, Equatable {
    let provider: Provider
    let windowID: String
    let kind: ResetEventKind
    let detectedMs: Int64
    let prevSampleMs: Int64
    let prevPercent: Double
    let newPercent: Double
    let prevEpochSeconds: Int64?
    let newEpochSeconds: Int64?
}

/// Reset detection over two consecutive samples of one window. Pure: the store
/// feeds it neighbours read from `quota_sample` (incrementally on ingest, and
/// again by `rebuildResetEvents()`; both must give the same events for an
/// in-order stream).
///
/// Only Claude OAuth samples qualify. The CLI scrape carries no reset time and
/// `.unknown` rows are legacy; neither is a measurement of the window's epoch.
/// A grant being spent cannot be told from a rollover without grant data, so
/// no kind for it exists here.
enum ResetDetector {
    /// Bumped whenever a rule below changes, so stored events can be told from
    /// a re-derivation by a newer detector.
    static let detectorVersion = 1

    /// The smallest in-epoch fall that counts as a reset. A design choice, not
    /// a measurement: it is above the 1-2 point wobble a re-scored utilization
    /// could show and far below the 20-100 points an emptied 5-hour or weekly
    /// window gives back. Revisit with real `reset_event` rows.
    static let earlyDropMinPoints = 5.0

    /// Any fall at all counts when the epoch moved: the window has a new
    /// period, so its used percent restarting is expected, whatever the old
    /// value was. Strictly greater than this.
    static let epochRolloverMinDropPoints = 0.0

    /// Classifies `next` against the sample before it, or nil when it is not a
    /// reset (or the pair is not comparable).
    ///
    /// The reset instants compared are `resetEpochSeconds`, `resetsAt` rounded
    /// to the nearest minute: Claude's own instants jitter around the minute
    /// (59.979 s and 0.005 s past it both seen for one epoch), which rounding
    /// to the nearest collapses and flooring would split into two epochs.
    nonisolated static func detect(previous: QuotaSampleRow, next: QuotaSampleRow) -> ResetEventKind? {
        guard previous.provider == .claude, next.provider == .claude,
              previous.source == .oauth, next.source == .oauth,
              previous.windowID == next.windowID,
              next.readingMs > previous.readingMs,
              // A window that never refills has no resets, and a window that
              // stated no utilization has no value to fall from or to.
              previous.isOneTimeCredit != true, next.isOneTimeCredit != true,
              !previous.flags.contains(.valueNotStated), !next.flags.contains(.valueNotStated),
              let previousUsed = previous.usedPercent, let nextUsed = next.usedPercent
        else { return nil }
        let drop = previousUsed - nextUsed
        guard drop.isFinite else { return nil }

        let before = previous.resetEpochSeconds
        let after = next.resetEpochSeconds
        // A window with no reset time before or after (an idle 5-hour) counts
        // as having moved on when the other side has one.
        let epochMovedEarlier: Bool
        if let before, let after { epochMovedEarlier = after < before } else { epochMovedEarlier = false }
        if before != after, !epochMovedEarlier {
            return drop > epochRolloverMinDropPoints ? .epochRollover : nil
        }
        return drop >= earlyDropMinPoints ? .earlyDrop : nil
    }

    /// `detect` with the event's facts filled in.
    nonisolated static func draft(previous: QuotaSampleRow, next: QuotaSampleRow) -> ResetEventDraft? {
        guard let kind = detect(previous: previous, next: next),
              let previousUsed = previous.usedPercent, let nextUsed = next.usedPercent else { return nil }
        return ResetEventDraft(
            provider: next.provider,
            windowID: next.windowID,
            kind: kind,
            detectedMs: next.readingMs,
            prevSampleMs: previous.readingMs,
            prevPercent: previousUsed,
            newPercent: nextUsed,
            prevEpochSeconds: previous.resetEpochSeconds,
            newEpochSeconds: next.resetEpochSeconds
        )
    }
}
