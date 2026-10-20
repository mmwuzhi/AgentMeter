import Foundation
import XCTest
@testable import AgentMeter

/// `acct_day`: the Gregorian day of `first_seen_ms` in `meta.acct_tz`, and the
/// recompute when the zone changes.
final class HistoryDayTests: XCTestCase {
    /// Times around midnights of both zones and both 2026 DST switches of Los Angeles.
    func contributions() -> [HMContribution] {
        var instants: [Int64] = []
        for (y, m, d) in [(2026, 3, 8), (2026, 3, 9), (2026, 11, 1), (2026, 11, 2), (2026, 9, 20)] {
            for zone in [hmTokyo, hmLosAngeles] {
                let midnight = hmMidnight(zone, y, m, d)
                instants += [midnight - 1, midnight, midnight + 90 * 60_000, midnight + 23 * 3_600_000 + 30 * 60_000]
            }
        }
        let a = instants.enumerated().map { n, t in
            hmObs(hmKey(n), [hmPart(output: n % 5)], .final, first: t, last: t + 5, final: t)
        }
        let noTime = hmObs(hmKey(999), [hmPart(output: 1)], .partial, first: nil, last: nil)
        return [HMContribution(path: "/p/proj/s1.jsonl", version: hmParserVersion, observations: a + [noTime])]
    }

    func ingest(_ c: [HMContribution], into store: HistoryStore) async throws {
        for (n, item) in c.enumerated() {
            try await store.applyScanCommand(hmScan(UInt64(n + 1), [hmFile(item.path, scan: UInt64(n + 1),
                                                                           watermark: hmWatermark(id: 9, parsed: 10),
                                                                           item.observations)]))
        }
    }

    func testAZoneChangeRecomputesEveryDayExactlyAsAFreshIngestUnderTheNewZone() async throws {
        let dir = historyTempDirectory("tokyo")
        let c = contributions()
        var store = hmStore(dir, timeZone: hmTokyo)
        try await ingest(c, into: store)
        let tokyo = try await store.logicalDump()
        XCTAssertEqual(tokyo, HMOracle.dump(c, births: [:], timeZone: hmTokyo))
        await store.close()

        store = hmStore(dir, timeZone: hmLosAngeles)
        try await store.applyScanCommand(hmScan(1, []))        // the first command switches the zone
        let switched = try await store.logicalDump()
        let freshStore = hmStore(historyTempDirectory("la"), timeZone: hmLosAngeles)
        try await ingest(c, into: freshStore)
        let fresh = try await freshStore.logicalDump()
        XCTAssertEqual(switched, fresh, hmDiff(switched, fresh))
        XCTAssertNotEqual(switched, tokyo, "the fixture straddles midnights, so the days must move")
        let zone = try await store.withDatabase { try $0.metaText("acct_tz") }
        XCTAssertEqual(zone, "America/Los_Angeles")
        await store.close()

        store = hmStore(dir, timeZone: hmTokyo)
        try await store.applyScanCommand(hmScan(2, []))
        let back = try await store.logicalDump()
        XCTAssertEqual(back, tokyo, "and back")
    }

    func testDaysAreGregorianYYYYMMDDAcrossDSTSwitches() {
        var la = HistoryAccountingDays(timeZone: hmLosAngeles)
        let fallBack = hmMidnight(hmLosAngeles, 2026, 11, 1)
        XCTAssertEqual(la.day(fallBack), 20_261_101)
        XCTAssertEqual(la.day(fallBack + 24 * 3_600_000), 20_261_101, "the 25-hour day: 24 h after midnight is still Nov 1")
        XCTAssertEqual(la.day(fallBack + 25 * 3_600_000), 20_261_102)
        let springForward = hmMidnight(hmLosAngeles, 2026, 3, 8)
        XCTAssertEqual(la.day(springForward + 23 * 3_600_000 - 1), 20_260_308)
        XCTAssertEqual(la.day(springForward + 23 * 3_600_000), 20_260_309, "the 23-hour day")
        XCTAssertEqual(la.day(springForward - 1), 20_260_307, "the cache must not answer outside its day")
        XCTAssertNil(la.day(nil))
    }

    /// The day never comes from `Calendar.current`: a Japanese-calendar system
    /// would give year 8 (Reiwa) for 2026. Overriding the process's current
    /// calendar is not possible in-process, so this pins the construction.
    func testTheDayIsGregorianWhateverCalendarTheSystemUses() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = hmTokyo
        let instant = hmMidnight(hmTokyo, 2026, 9, 20) + 1
        XCTAssertEqual(japanese.component(.year, from: HistoryTime.date(ms: instant)), 8)
        var days = HistoryAccountingDays(timeZone: hmTokyo)
        XCTAssertEqual(days.day(instant), 20_260_920)
    }

    // MARK: A DST change at midnight

    /// Walks `cases` (ascending) through ONE cache, so every lookup after the
    /// first is answered by whatever the earlier ones left cached.
    func assertDays(_ zone: String, _ cases: [(ms: Int64, day: Int64)], file: StaticString = #filePath, line: UInt = #line) {
        let tz = TimeZone(identifier: zone)!
        var days = HistoryAccountingDays(timeZone: tz)
        for (ms, want) in cases {
            XCTAssertEqual(hmDay(ms, tz), want, "\(zone) \(ms): the fixture disagrees with Foundation", file: file, line: line)
            XCTAssertEqual(days.day(ms), want, "\(zone) \(ms)", file: file, line: line)
        }
    }

    /// Santiago (2026-09-06), Cairo (2026-04-24) and Havana (2026-03-08) start
    /// DST at 00:00 -> 01:00: the day begins at 01:00, and one day after that
    /// is 01:00 of the NEXT day, whose first hour must not be served from the
    /// cache as the transition day. Santiago (2026-04-05) and Cairo
    /// (2026-10-29) fall back at midnight, Havana (2026-11-01) at 01:00, giving
    /// repeated wall times around a day boundary. Times are UTC instants.
    func testDaysAroundADSTChangeAtMidnightWithAPrimedCache() {
        let minute: Int64 = 60_000, hour: Int64 = 3_600_000
        let scl: Int64 = 1_788_750_000_000          // 2026-09-07 00:00 -03, the day after the 00:00 -> 01:00 jump
        assertDays("America/Santiago", [
            (scl - 12 * hour, 20_260_906), (scl - 1, 20_260_906), (scl, 20_260_907),
            (scl + 30 * minute, 20_260_907), (scl + hour - 1, 20_260_907), (scl + hour, 20_260_907),
        ])
        let sclBack: Int64 = 1_775_358_000_000      // 2026-04-05 00:00 -03 -> 2026-04-04 23:00 -04
        assertDays("America/Santiago", [
            (sclBack - 12 * hour, 20_260_404), (sclBack - 1, 20_260_404), (sclBack, 20_260_404),
            (sclBack + 30 * minute, 20_260_404), (sclBack + hour - 1, 20_260_404), (sclBack + hour, 20_260_405),
            (sclBack + 2 * hour, 20_260_405),
        ])
        let caiStart: Int64 = 1_776_981_600_000     // 2026-04-24 01:00 +03, the first instant of Apr 24
        let cai: Int64 = 1_777_064_400_000          // 2026-04-25 00:00 +03
        assertDays("Africa/Cairo", [
            (caiStart - 1, 20_260_423), (caiStart, 20_260_424), (cai - 12 * hour, 20_260_424), (cai - 1, 20_260_424),
            (cai, 20_260_425), (cai + 30 * minute, 20_260_425), (cai + hour - 1, 20_260_425), (cai + hour, 20_260_425),
        ])
        let caiBack: Int64 = 1_793_307_600_000      // 2026-10-29 24:00 +03 -> 23:00 +02
        assertDays("Africa/Cairo", [
            (caiBack - 12 * hour, 20_261_029), (caiBack - 1, 20_261_029), (caiBack, 20_261_029),
            (caiBack + 30 * minute, 20_261_029), (caiBack + hour - 1, 20_261_029), (caiBack + hour, 20_261_030),
            (caiBack + 2 * hour, 20_261_030),
        ])
        let havStart: Int64 = 1_772_946_000_000     // 2026-03-08 01:00 -04, the first instant of Mar 8
        let hav: Int64 = 1_773_028_800_000          // 2026-03-09 00:00 -04
        assertDays("America/Havana", [
            (havStart - 1, 20_260_307), (havStart, 20_260_308), (hav - 12 * hour, 20_260_308), (hav - 1, 20_260_308),
            (hav, 20_260_309), (hav + 30 * minute, 20_260_309), (hav + hour - 1, 20_260_309), (hav + hour, 20_260_309),
        ])
        let havBack: Int64 = 1_793_509_200_000      // 2026-11-01 01:00 -04 -> 00:00 -05
        assertDays("America/Havana", [
            (havBack - hour - 1, 20_261_031), (havBack - hour, 20_261_101), (havBack - 1, 20_261_101),
            (havBack, 20_261_101), (havBack + 12 * hour, 20_261_101), (havBack + 24 * hour - 1, 20_261_101),
            (havBack + 24 * hour, 20_261_102),
        ])
    }

    /// The Santiago fixture through the store: the transition day's noon and
    /// 00:30 of the next day as two keys of ONE file. In either order inside
    /// the batch, whole or whole-then-delta, and after a zone change from
    /// Tokyo, the store must file each key on Foundation's day (the oracle
    /// computes days without the store's cache).
    func testTheStoreFilesTheHourAfterAMidnightDSTStartOnItsOwnDayInEverySchedule() async throws {
        let scl = TimeZone(identifier: "America/Santiago")!
        let noon: Int64 = 1_788_706_800_000          // 2026-09-06 12:00 -03
        let afterMidnight: Int64 = 1_788_751_800_000 // 2026-09-07 00:30 -03
        let p = "/p/proj/s1.jsonl"
        let o1 = hmObs(hmKey(1), [hmPart(output: 1)], .final, first: noon, last: noon, final: noon)
        let o2 = hmObs(hmKey(2), [hmPart(output: 1)], .final, first: afterMidnight, last: afterMidnight, final: afterMidnight)
        let want = HMOracle.dump([HMContribution(path: p, version: hmParserVersion, observations: [o1, o2])], births: [:], timeZone: scl)
        XCTAssertEqual(want.requests.first { $0.keyHex == hmKey(2).historyHex }?.acctDay, 20_260_907)

        let w1 = hmWatermark(id: 9, parsed: 10), w2 = hmWatermark(id: 9, parsed: 20)
        var dumps: [(String, HistoryLogicalDump)] = []
        for (name, scans) in [
            ("whole o1,o2", [hmScan(1, [hmFile(p, scan: 1, watermark: w2, [o1, o2])])]),
            ("whole o2,o1", [hmScan(1, [hmFile(p, scan: 1, watermark: w2, [o2, o1])])]),
            ("whole then delta", [hmScan(1, [hmFile(p, scan: 1, watermark: w1, [o1])]),
                                  hmScan(2, [hmFile(p, scan: 2, watermark: w2, [o1, o2], delta: (w1, [o2]))])]),
        ] {
            let store = hmStore(historyTempDirectory("santiago"), timeZone: scl)
            for scan in scans { try await store.applyScanCommand(scan) }
            dumps.append((name, try await store.logicalDump()))
            await store.close()
        }
        let dir = historyTempDirectory("santiago-switch")
        var store = hmStore(dir, timeZone: hmTokyo)
        try await store.applyScanCommand(hmScan(1, [hmFile(p, scan: 1, watermark: w2, [o2, o1])]))
        await store.close()
        store = hmStore(dir, timeZone: scl)
        try await store.applyScanCommand(hmScan(2, []))      // the first command recomputes every day
        dumps.append(("Tokyo -> Santiago", try await store.logicalDump()))
        await store.close()
        for (name, got) in dumps { XCTAssertEqual(got, want, "\(name): \(hmDiff(got, want))") }
    }

    /// Every known zone, around every offset transition from 2010 through
    /// 2027: walks from `halfWindowMs` before to `halfWindowMs` after it in
    /// ascending order (so each lookup meets the cache the previous one left)
    /// and compares with an uncached Foundation computation. With
    /// `nearMidnightOnly`, only transitions whose wall time on either side is
    /// within an hour of midnight (the ones that move a day boundary).
    /// Returns (instants, wrong instants, the first 20 of them).
    static func transitionSweep(stepMs: Int64, halfWindowMs: Int64, nearMidnightOnly: Bool)
        -> (checked: Int, wrong: Int, mismatches: [String]) {
        let start = Date(timeIntervalSince1970: 1_262_304_000)   // 2010-01-01
        let end = Date(timeIntervalSince1970: 1_830_297_600)     // 2028-01-01
        var checked = 0
        var wrong = 0
        var mismatches: [String] = []
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let tz = TimeZone(identifier: id) else { continue }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            var days = HistoryAccountingDays(timeZone: tz)
            var transitions: [Date] = []
            var t = start
            while let next = tz.nextDaylightSavingTimeTransition(after: t), next < end {
                transitions.append(next)
                t = next
            }
            for p in transitions {
                if nearMidnightOnly {
                    let walls = [tz.secondsFromGMT(for: p.addingTimeInterval(-1)), tz.secondsFromGMT(for: p)].map {
                        ((Int(p.timeIntervalSince1970) + $0) % 86_400 + 86_400) % 86_400
                    }
                    guard walls.contains(where: { $0 <= 3_600 || $0 >= 23 * 3_600 }) else { continue }
                }
                var ms = HistoryTime.ms(p) - halfWindowMs
                let stop = HistoryTime.ms(p) + halfWindowMs
                while ms <= stop {
                    let c = cal.dateComponents([.year, .month, .day], from: HistoryTime.date(ms: ms))
                    let want = Int64(c.year! * 10_000 + c.month! * 100 + c.day!)
                    let got = days.day(ms)
                    checked += 1
                    if got != want {
                        wrong += 1
                        if mismatches.count < 20 { mismatches.append("\(id) \(ms): got \(got.map(String.init) ?? "nil"), want \(want)") }
                    }
                    ms += stepMs
                }
            }
        }
        return (checked, wrong, mismatches)
    }

    /// The fast form of the sweep: the transitions within an hour of a local
    /// midnight, from 26 h before to 26 h after, in 29-minute steps (never a
    /// divisor of the hour, so every hour is probed at shifting minutes).
    /// `AGENTMETER_HISTORY_TZ_SWEEP=1` walks EVERY transition of every zone
    /// from 30 h before to 30 h after in 1-minute steps instead (21.2
    /// million instants, about 30 s).
    func testTheDayCacheEqualsFoundationAroundEveryTransitionNearMidnight() {
        let full = ProcessInfo.processInfo.environment["AGENTMETER_HISTORY_TZ_SWEEP"] == "1"
        let started = Date()
        let (checked, wrong, mismatches) = full
            ? Self.transitionSweep(stepMs: 60_000, halfWindowMs: 30 * 3_600_000, nearMidnightOnly: false)
            : Self.transitionSweep(stepMs: 29 * 60_000, halfWindowMs: 26 * 3_600_000, nearMidnightOnly: true)
        print("[history-days] \(full ? "full" : "near-midnight") sweep: \(checked) instants, \(wrong) wrong, "
              + String(format: "%.2f s", Date().timeIntervalSince(started)))
        XCTAssertGreaterThan(checked, 10_000)
        XCTAssertEqual(mismatches, [])
    }
}
