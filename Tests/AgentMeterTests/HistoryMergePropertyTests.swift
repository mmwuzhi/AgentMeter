import Foundation
import XCTest
@testable import AgentMeter

/// Order independence on the real store: random transcripts with tiny value
/// ranges (so every tie happens), plus fork-copied events (same request id /
/// time / payload, another uuid, session, file and birth) and in-place
/// rewrites (the same records with other labels), ingested under several
/// schedules (permutation, prefix snapshots as whole or delta batches with
/// missed batches, duplicate and stale re-imports, a restart, chunk sizes
/// 1..2000, a parser-version bump) must all give the logical dump of the
/// closed form.
/// Then each of the five merge mechanisms, and the owner rule of events, is
/// switched off and the default run (same seed, same trial count) must FAIL.
final class HistoryMergePropertyTests: XCTestCase {
    struct Trial {
        var paths: [String]
        var births: [String: Int64]
        var records: [String: [HMRecord]]
        /// Re-ingested under parser version 2 at the end of every schedule.
        var v2: [String]
        var events: [HMEventCopy] = []
        /// A second content of the path, rewritten in place: the same records
        /// with other version / effort / entrypoint labels (and, for some, one
        /// more input token), so each key's standing record ties with the
        /// original on (version, finality, output). Union semantics keep both.
        var rewrites: [String: [HMRecord]] = [:]
    }

    enum Step {
        case scan(HistoryScanBatch)
        case restart
    }

    /// Times are tiny offsets around a Tokyo midnight, so finals cross it.
    static let base = hmMidnight(hmTokyo, 2026, 9, 20) - 3

    static func makeTrial(_ rng: inout HistorySplitMix64) -> Trial {
        let nfiles = Int.random(in: 1...4, using: &rng)
        let nkeys = Int.random(in: 1...2, using: &rng)
        var templates: [[HMRecord]] = []
        for k in 0..<nkeys {
            var list: [HMRecord] = []
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let fin: UsageFinality = [.zeroed, .partial, .partial, .final, .final].randomElement(using: &rng)!
                let model = ["m1", "m2"].randomElement(using: &rng)!
                var parts = [hmPart(model, input: 0, output: 0)]
                if fin != .zeroed {
                    parts = (0..<[1, 1, 2].randomElement(using: &rng)!).map { _ in
                        hmPart(["m1", "m2"].randomElement(using: &rng)!, input: 1, output: Int.random(in: 0...2, using: &rng),
                               cw5m: Int.random(in: 0...1, using: &rng), cacheRead: Int.random(in: 0...1, using: &rng))
                    }
                }
                let flags: RequestFlags = [[], [], .fast, .abortedMidStream].randomElement(using: &rng)!
                list.append(HMRecord(key: hmKey(k), finality: fin, parts: parts,
                                     thinking: [nil, 1].randomElement(using: &rng)!,
                                     version: ["a", "b"].randomElement(using: &rng)!,
                                     effort: [nil, "high"].randomElement(using: &rng)!,
                                     entrypoint: [nil, "cli"].randomElement(using: &rng)!, flags: flags, ts: nil))
            }
            templates.append(list)
        }
        var trial = Trial(paths: [], births: [:], records: [:], v2: [])
        for f in 0..<nfiles {
            let path: String
            switch f == 0 ? 0 : Int.random(in: 0...2, using: &rng) {
            case 0: path = "/p/proj/s\(f).jsonl"
            case 1: path = "/p/proj/s0/subagents/agent-a\(f).jsonl"
            default: path = "/p/proj/s0/subagents/workflows/r1/agent-w\(f).jsonl"
            }
            trial.paths.append(path)
            if let b = [nil, 1, 1, 2].randomElement(using: &rng)! { trial.births[path] = base + Int64(b) }
            trial.records[path] = (0..<Int.random(in: 1...6, using: &rng)).map { _ in
                var r = templates[Int.random(in: 0..<nkeys, using: &rng)].randomElement(using: &rng)!
                r.ts = [nil, 0, 1, 2, 3, 4, 5].randomElement(using: &rng)!.map { base + Int64($0) }
                return r
            }
        }
        if Int.random(in: 0..<10, using: &rng) < 3 {
            trial.v2 = trial.paths.filter { _ in Bool.random(using: &rng) }
        }
        if Bool.random(using: &rng) {
            trial.events = HMEvents.make(&rng, paths: trial.paths,
                                         sessions: trial.paths.map { HistorySourceFile.parse(path: $0).sessionID },
                                         counts: trial.records.mapValues(\.count), base: base)
        }
        if Int.random(in: 0..<10, using: &rng) < 3 {
            for p in trial.paths where Bool.random(using: &rng) {
                let flips = (0..<4).map { _ in Bool.random(using: &rng) }
                trial.rewrites[p] = trial.records[p]!.map { r in
                    var r = r
                    if flips[0] || !(flips[1] || flips[2]) { r.version = r.version == "a" ? "b" : "a" }
                    if flips[1] { r.effort = r.effort == nil ? "high" : nil }
                    if flips[2] { r.entrypoint = r.entrypoint == nil ? "cli" : nil }
                    if flips[3], r.finality != .zeroed {
                        r.parts = r.parts.map { var q = $0; q.counts.input += 1; return q }
                    }
                    return r
                }
            }
        }
        return trial
    }

    static func fold(_ records: [HMRecord]) -> [RequestObservation] {
        var fold = HMFold()
        for r in records { fold.add(r) }
        return fold.observations
    }

    /// Prefix snapshots of one file's fold at random cut points (the last is the whole file).
    static func snapshots(_ recs: [HMRecord], _ rng: inout HistorySplitMix64) -> [(cut: Int, obs: [RequestObservation])] {
        let n = recs.count
        var cuts = n > 1 ? Array((1..<n).shuffled(using: &rng).prefix(min(Int.random(in: 0...3, using: &rng), n - 1))) : []
        cuts.sort()
        cuts.append(n)
        var fold = HMFold()
        var out: [(Int, [RequestObservation])] = []
        var i = 0
        for c in cuts {
            for r in recs[i..<c] { fold.add(r) }
            i = c
            out.append((c, fold.observations))
        }
        return out
    }

    static func expected(_ t: Trial) -> HistoryLogicalDump {
        var contributions: [HMContribution] = []
        for p in t.paths {
            let observations = fold(t.records[p]!)
            contributions.append(HMContribution(path: p, version: 1, observations: observations))
            if t.v2.contains(p) { contributions.append(HMContribution(path: p, version: 2, observations: observations)) }
            if let rewrite = t.rewrites[p] {
                contributions.append(HMContribution(path: p, version: 1, observations: fold(rewrite)))
            }
        }
        var dump = HMOracle.dump(contributions, births: t.births, timeZone: hmTokyo)
        dump.events = HMEvents.lines(t.events, births: t.births)
        return dump
    }

    /// The closed form ranks attributes with `HistoryAttributeSignature`
    /// itself, so it cannot tell a wrong `att_sig` from a right one. This
    /// check does not use it: when the owner file holds an observation with
    /// the row's (ingest_version, finality, rec_sig), the row's labels are
    /// those of such an observation, never another content's.
    static func labelsFollowTheRowsContent(_ t: Trial, _ want: HistoryLogicalDump) -> String? {
        var byPath: [String: [(v: Int64, o: RequestObservation)]] = [:]
        for p in t.paths {
            let obs = fold(t.records[p]!)
            byPath[p, default: []] += obs.map { (Int64(1), $0) }
            if t.v2.contains(p) { byPath[p]! += obs.map { (Int64(2), $0) } }
            if let rewrite = t.rewrites[p] { byPath[p]! += fold(rewrite).map { (Int64(1), $0) } }
        }
        for row in want.requests where row.idx == 0 {
            let same = (byPath[row.ownerPath] ?? []).filter {
                $0.o.key.historyHex == row.keyHex && $0.v == row.ingestVersion
                    && Int64($0.o.finality.rawValue) == row.finality && HistoryRecordSignature.compute($0.o) == row.recSig
            }
            if !same.isEmpty, !same.contains(where: {
                $0.o.ccVersion == row.ccVersion && $0.o.effort == row.effort && $0.o.entrypoint == row.entrypoint
            }) {
                return "key \(row.keyHex): the row's labels are another content's than its counts"
            }
        }
        return nil
    }

    /// One file batch, not yet assigned to a scan.
    struct Entry {
        var path: String
        var watermark: HistoryFileWatermark
        var observations: [RequestObservation]
        var delta: (base: HistoryFileWatermark, requests: [RequestObservation])?
        var stale = false
        var events = HistoryFileEvents.empty
    }

    static func schedules(_ t: Trial, _ rng: inout HistorySplitMix64) -> [(name: String, steps: [Step], chunk: Int)] {
        let ids = Dictionary(uniqueKeysWithValues: t.paths.enumerated().map { ($1, UInt64(100 + $0)) })
        var fresh: UInt64 = 10_000
        var out: [(String, [Step], Int)] = []
        func finalEntries(_ version: Int, _ paths: [String]) -> [Entry] {
            paths.map { p in
                let n = t.records[p]!.count
                return Entry(path: p, watermark: hmWatermark(id: ids[p], parsed: Int64(n), version: version),
                             observations: fold(t.records[p]!), events: HMEvents.events(t.events, path: p, cut: n))
            }
        }
        /// The rewrites, each as a whole batch under a new identity (the
        /// content changed, so the stored watermark never equals it), placed
        /// at random positions of `entries`.
        func withRewrites(_ entries: [Entry], _ rng: inout HistorySplitMix64) -> [Entry] {
            var out = entries
            for p in t.paths {
                guard let rewrite = t.rewrites[p] else { continue }
                fresh += 1
                out.insert(Entry(path: p, watermark: hmWatermark(id: fresh, parsed: Int64(rewrite.count), version: 1),
                                 observations: fold(rewrite)), at: Int.random(in: 0...out.count, using: &rng))
            }
            return out
        }
        func steps(_ entries: [Entry], restartAt: Int?, _ rng: inout HistorySplitMix64) -> [Step] {
            var steps: [Step] = []
            var ticket: UInt64 = 0
            var i = 0
            while i < entries.count {
                let size = min(Int.random(in: 1...3, using: &rng), entries.count - i)
                ticket += 1
                let files = entries[i..<(i + size)].map { e in
                    hmFile(e.path, scan: e.stale ? 0 : ticket, watermark: e.watermark, e.observations, delta: e.delta,
                           events: e.events)
                }
                steps.append(.scan(hmScan(ticket, files, complete: Bool.random(using: &rng))))
                i += size
            }
            if let r = restartAt { steps.insert(.restart, at: min(r, steps.count)) }
            return steps
        }
        let chunkSizes = [1, 2, 3, 2_000]

        // 1. Permutation of the whole contributions.
        var perm = withRewrites(finalEntries(1, t.paths.shuffled(using: &rng)), &rng)
        perm += finalEntries(2, t.v2)
        out.append(("perm", steps(perm, restartAt: nil, &rng), chunkSizes.randomElement(using: &rng)!))

        // 2-4. Prefix snapshots, whole or delta, missed batches, duplicates, stale re-imports, a restart.
        let restartSchedule = Int.random(in: 0..<3, using: &rng)
        for n in 0..<3 {
            var snaps: [String: [(cut: Int, obs: [RequestObservation])]] = [:]
            for p in t.paths { snaps[p] = snapshots(t.records[p]!, &rng) }
            var next = Dictionary(uniqueKeysWithValues: t.paths.map { ($0, 0) })
            var pending = t.paths
            var entries: [Entry] = []
            while !pending.isEmpty {
                let p = pending.randomElement(using: &rng)!
                let list = snaps[p]!
                let j = next[p]!
                next[p] = j + 1
                if j + 1 >= list.count { pending.removeAll { $0 == p } }
                if j < list.count - 1 && Int.random(in: 0..<4, using: &rng) == 0 { continue }      // missed batch
                let wm = hmWatermark(id: ids[p], parsed: Int64(list[j].cut), version: 1)
                var delta: (HistoryFileWatermark, [RequestObservation])?
                if j > 0 && Bool.random(using: &rng) {
                    let before = Dictionary(uniqueKeysWithValues: list[j - 1].obs.map { ($0.key, $0) })
                    delta = (hmWatermark(id: ids[p], parsed: Int64(list[j - 1].cut), version: 1),
                             list[j].obs.filter { before[$0.key] != $0 })
                }
                entries.append(Entry(path: p, watermark: wm, observations: list[j].obs, delta: delta,
                                     events: HMEvents.events(t.events, path: p, cut: list[j].cut)))
                if Int.random(in: 0..<10, using: &rng) < 3 {
                    // A duplicate or stale re-import of some snapshot: as a replaced file
                    // (new identity, applied whole) or as an older scan (skipped or dominated).
                    let q = t.paths.randomElement(using: &rng)!
                    let s = snaps[q]!.randomElement(using: &rng)!
                    let stale = Bool.random(using: &rng)
                    fresh += 1
                    entries.append(Entry(path: q, watermark: hmWatermark(id: stale ? ids[q] : fresh, parsed: Int64(s.cut), version: 1),
                                         observations: s.obs, delta: nil, stale: stale,
                                         events: HMEvents.events(t.events, path: q, cut: s.cut)))
                }
            }
            entries = withRewrites(entries, &rng)
            entries += finalEntries(2, t.v2)
            // One of the three chunked schedules restarts the store (a reopen costs
            // more than the rest of a schedule; one per trial covers every position).
            let restart = n == restartSchedule ? Int.random(in: 0...entries.count, using: &rng) : nil
            out.append(("chunk\(n)", steps(entries, restartAt: restart, &rng), chunkSizes.randomElement(using: &rng)!))
        }
        return out
    }

    /// Runs schedules against one store directory, wiping it between them.
    final class Runner {
        let dir: URL
        let births = HMBirths()
        let mutations: HistoryMergeMutations
        var store: HistoryStore

        init(dir: URL, mutations: HistoryMergeMutations) {
            self.dir = dir
            self.mutations = mutations
            store = hmStore(dir, births: births) { $0.mergeMutations = mutations }
        }

        func run(_ steps: [Step], chunk: Int) async throws -> HistoryLogicalDump {
            try await store.withDatabase { try hmWipe($0); try hmNoSync($0) }
            await store.resetIngestMemory()
            await store.setScanChunkSize(chunk)
            for step in steps {
                switch step {
                case let .scan(scan):
                    try await store.applyScanCommand(scan)
                case .restart:
                    await store.close()
                    let m = mutations
                    store = hmStore(dir, births: births) { $0.mergeMutations = m }
                    try await store.withDatabase { try hmNoSync($0) }
                    await store.setScanChunkSize(chunk)
                }
            }
            return try await store.logicalDump()
        }
    }

    /// Returns the failures (seed, schedule, first difference); stops at the first when `stopEarly`.
    func runTrials(_ count: Int, seed: UInt64, mutations: HistoryMergeMutations = [], stopEarly: Bool = false) async throws
        -> [String] {
        let runner = Runner(dir: historyTempDirectory("prop-\(seed)-\(mutations.rawValue)"), mutations: mutations)
        var failures: [String] = []
        for n in 0..<count {
            var rng = HistorySplitMix64(seed: seed &+ UInt64(n) &* 0x9E37_79B9)
            let trial = Self.makeTrial(&rng)
            runner.births.set(trial.births)
            let want = Self.expected(trial)
            if let broken = Self.labelsFollowTheRowsContent(trial, want) {
                failures.append("trial \(n) closed form: \(broken)")
                if stopEarly { break }
                continue
            }
            for (name, steps, chunk) in Self.schedules(trial, &rng) {
                let got = try await runner.run(steps, chunk: chunk)
                if got != want {
                    failures.append("trial \(n) schedule \(name) chunk \(chunk): \(hmDiff(got, want))")
                    break
                }
            }
            if stopEarly && !failures.isEmpty { break }
        }
        await runner.store.close()
        return failures
    }

    /// 200 trials by default, so the suite stays fast: every switched-off
    /// mechanism fails within the first 13 trials of this seed (and within 87
    /// of the next two seeds), and `testEachMergeMechanismIsLoadBearing` keeps
    /// that true. Set `AGENTMETER_HISTORY_PROP_TRIALS` (2,000 at least for a
    /// merge change, 20,000 before a release) for the full run.
    static let defaultTrials = 200
    static let defaultSeed: UInt64 = 0xA2

    func testEveryScheduleGivesTheClosedForm() async throws {
        let trials = Int(ProcessInfo.processInfo.environment["AGENTMETER_HISTORY_PROP_TRIALS"] ?? "") ?? Self.defaultTrials
        let started = Date()
        let failures = try await runTrials(trials, seed: Self.defaultSeed)
        print("[history-prop] \(trials) trials x 4 schedules, failures \(failures.count), "
              + String(format: "%.1f s", Date().timeIntervalSince(started)))
        XCTAssertEqual(failures.count, 0, failures.prefix(3).joined(separator: "\n"))
    }

    /// Each mechanism is load-bearing: with it switched off, the default run of
    /// the property test (its seed and trial count) finds a counter-example
    /// (cheap: stops at the first one).
    func testEachMergeMechanismIsLoadBearing() async throws {
        for (name, mutation) in [("stale cleanup", HistoryMergeMutations.noStaleCleanup),
                                 ("rec_sig tie-break", .noRecSigTieBreak),
                                 ("final_ms tie-break", .noFinalMsTieBreak),
                                 ("per-row derived UPDATE", .keyLevelDerivedSkip),
                                 ("event owner rule", .firstArrivalEvents),
                                 ("att_sig tie-break", .noAttSigTieBreak)] {
            let failures = try await runTrials(Self.defaultTrials, seed: Self.defaultSeed, mutations: mutation,
                                               stopEarly: true)
            XCTAssertFalse(failures.isEmpty, "without the \(name) the property test must fail")
            if let first = failures.first { print("[history-prop] without \(name): \(first.prefix(160))") }
        }
    }
}
