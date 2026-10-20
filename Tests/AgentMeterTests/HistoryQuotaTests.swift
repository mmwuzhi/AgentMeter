import Foundation
import XCTest
@testable import AgentMeter

/// `quota_sample`, `reset_event`, `reset_grant_sample`.
final class HistoryQuotaTests: XCTestCase {
    let t0: Int64 = 1_790_000_000_000
    let epoch: Int64 = 1_790_018_000_000

    func row(_ window: String = "five_hour", source: QuotaSampleSource = .oauth, provider: Provider = .claude,
             at reading: Int64, recorded: Int64? = nil, used: Double? = 10, resetsAt: Int64? = nil,
             isActive: Bool? = nil, scopeName: String? = nil, flags: QuotaSampleRow.Flags = []) -> QuotaSampleRow {
        QuotaSampleRow(provider: provider, windowID: window, source: source, readingMs: reading, fetchedMs: reading,
                       cachedMs: nil, recordedMs: recorded ?? reading + 500, usedPercent: used,
                       resetsAtMs: resetsAt ?? epoch, cycleSeconds: 18_000, isModelScoped: scopeName != nil,
                       isOneTimeCredit: false, isActive: isActive, severity: nil, lockedReason: nil, scopeName: scopeName,
                       shareUsedOfWeekly: nil, shareAllowanceOfWeekly: nil, plan: "max", tier: "default_claude_max_20x",
                       flags: flags)
    }

    func samples(_ store: HistoryStore, where clause: String = "1") async throws -> [String] {
        try await store.withDatabase { db in
            try db.conn.queryTexts("""
                SELECT provider || '|' || window_id || '|' || source || '|' || reading_ms || '|' ||
                       coalesce(used_percent, 'NULL') || '|' || flags
                FROM quota_sample WHERE \(clause) ORDER BY provider, window_id, source, reading_ms
                """)
        }
    }

    func conflicts(_ store: HistoryStore) async throws -> Int64 {
        try await store.withDatabase { try $0.metaInt("quota_conflicts") ?? 0 }
    }

    // MARK: Natural key

    func testTheNaturalKeySeparatesWindowsSourcesAndProviders() async throws {
        let store = hmStore(historyTempDirectory()) { $0.quotaProviders = [.claude, .copilot] }
        try await store.applyQuotaCommand([row("five_hour", at: t0), row("seven_day", at: t0),
                                          row("five_hour", source: .cli, at: t0),
                                          row("five_hour", source: .cli, provider: .copilot, at: t0)])
        let stored = try await samples(store)
        XCTAssertEqual(stored.count, 4, "two windows at one time; oauth vs cli at one time; cli vs copilot at one time")
        let defaultStore = hmStore(historyTempDirectory())
        try await defaultStore.applyQuotaCommand([row(source: .cli, at: t0), row(source: .cli, provider: .copilot, at: t0)])
        let claudeOnly = try await samples(defaultStore)
        XCTAssertEqual(claudeOnly, ["claude|five_hour|cli|\(t0)|10.0|0"], "the store re-checks the allowlist")
    }

    func testAJoinedFlightLandsOnceAndIsNoConflict() async throws {
        let store = hmStore(historyTempDirectory())
        try await store.applyQuotaCommand([row(at: t0, recorded: t0 + 1)])
        try await store.applyQuotaCommand([row(at: t0, recorded: t0 + 9_000)])
        let stored = try await samples(store)
        XCTAssertEqual(stored.count, 1)
        let n = try await conflicts(store)
        XCTAssertEqual(n, 0, "recorded_ms is not a measured field")
    }

    func testAConflictIsCountedOnlyWhenAMeasuredFieldDiffersAndTheFirstWriterWins() async throws {
        let store = hmStore(historyTempDirectory())
        try await store.applyQuotaCommand([row(at: t0, used: 10)])
        try await store.applyQuotaCommand([row(at: t0, used: 11)])
        try await store.applyQuotaCommand([row(at: t0, used: 10, resetsAt: epoch + 3_600_000)])
        try await store.applyQuotaCommand([row(at: t0, used: 10, scopeName: "Fable")])
        try await store.applyQuotaCommand([row(at: t0, recorded: t0 + 77, used: 10)])
        let n = try await conflicts(store)
        XCTAssertEqual(n, 3)
        let stored = try await samples(store)
        XCTAssertEqual(stored, ["claude|five_hour|oauth|\(t0)|10.0|0"])
    }

    func testLegacyRowsWithoutASourceAreUnknownAndNeverReachTheOAuthHelper() async throws {
        let store = hmStore(historyTempDirectory())
        let legacy = QuotaSampleRow.legacyRows(from: [
            QuotaObservation(provider: .claude, windowID: "five_hour", remainingPercent: 70,
                             observedAt: HistoryTime.date(ms: t0), resetsAt: nil, source: nil),
            QuotaObservation(provider: .claude, windowID: "five_hour", remainingPercent: 60,
                             observedAt: HistoryTime.date(ms: t0 + 60_000), resetsAt: nil, source: .oauth),
        ])
        store.submit(legacyQuota: legacy)
        await store.flush()
        let stored = try await samples(store)
        XCTAssertEqual(stored, ["claude|five_hour|oauth|\(t0 + 60_000)|40.0|1", "claude|five_hour|unknown|\(t0)|30.0|1"])
        let oauth = try await store.oauthSamples(window: "five_hour")
        XCTAssertEqual(oauth.map(\.readingMs), [t0 + 60_000], "unknown never stands in for oauth")
    }

    func testValueNotStatedIsNullAndAFutureReadingKeepsItsRawTime() async throws {
        let store = hmStore(historyTempDirectory())
        try await store.applyQuotaCommand([row("seven_day_fable", at: t0, used: nil, flags: .valueNotStated),
                                          row("five_hour", at: t0 + 5_000, recorded: t0, flags: .futureReading)])
        let stored = try await samples(store)
        XCTAssertEqual(stored, ["claude|five_hour|oauth|\(t0 + 5_000)|10.0|2", "claude|seven_day_fable|oauth|\(t0)|NULL|4"])
    }

    func testRowsWithNonFiniteValuesAreNotStored() async throws {
        let store = hmStore(historyTempDirectory())
        try await store.applyQuotaCommand([row(at: t0, used: .nan), row(at: t0 + 1, used: .infinity)])
        let stored = try await samples(store)
        XCTAssertEqual(stored, [])
        let stats = await store.statistics()
        XCTAssertEqual(stats.skippedInvalidEvents, 2)
    }

    // MARK: Thinning

    func readings(_ store: HistoryStore) async throws -> [Int64] {
        try await store.withDatabase { db in
            try db.conn.queryTexts("SELECT reading_ms FROM quota_sample ORDER BY reading_ms").compactMap { Int64($0) }
        }
    }

    func testUnchangedReadingsAreThinnedWithAHeartbeatEveryTenMinutes() async throws {
        let store = hmStore(historyTempDirectory())
        for minute in 0...21 { try await store.applyQuotaCommand([row(at: t0 + Int64(minute) * 60_000)]) }
        let stored = try await readings(store)
        XCTAssertEqual(stored, [t0, t0 + 600_000, t0 + 1_200_000])
    }

    func testAChangeIsStoredWithTheLastSkippedReadingBeforeIt() async throws {
        let store = hmStore(historyTempDirectory())
        for minute in 0...3 { try await store.applyQuotaCommand([row(at: t0 + Int64(minute) * 60_000, used: 10)]) }
        try await store.applyQuotaCommand([row(at: t0 + 4 * 60_000, used: 12)])
        try await store.applyQuotaCommand([row(at: t0 + 5 * 60_000, used: 3, resetsAt: epoch + 18_000_000)])
        let stored = try await readings(store)
        XCTAssertEqual(stored, [t0, t0 + 180_000, t0 + 240_000, t0 + 300_000],
                       "the reading just before the step (minute 3) is kept; no skipped reading before minute 5")
    }

    func testAnOutOfOrderReadingIsStoredWithoutMovingTheThinningState() async throws {
        let store = hmStore(historyTempDirectory())
        try await store.applyQuotaCommand([row(at: t0 + 600_000)])
        try await store.applyQuotaCommand([row(at: t0 + 60_000)])                  // older: stored
        try await store.applyQuotaCommand([row(at: t0 + 660_000)])                 // unchanged, 1 min after the newest: skipped
        let stored = try await readings(store)
        XCTAssertEqual(stored, [t0 + 60_000, t0 + 600_000])
    }

    func testARestartReseedsTheThinningStateFromTheNewestStoredRow() async throws {
        let dir = historyTempDirectory()
        var store = hmStore(dir)
        try await store.applyQuotaCommand([row(at: t0), row(at: t0 + 300_000, used: 20)])
        await store.close()
        store = hmStore(dir)
        try await store.applyQuotaCommand([row(at: t0 + 360_000, used: 20)])       // same as the newest stored, 1 min later
        try await store.applyQuotaCommand([row(at: t0 + 420_000, used: 10)])       // a change against the newest (20), not the first (10)
        let stored = try await readings(store)
        XCTAssertEqual(stored, [t0, t0 + 300_000, t0 + 360_000, t0 + 420_000])
    }

    // MARK: Reset events

    func testIncrementalResetEventsEqualTheRebuild() async throws {
        let store = hmStore(historyTempDirectory())
        var stream: [QuotaSampleRow] = []
        var used = 40.0
        for minute in 0..<60 {
            let at = t0 + Int64(minute) * 60_000
            if minute == 20 { used = 2 }                                            // rollover: new epoch, lower value
            if minute == 40 { used = 1 }                                            // within an epoch, less than 5 points
            if minute == 50 { used = 30 }
            if minute == 55 { used = 10 }                                           // early drop of 20 points
            let reset = minute >= 20 ? epoch + 18_000_000 : epoch
            stream.append(row(at: at, used: used, resetsAt: reset))
            stream.append(row("seven_day", at: at, used: minute < 30 ? 50 : 49, resetsAt: epoch * 2))
        }
        for r in stream { try await store.applyQuotaCommand([r]) }
        let events = { () async throws -> [String] in
            try await store.withDatabase { db in
                try db.conn.queryTexts("""
                    SELECT window_id || '|' || kind || '|' || detected_ms || '|' || prev_sample_ms || '|' ||
                           prev_percent || '|' || new_percent || '|' || coalesce(prev_epoch_s, '-') || '|' ||
                           coalesce(new_epoch_s, '-') FROM reset_event ORDER BY window_id, detected_ms, kind
                    """)
            }
        }
        let incremental = try await events()
        XCTAssertEqual(incremental.map { $0.split(separator: "|").prefix(3).joined(separator: "|") },
                       ["five_hour|epoch_rollover|\(t0 + 20 * 60_000)", "five_hour|early_drop|\(t0 + 55 * 60_000)"])
        let rebuilt = try await store.rebuildResetEvents()
        XCTAssertEqual(rebuilt, 2)
        let afterRebuild = try await events()
        XCTAssertEqual(afterRebuild, incremental)
    }

    // MARK: Legacy import and grants

    func testTheLegacyImportRunsOncePerDatabase() async throws {
        let store = hmStore(historyTempDirectory())
        try await store.applyQuotaCommand([row(source: .unknown, at: t0, used: 30, flags: .legacy)])
        store.submit(legacyQuota: [row(source: .unknown, at: t0, used: 30, flags: .legacy),
                                   row(source: .unknown, at: t0 + 300_000, used: 31, flags: .legacy)])
        store.submit(legacyQuota: [row(source: .unknown, at: t0 + 600_000, used: 32, flags: .legacy)])
        await store.flush()
        let stored = try await readings(store)
        XCTAssertEqual(stored, [t0, t0 + 300_000], "deduped by the natural key; the second import is ignored")
        let flag = try await store.withDatabase { try $0.metaInt("legacy_quota_imported") }
        XCTAssertNotNil(flag)
    }

    func testResetGrantsAreStoredOnlyWhenTheSetChanges() async throws {
        let store = hmStore(historyTempDirectory())
        let g1 = ResetGrantObservation(id: "g1", resetsLeft: 1, endsAtMs: t0 + 86_400_000, clears: "five_hour,seven_day")
        let g1Spent = ResetGrantObservation(id: "g1", resetsLeft: 0, endsAtMs: t0 + 86_400_000, clears: "five_hour,seven_day")
        let g2 = ResetGrantObservation(id: "g2", resetsLeft: 2, endsAtMs: nil, clears: "five_hour")
        let sets: [[ResetGrantObservation]] = [[], [], [g1], [g1], [g2, g1], [g1, g2], [g1Spent, g2], []]
        for (n, set) in sets.enumerated() { store.submit(resetGrants: set, recordedMs: t0 + Int64(n)) }
        await store.flush()
        let base = t0
        let stored = try await store.withDatabase { db in
            try db.conn.queryTexts("""
                SELECT (recorded_ms - \(base)) || ':' || grant_id || ':' || coalesce(resets_left, '-')
                FROM reset_grant_sample ORDER BY recorded_ms, grant_id
                """)
        }
        XCTAssertEqual(stored, ["0::-", "2:g1:1", "4:g1:1", "4:g2:2", "6:g1:0", "6:g2:2", "7::-"],
                       "an empty set is a real answer (one marker row); equal sets in any order are not stored again")
    }

    func grantRows(_ store: HistoryStore) async throws -> [String] {
        let base = t0
        return try await store.withDatabase { db in
            try db.conn.queryTexts("""
                SELECT (recorded_ms - \(base)) || ':' || grant_id FROM reset_grant_sample ORDER BY recorded_ms, grant_id
                """)
        }
    }

    /// Two sets cannot be kept apart under one `recorded_ms` (the key is
    /// (recorded_ms, grant_id)): the second is skipped, never merged into a
    /// set nobody answered.
    func testADifferentGrantSetAtAnAlreadyStoredTimeIsSkippedNotMerged() async throws {
        let store = hmStore(historyTempDirectory())
        let g1 = ResetGrantObservation(id: "g1", resetsLeft: 1, endsAtMs: nil, clears: "five_hour")
        let g2 = ResetGrantObservation(id: "g2", resetsLeft: 1, endsAtMs: nil, clears: "seven_day")
        store.submit(resetGrants: [g1], recordedMs: t0)
        store.submit(resetGrants: [g2], recordedMs: t0)
        store.submit(resetGrants: [], recordedMs: t0)
        await store.flush()
        let last = try await store.withDatabase { try $0.lastStoredGrantSet() }
        XCTAssertEqual(last?.map(\.id), ["g1"])
        let rows = try await grantRows(store)
        XCTAssertEqual(rows, ["0:g1"])
        store.submit(resetGrants: [g2], recordedMs: t0 + 60_000)
        await store.flush()
        let next = try await store.withDatabase { try $0.lastStoredGrantSet() }
        XCTAssertEqual(next?.map(\.id), ["g2"], "the next refresh stores the change")
    }

    /// A clock set back below the newest stored time: a set is compared with
    /// the set in force at ITS time, so an unchanged set is written once, not
    /// on every refresh until the clock passes the newest stored time.
    func testAClockSetBackWritesAChangedGrantSetOnce() async throws {
        let store = hmStore(historyTempDirectory())
        let g1 = ResetGrantObservation(id: "g1", resetsLeft: 1, endsAtMs: nil, clears: "five_hour")
        let g2 = ResetGrantObservation(id: "g2", resetsLeft: 1, endsAtMs: nil, clears: "seven_day")
        store.submit(resetGrants: [g1], recordedMs: t0 + 600_000)
        for minute in 0..<5 { store.submit(resetGrants: [g2], recordedMs: t0 + Int64(minute) * 60_000) }
        await store.flush()
        let rows = try await grantRows(store)
        XCTAssertEqual(rows, ["0:g2", "600000:g1"])
        let last = try await store.withDatabase { try $0.lastStoredGrantSet() }
        XCTAssertEqual(last?.map(\.id), ["g1"], "the newest recorded_ms still names the last set")
    }

    /// Grant ids are server text: 1-64 printable ASCII bytes or the whole set
    /// is skipped (storing it without the grant would record a set never answered).
    func testAGrantSetWithAnUnusableIDIsNotStored() async throws {
        let store = hmStore(historyTempDirectory())
        func grant(_ id: String) -> ResetGrantObservation {
            ResetGrantObservation(id: id, resetsLeft: 1, endsAtMs: nil, clears: "five_hour")
        }
        let longest = String(repeating: "g", count: 64)
        store.submit(resetGrants: [grant(longest)], recordedMs: t0)
        for (n, bad) in [String(repeating: "g", count: 65), String(repeating: "x", count: 5_000), "g\n1", "g\u{202E}1", "",
                         "\u{4E2D}"].enumerated() {
            store.submit(resetGrants: [grant("g1"), grant(bad)], recordedMs: t0 + 60_000 * Int64(n + 1))
        }
        await store.flush()
        let rows = try await grantRows(store)
        XCTAssertEqual(rows, ["0:\(longest)"])
    }
}
