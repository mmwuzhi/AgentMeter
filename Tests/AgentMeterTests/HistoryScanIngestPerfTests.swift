import Darwin
import Foundation
import XCTest
@testable import AgentMeter

/// A corpus-shaped synthetic backfill (at full size 116,000 observations of
/// 113,600 keys in 2,600 files, 2.1% of keys with a second occurrence, 22%
/// partial winners, a few two-iteration requests), then incremental batches.
/// Prints the numbers. The default run is a 3,000-observation slice of the
/// same shape and asserts only what landed; `AGENTMETER_HISTORY_PERF=1` runs
/// the full size and `AGENTMETER_HISTORY_PERF_SCALE` (0 < x <= 1) any other,
/// and only those also assert the timing gates, which are soft (several
/// times the targets, scaled with the size) so a loaded machine does not
/// fail them.
final class HistoryScanIngestPerfTests: XCTestCase {
    /// `phys_footprint`: what Activity Monitor calls the process's memory.
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    struct Corpus {
        var files: [(path: String, id: UInt64, obs: [RequestObservation])]
        /// Per file, the keys whose standing record there is still partial.
        var partials: [[Int]]
    }

    static func corpus(scale: Double) -> Corpus {
        var rng = HistorySplitMix64(seed: 0xC0FFEE)
        let nFiles = Int(2_600 * scale), nKeys = Int(113_600 * scale), extra = Int(2_400 * scale)
        let start: Int64 = 1_776_000_000_000
        let models = ["claude-opus-4-7", "claude-fable-5", "claude-sonnet-4-6"]
        var paths: [String] = []
        for f in 0..<nFiles {
            switch f % 3 {
            case 0: paths.append("/Users/u/.claude/projects/-proj\(f % 40)/s\(f).jsonl")
            case 1: paths.append("/Users/u/.claude/projects/-proj\(f % 40)/s\(f - 1)/subagents/agent-a\(f).jsonl")
            default: paths.append("/Users/u/.claude/projects/-proj\(f % 40)/s\(f - 2)/subagents/workflows/r\(f)/agent-w\(f).jsonl")
            }
        }
        var perFile = [[RequestObservation]](repeating: [], count: nFiles)
        var partials = [[Int]](repeating: [], count: nFiles)
        var made: [RequestObservation] = []
        made.reserveCapacity(nKeys)
        for k in 0..<nKeys {
            let first = start + Int64(k) * 110_000 + Int64.random(in: 0..<60_000, using: &rng)
            let partial = Int.random(in: 0..<100, using: &rng) < 22
            let home = Int.random(in: 0..<nFiles, using: &rng)
            if partial { partials[home].append(k) }
            var parts = [hmPart(models[k % 3], input: Int.random(in: 1..<2_000, using: &rng),
                                output: Int.random(in: 1..<3_000, using: &rng), cw5m: Int.random(in: 0..<5_000, using: &rng),
                                cacheRead: Int.random(in: 0..<200_000, using: &rng))]
            if k % 250 == 0 { parts.insert(hmPart(models[(k + 1) % 3], output: 188), at: 0) }
            let o = hmObs(hmKey(k), parts, partial ? .partial : .final, first: first,
                          last: first + Int64.random(in: 0..<120_000, using: &rng), final: partial ? nil : first,
                          thinking: k % 7 == 0 ? 100 : nil, cc: "2.1.\(200 + k % 20)", effort: k % 5 == 0 ? "high" : nil,
                          entry: k % 2 == 0 ? "cli" : "sdk-ts")
            made.append(o)
            perFile[home].append(o)
        }
        for _ in 0..<extra {      // fork copies: same record in another file, a later last block
            let o = made[Int.random(in: 0..<nKeys, using: &rng)]
            let copy = hmObs(o.key, o.parts, o.finality, first: o.firstMs, last: (o.lastMs ?? 0) + 30_000, final: o.finalMs,
                             thinking: o.thinkingTokens, cc: "2.1.299", effort: o.effort, entry: o.entrypoint)
            perFile[Int.random(in: 0..<nFiles, using: &rng)].append(copy)
        }
        let files = (0..<nFiles).map { (paths[$0], UInt64(10_000 + $0), perFile[$0]) }
        return Corpus(files: files, partials: partials)
    }

    /// About 3,000 of the full 116,000 observations: 67 files, so each of the
    /// 20 incremental scans below touches 30 distinct files.
    static let defaultScale = 3_000.0 / 116_000.0

    func testCorpusShapedBackfillAndIncrementalBatches() async throws {
        let env = ProcessInfo.processInfo.environment
        let scale = Double(env["AGENTMETER_HISTORY_PERF_SCALE"] ?? "")
            ?? (env["AGENTMETER_HISTORY_PERF"] == "1" ? 1 : Self.defaultScale)
        let timed = env["AGENTMETER_HISTORY_PERF"] == "1" || env["AGENTMETER_HISTORY_PERF_SCALE"] != nil
        let corpus = Self.corpus(scale: scale)
        let dir = historyTempDirectory()
        let store = hmStore(dir)
        if let c = Int(ProcessInfo.processInfo.environment["AGENTMETER_HISTORY_PERF_CHUNK"] ?? "") { await store.setScanChunkSize(c) }
        let observations = corpus.files.reduce(0) { $0 + $1.obs.count }
        let scan = hmScan(1, corpus.files.map { f in
            hmFile(f.path, scan: 1, watermark: hmWatermark(id: f.id, parsed: Int64(f.obs.count)), f.obs)
        }, complete: true)

        // Cold whole ingest, with a concurrent status() measuring the actor hop.
        let footprintBefore = Self.footprint()
        var footprintPeak = footprintBefore
        let started = Date()
        let done = HMClock()
        done.set(.distantPast)
        let backfill = Task {
            try await store.applyScanCommand(scan)
            done.set(.distantFuture)
        }
        var hops: [Double] = []
        while done.get() == .distantPast && Date().timeIntervalSince(started) < 120 {
            let t = Date()
            _ = await store.status()
            hops.append(Date().timeIntervalSince(t) * 1_000)
            footprintPeak = max(footprintPeak, Self.footprint())
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await backfill.value
        let cold = Date().timeIntervalSince(started)
        let stats = try await store.historyStatistics()

        // Incremental: 20 scans of ~500 observations each, as deltas of 30 files on their stored
        // watermark: per file ~10 partial -> final of its own keys, new keys and unchanged duplicates.
        var times: [Double] = []
        var nextKey = 1_000_000
        var incremental = 0
        for round in 0..<20 {
            var files: [HistoryFileBatch] = []
            for i in 0..<30 {
                let n = (round * 30 + i) % corpus.files.count
                let f = corpus.files[n]
                var slice: [RequestObservation] = corpus.partials[n].prefix(10).map { k in
                    hmObs(hmKey(k), [hmPart("claude-opus-4-7", output: 9_999)], .final, first: 1_776_000_000_000,
                          last: 1_776_000_000_000, final: 1_776_000_000_000, cc: "2.1.300")
                }
                while slice.count < 13 {
                    slice.append(hmObs(hmKey(nextKey), [hmPart(output: 5)], .final, first: 1_790_000_000_000,
                                       last: 1_790_000_000_000, final: 1_790_000_000_000, cc: "2.1.300"))
                    nextKey += 1
                }
                slice += f.obs.prefix(4)                     // unchanged: the merge must be a no-op
                incremental += slice.count
                let base = hmWatermark(id: f.id, parsed: Int64(f.obs.count))
                files.append(hmFile(f.path, scan: UInt64(2 + round), watermark: hmWatermark(id: f.id, parsed: base.parsedBytes + 1_000),
                                    f.obs + slice, delta: (base, slice)))
            }
            let t = Date()
            try await store.applyScanCommand(hmScan(UInt64(2 + round), files))
            times.append(Date().timeIntervalSince(t) * 1_000)
        }
        times.sort()
        hops.sort()
        // A small backfill can finish before the first status() call.
        let hopP90 = hops.isEmpty ? 0 : hops[min(hops.count - 1, Int(Double(hops.count) * 0.9))]
        await store.close()
        let dbBytes = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(HistoryDatabase.fileName).path)[.size]
            as? Int) ?? 0

        let line = String(format: """
            [history-perf] scale %.2f: %d observations, %d request rows, %d occurrences, %d files
            [history-perf] cold whole ingest %.2f s (%.1f us/observation), footprint +%.1f MB peak during the backfill, DB %.1f MB (%.0f B/row)
            [history-perf] status() hop during the backfill: max %.1f ms, p90 %.1f ms over %d calls
            [history-perf] incremental scans of %d observations (30 delta files): p50 %.1f ms, p90 %.1f ms, max %.1f ms
            """, scale, observations, stats.rowCounts["request"] ?? 0, stats.rowCounts["request_occurrence"] ?? 0,
            stats.rowCounts["source_file"] ?? 0, cold, cold * 1e6 / Double(max(observations, 1)),
            Double(footprintPeak - footprintBefore) / 1e6,
            Double(dbBytes) / 1e6, Double(dbBytes) / Double(max(stats.rowCounts["request"] ?? 1, 1)),
            hops.last ?? 0, hopP90, hops.count,
            incremental / 20, times[times.count / 2], times[Int(Double(times.count) * 0.9)], times.last ?? 0)
        print(line)
        XCTAssertEqual(stats.rowCounts["source_file"], corpus.files.count)
        // One row per key, two for every 250th (a two-iteration request).
        let keys = Int(113_600 * scale)
        XCTAssertEqual(stats.rowCounts["request"], keys + (keys + 249) / 250)
        guard timed else { return }
        XCTAssertLessThan(cold, 60 * scale + 5, "soft gate: target <= 10 s")
        // Soft: the max is set by autocheckpoint fsync stalls (0.4-2.7 s under
        // disk load), not by the transaction size; p90 is.
        XCTAssertLessThan(hopP90, 250, "soft gate: target p90 <= ~50 ms")
    }
}
