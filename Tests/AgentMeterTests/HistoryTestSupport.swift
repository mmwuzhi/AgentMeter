import Foundation
import os
import SQLite3
import XCTest
@testable import AgentMeter

// Shared helpers of the history test suites. Every database lives in a fresh
// directory under the system temp dir (never in Application Support) and is
// removed when the test ends, so a test can never touch the user's real
// `history.sqlite`.

extension XCTestCase {
    /// A new empty directory, deleted (permissions restored first) at tear-down.
    /// `resolvingSymlinksInPath` because `/var` is a link to `/private/var`.
    func historyTempDirectory(_ name: String = #function) -> URL {
        let safe = name.replacingOccurrences(of: "()", with: "")
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("history-\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

func historyConfig(_ dir: URL, file: String = HistoryDatabase.fileName) -> HistoryDatabaseConfiguration {
    HistoryDatabaseConfiguration(url: dir.appendingPathComponent(file))
}

/// Deterministic PRNG so a failing run can be replayed from its seed.
struct HistorySplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func historyFileBytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

func historyQuarantined(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".corrupt-") }.sorted()
}

/// Fills `dict` (a table with a UNIQUE index, so it spans many pages) with
/// `rows` random labels, in transactions of 2,000 rows (plain rows, not scan
/// observations). About 100 pages per 5,000 rows.
func historyPopulate(_ db: HistoryDatabase, rows: Int, seed: UInt64 = 1) throws {
    var rng = HistorySplitMix64(seed: seed)
    var done = 0
    while done < rows {
        let n = min(2_000, rows - done)
        try db.conn.transaction(.immediate) {
            try db.conn.withStatement("INSERT INTO dict(kind, value) VALUES (?1, ?2)") { s in
                for _ in 0..<n {
                    s.bind(1, 1)
                    s.bind(2, String(rng.next(), radix: 16) + String(rng.next(), radix: 16))
                    try s.step()
                    s.rewind()
                }
            }
        }
        done += n
    }
}

func historyDictCount(_ db: HistoryDatabase) throws -> Int {
    Int(try db.conn.queryInt("SELECT count(*) FROM dict") ?? -1)
}

/// A one-shot async latch: `wait()` suspends until `open()`.
actor HistoryAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

/// An append-only log that any isolation domain may write.
final class HistoryOrderLog: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// The store's `retryClock`, advanced by hand: a latch expires when the test
/// says so, never because a loaded machine was slow.
final class HistoryRetryClock: Sendable {
    private let base = ContinuousClock.now
    private let offset = OSAllocatedUnfairLock<Duration>(initialState: .zero)
    func now() -> ContinuousClock.Instant { base + offset.withLock { $0 } }
    func advance(_ by: Duration) { offset.withLock { $0 += by } }
}

/// A settable zone for the store's `timeZoneSource`: the system zone changing
/// while the app runs.
final class HistoryZoneBox: Sendable {
    private let zone: OSAllocatedUnfairLock<TimeZone>
    init(_ initial: TimeZone) { zone = OSAllocatedUnfairLock(initialState: initial) }
    func get() -> TimeZone { zone.withLock { $0 } }
    func set(_ new: TimeZone) { zone.withLock { $0 = new } }
}

func historyWalBytes(_ dir: URL) -> Int {
    let path = dir.appendingPathComponent(HistoryDatabase.fileName).path + "-wal"
    return ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil) ?? 0
}
