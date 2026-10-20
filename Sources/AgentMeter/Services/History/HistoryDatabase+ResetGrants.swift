import Foundation

// `reset_grant_sample`: the grant set `ClaudeResetGrantFetcher` already fetched,
// stored only when it differs from the set in force at its time (no extra request).

extension HistoryDatabase {
    /// `grant_id` of the one row that stands for an EMPTY set (no grants,
    /// ineligible): an empty set is a real answer, and the table has no other
    /// way to say "the set became empty at T".
    static let emptyGrantSetMarker = ""

    /// A grant id is stored only when it is 1 to this many printable ASCII
    /// bytes, like the other server labels the history keeps. The fetcher
    /// already holds ids to `[a-z0-9_-]{1,40}`; a state decoded from elsewhere
    /// is not checked there.
    static let maxGrantIDBytes = 64

    /// Stores `grants` as of `recordedMs` when they differ from the set in
    /// force at that time: the set at the newest `recorded_ms` not after it
    /// (or nothing is stored yet). Compared as arrays in the canonical order of
    /// `ResetGrantObservation.observations`; a repeated id keeps its first
    /// entry (the key is (recorded_ms, grant_id)). Skipped whole, writing
    /// nothing:
    ///  * a set with an unusable id (`maxGrantIDBytes`): storing it without
    ///    that grant would record a set that was never answered;
    ///  * a different set at a `recorded_ms` that already holds one: the two
    ///    could not be told apart under one time, so the first one stays.
    /// Comparing with the set in force at `recordedMs` (not the newest one)
    /// also keeps a clock set back from writing the same set every refresh.
    /// Returns whether anything was written. Inside the store's transaction.
    @discardableResult
    func applyResetGrants(_ grants: [ResetGrantObservation], recordedMs: Int64) throws -> Bool {
        guard grants.allSatisfy({ HistoryObservationCheck.isPrintableASCII($0.id, maxBytes: Self.maxGrantIDBytes) })
        else { return false }
        var seen = Set<String>()
        let incoming = Self.canonicalGrants(grants.filter { seen.insert($0.id).inserted })
        if let inForce = try storedGrantSet(atOrBefore: recordedMs),
           inForce.grants == incoming || inForce.recordedMs == recordedMs { return false }
        let rows: [ResetGrantObservation] = incoming.isEmpty
            ? [ResetGrantObservation(id: Self.emptyGrantSetMarker, resetsLeft: nil, endsAtMs: nil, clears: "")]
            : incoming
        var wrote = false
        for g in rows {
            try conn.withStatement("""
                INSERT INTO reset_grant_sample(recorded_ms, grant_id, resets_left, ends_at_ms, clears)
                VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT DO NOTHING
                """) { s in
                s.bind(1, recordedMs)
                s.bind(2, g.id)
                s.bind(3, g.resetsLeft.map(Int64.init))
                s.bind(4, g.endsAtMs)
                s.bind(5, g.id == Self.emptyGrantSetMarker ? nil : g.clears)
                try s.step()
            }
            wrote = wrote || conn.lastChanges > 0
        }
        return wrote
    }

    /// The set at the newest `recorded_ms`; `[]` for the empty-set marker, nil when nothing is stored.
    func lastStoredGrantSet() throws -> [ResetGrantObservation]? {
        try storedGrantSet(atOrBefore: .max)?.grants
    }

    /// The set at the newest `recorded_ms` that is `<= ms`, with that time.
    private func storedGrantSet(atOrBefore ms: Int64) throws -> (recordedMs: Int64, grants: [ResetGrantObservation])? {
        try conn.withStatement("""
            SELECT recorded_ms, grant_id, resets_left, ends_at_ms, clears FROM reset_grant_sample
            WHERE recorded_ms = (SELECT max(recorded_ms) FROM reset_grant_sample WHERE recorded_ms <= ?1)
            """) { s -> (Int64, [ResetGrantObservation])? in
            s.bind(1, ms)
            var out: [ResetGrantObservation] = []
            var at: Int64?
            while try s.step() {
                at = s.int64(0)
                let id = s.text(1) ?? ""
                if id == Self.emptyGrantSetMarker { continue }
                out.append(ResetGrantObservation(id: id, resetsLeft: s.optionalInt64(2).map(Int.init),
                                                 endsAtMs: s.optionalInt64(3), clears: s.text(4) ?? ""))
            }
            return at.map { ($0, Self.canonicalGrants(out)) }
        }
    }

    /// The order `ResetGrantObservation.observations` produces: id, then
    /// deadline (nil last), resets left (nil first), clears.
    static func canonicalGrants(_ g: [ResetGrantObservation]) -> [ResetGrantObservation] {
        g.sorted {
            ($0.id, $0.endsAtMs ?? .max, $0.resetsLeft ?? .min, $0.clears)
                < ($1.id, $1.endsAtMs ?? .max, $1.resetsLeft ?? .min, $1.clears)
        }
    }
}
