import CryptoKit
import Foundation

// MARK: - What one log file contributes

/// A record's `message.id|requestId`, as 128 bits: the first 16 bytes of
/// SHA-256 over that string. Persisted and compared across files, so it has
/// to be the same on every launch — Swift's `hashValue` is seeded per process
/// and is not. At 10^6 records the chance of any two keys colliding is about
/// 10^-27; a collision would drop one record from the totals, nothing more.
struct DedupKey: Hashable, Sendable {
    let hi: UInt64
    let lo: UInt64

    init(hi: UInt64, lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    init(messageID: String, requestID: String) {
        var hasher = SHA256()
        var mid = messageID
        var rid = requestID
        mid.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        withUnsafeBytes(of: UInt8(ascii: "|")) { hasher.update(bufferPointer: $0) }
        rid.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        let digest = hasher.finalize()
        let (hi, lo) = digest.withUnsafeBytes { raw in
            (UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
             UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        }
        self.init(hi: hi, lo: lo)
    }
}

/// How far one record's usage can be trusted, in the order the dedup prefers
/// records. Claude Code writes one assistant record per content block, and
/// the records of one request do not all carry the same usage.
enum UsageFinality: UInt8, Sendable, Comparable {
    /// Every top-level count is zero: a replay of the request appended later
    /// (often by a newer Claude Code), whose original record carries the
    /// counts. Contributes nothing.
    case zeroed = 0
    /// No `stop_reason`: written while the request was still streaming. Its
    /// input and cache counts are already the request's, but its output is
    /// only what had streamed by then — in subagent and workflow transcripts
    /// the `message_start` figure of a few tokens. A lower bound.
    case partial = 1
    /// Has a `stop_reason`: the record that closed the request. Final usage.
    case final = 2

    static func < (lhs: UsageFinality, rhs: UsageFinality) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Times, attributes and flags of the records of one key in one file, kept
/// beside the record that stands for the key. Times are absolute Unix ms
/// (UTC), `noTime` for "not stated": a u32 offset from the first time cannot
/// hold a span over 49.7 days, and a stated time read back as unstated lets
/// the history keep whatever an earlier, shorter parse of the file stated,
/// so the rows would depend on when the file was scanned. Every field is
/// exactly what the AMCU codec writes: nothing is clamped at encode time, so
/// decode(encode(x)) == x and a resumed parse continues from the same state
/// a parse from the top reaches. Limits are applied when a record is parsed.
struct RecordStamp: Sendable, Equatable {
    /// `Int64.min`, so a MAX over raw values already treats it as "not stated".
    static let noTime = Int64.min
    static let noThinking = UInt32.max

    /// MIN timestamp over every record of the key in the file, zeroed replays
    /// and records that did not count included.
    var firstMs: Int64 = RecordStamp.noTime
    /// MAX timestamp over the key's non-zeroed records.
    var latestMs: Int64 = RecordStamp.noTime
    /// The standing record's own timestamp; final records only.
    var ownFinalMs: Int64 = RecordStamp.noTime
    /// `usage.output_tokens_details.thinking_tokens` of the standing record.
    var thinking: UInt32 = RecordStamp.noThinking
    /// 1-based index into `ClaudeFileUsage.attributeSets` (the standing
    /// record's version, effort, entrypoint); 0 = none.
    var attributes: UInt16 = 0
    /// OR over every record of the key in the file (monotone, so never ranked
    /// and never order-dependent).
    var flags: RequestFlags = []

    /// One record's own times and flags, before any fold.
    static func of(ms: Int64?, finality: UsageFinality, flags: RequestFlags = []) -> RecordStamp {
        var stamp = RecordStamp()
        stamp.flags = flags
        guard let ms else { return stamp }
        stamp.firstMs = ms
        if finality != .zeroed { stamp.latestMs = ms }
        if finality == .final { stamp.ownFinalMs = ms }
        return stamp
    }

    var first: Int64? { firstMs == Self.noTime ? nil : firstMs }
    var lastMs: Int64? { latestMs == Self.noTime ? nil : latestMs }
    var finalMs: Int64? { ownFinalMs == Self.noTime ? nil : ownFinalMs }

    /// Folds another record of the same key into this one: first = MIN,
    /// last = MAX, flags OR; this record's own final time, attributes and
    /// thinking stay. Commutative and associative on times and flags.
    mutating func absorb(_ other: RecordStamp) {
        flags.formUnion(other.flags)
        guard other.firstMs != Self.noTime else { return }
        guard firstMs != Self.noTime else {
            // This record stated no time, so it has no final time of its own.
            firstMs = other.firstMs
            latestMs = other.latestMs
            ownFinalMs = Self.noTime
            return
        }
        firstMs = min(firstMs, other.firstMs)
        latestMs = max(latestMs, other.latestMs)
    }
}

/// (version, effort, entrypoint) of a standing record, interned per file in
/// `ClaudeFileUsage.attributeSets`. Each is a validated label (1–64
/// printable ASCII bytes) or nil.
struct RecordAttributes: Sendable, Hashable {
    var version: String?
    var effort: String?
    var entrypoint: String?
}

/// One deduplicated usage record of a file: the one record that stands for
/// its key, never a mix of fields from several — except `stamp`, which folds
/// the times and flags of every record of the key in the file.
///
/// `==` is exact within one file's parse lineage only: `stamp.attributes` is
/// an index into that file's own `attributeSets`, which only ever grows.
struct KeyedUsage: Sendable, Equatable {
    let key: DedupKey
    /// The record's usage — for a request that ran several iterations
    /// (`usage.iterations`, a Fable attempt followed by its fallback model)
    /// the last iteration's, which is all the top level repeats.
    private(set) var usage: DayModelUsage
    /// The iterations before the last, each under its own model. Empty for
    /// an ordinary request.
    var earlierIterations: [DayModelUsage] = []
    /// Declared before `finality`, which then fills the stamp's last padding
    /// byte: the struct's stride is 120 this way, 128 the other
    /// (`ClaudeUsageStampTests.testKeyedUsageStrideIsPinned`).
    var stamp = RecordStamp()
    var finality: UsageFinality = .final

    init(key: DedupKey, usage: DayModelUsage, earlierIterations: [DayModelUsage] = [],
         finality: UsageFinality = .final, stamp: RecordStamp = RecordStamp()) {
        self.key = key
        self.usage = usage
        self.earlierIterations = earlierIterations
        self.stamp = stamp
        self.finality = finality
    }

    var outputTokens: Int {
        earlierIterations.reduce(usage.counts.output) { $0 + $1.counts.output }
    }

    /// Whether this record should stand for its key instead of `held`, the
    /// one kept so far: a final record beats a partial one, which beats a
    /// zeroed replay; of two partial records the one that streamed further
    /// wins. Anything else keeps `held`, so the earlier of two equals stays
    /// and a whole-file parse, a resumed one and a cross-file merge in path
    /// order all settle on the same record.
    func outranks(_ held: KeyedUsage) -> Bool {
        if finality != held.finality { return finality > held.finality }
        return finality == .partial && outputTokens > held.outputTokens
    }

    /// The same record filed under `day`: the request keeps the day it was
    /// first counted on when a later record of it — its final one, written
    /// after midnight — takes its place. Moving it would leave the spend
    /// ledger's old day holding it too, since a windowed scan cannot lower a
    /// day there.
    func filed(on day: Date) -> KeyedUsage {
        guard usage.day != day else { return self }
        var copy = self
        copy.usage = DayModelUsage(day: day, model: usage.model, counts: usage.counts)
        copy.earlierIterations = earlierIterations.map { DayModelUsage(day: day, model: $0.model, counts: $0.counts) }
        return copy
    }

    /// `self` in place of `held`, filed under the day `held` was counted on
    /// — unless `held` was a zeroed replay, which counted nothing and was
    /// written later than the request. The times and flags of both are
    /// folded: a final record written after midnight must not lose the
    /// streaming record's earlier first time.
    func replacing(_ held: KeyedUsage) -> KeyedUsage {
        var result = held.finality == .zeroed ? self : filed(on: held.usage.day)
        result.stamp.absorb(held.stamp)
        return result
    }

    /// Every iteration's usage, the earlier ones first.
    func forEachPart(_ body: (DayModelUsage) -> Void) {
        for part in earlierIterations { body(part) }
        body(usage)
    }
}

/// How the requests behind a day's counts ended up in the transcripts. Only
/// `final` requests are exact; the output a `partial` request had left to
/// stream is in no transcript at all and cannot be recovered from them.
struct RequestFinalityCounts: Sendable, Equatable {
    /// Counted from the record that closed the request.
    var final = 0
    /// No closing record anywhere: input and cache counts are exact, output
    /// is a lower bound.
    var partial = 0
    /// Seen only as zeroed replays: nothing about the request is countable.
    var zeroed = 0
    /// The output counted for `partial` requests — all of it a lower bound.
    var partialOutput = 0

    var requests: Int { final + partial + zeroed }

    mutating func count(_ record: KeyedUsage) {
        switch record.finality {
        case .final: final += 1
        case .partial:
            partial += 1
            partialOutput += record.outputTokens
        case .zeroed: zeroed += 1
        }
    }

    mutating func add(_ other: RequestFinalityCounts) {
        final += other.final
        partial += other.partial
        zeroed += other.zeroed
        partialOutput += other.partialOutput
    }
}

/// What one log file contributes to the usage report, up to a line boundary:
/// the statistics behind every record that carries usage, and nothing of the
/// conversation itself.
struct ClaudeFileUsage: Sendable, Equatable {
    /// One entry per key, at the position of its first occurrence, holding
    /// the record that outranks every other of that key in the file
    /// (`KeyedUsage.outranks`). Kept per record rather than pre-aggregated so
    /// `ClaudeJSONLScanner.usageReport(files:)` can pick one record per key
    /// across files: resuming or forking a session copies the earlier
    /// transcript into a new file, so the same assistant message appears in
    /// both.
    var keyed: [KeyedUsage]
    /// Records with no `message.id`, which cannot be deduplicated at all;
    /// summed per (day, model).
    var unkeyed: [DayModelUsage]
    /// Digest of the bytes right before the parsed boundary
    /// (`ClaudeUsageCacheStore.boundaryDigest`). A resume checks the file
    /// still ends that way before trusting that what came before the
    /// boundary is what was parsed.
    var boundaryDigest: Data
    /// The (version, effort, entrypoint) triples `KeyedUsage.stamp.attributes`
    /// points into. Append-only within one parse lineage, never compacted.
    var attributeSets: [RecordAttributes] = []
    /// What the global scan reads besides usage (`ParseState.collectsExtras`):
    /// limit events, `/usage` reports, cost states, compactions, and the
    /// file's first cwd / entrypoint / version. Empty on the session path.
    var extras: HistoryFileEvents = .empty
    /// Running MAX timestamp over the usage records parsed so far (the
    /// `afterTsMs` of a cost state read next); `RecordStamp.noTime` if none.
    var usageHighWaterMs: Int64 = RecordStamp.noTime

    static let empty = ClaudeFileUsage(keyed: [], unkeyed: [],
                                       boundaryDigest: ClaudeUsageCacheStore.boundaryDigest(of: Data()))

    /// The file's counts per model, each key once.
    func countsByModel() -> [String: TokenCounts] {
        var totals: [String: TokenCounts] = [:]
        for record in keyed where record.finality != .zeroed {
            record.forEachPart { totals[$0.model, default: TokenCounts()].add($0.counts) }
        }
        for usage in unkeyed { totals[usage.model, default: TokenCounts()].add(usage.counts) }
        return totals
    }
}

// MARK: - The caches one scan parses through

/// The caches a Claude usage scan reads through: the in-memory
/// `LogFileParseCache` every scan consults first, and — for the app — a
/// `ClaudeUsageCacheStore` on disk that outlives the process. Tests build
/// their own over a temporary directory; `memoryOnly` is the default for
/// `usageReport(files:)` callers and persists nothing.
final class ClaudeUsageCache: Sendable {
    let memory = LogFileParseCache<ClaudeFileUsage>()
    let store: ClaudeUsageCacheStore?
    let stats = ClaudeScanStats()

    init(store: ClaudeUsageCacheStore?) {
        self.store = store
    }

    /// The app's cache, persisted under Application Support.
    static let shared = ClaudeUsageCache(
        store: ClaudeUsageCacheStore(directory: ClaudeUsageCacheStore.defaultDirectory,
                                     legacyDirectories: ClaudeUsageCacheStore.legacyDirectories))

    /// No store: what every scan went through before the store existed.
    static let memoryOnly = ClaudeUsageCache(store: nil)
}

/// Counts what a scan did, so a test can prove an unchanged file was never
/// opened and an appended one was read only from its old end.
actor ClaudeScanStats {
    struct Snapshot: Sendable, Equatable {
        var memoryHits = 0
        var storeHits = 0
        var fullParses = 0
        var resumedParses = 0
        /// Log files opened to parse (not the small boundary reads).
        var filesOpened = 0
        /// Newline-terminated bytes parsed and committed to the cache.
        var bytesCommitted: Int64 = 0
    }

    private var current = Snapshot()

    func memoryHit() { current.memoryHits += 1 }
    func storeHit() { current.storeHits += 1 }
    func opened() { current.filesOpened += 1 }

    func parsed(resumed: Bool, bytes: Int64) {
        if resumed { current.resumedParses += 1 } else { current.fullParses += 1 }
        current.bytesCommitted += bytes
    }

    func snapshot() -> Snapshot { current }
    func reset() { current = Snapshot() }
}

// MARK: - The store on disk

/// Persists `ClaudeFileUsage` per log file so a launch, and the complete
/// scan every `ClaudeJSONLScanner.fullHistoryInterval`, re-read only the
/// files that changed. One entry file per log file, named by a digest of the
/// log's path, written whole and atomically (temp file + `rename`), with a
/// SHA-256 trailer: a torn or corrupt entry fails the checksum, is deleted
/// and the log is parsed again. The cache is never the only source of a
/// figure — an entry is used only while the log's fingerprint still matches
/// it exactly, or as the head of a resume after the boundary check.
actor ClaudeUsageCacheStore {
    /// Bump when the layout below or what `ClaudeJSONLScanner.consume` puts
    /// in a `ClaudeFileUsage` changes; entries of another version are
    /// discarded on read.
    ///
    /// 2: a record per key is the final one rather than the first (version 1
    /// entries hold the streaming `message_start` usage of many subagent and
    /// workflow requests), and records carry their finality and earlier
    /// iterations. A version 1 build reading a version 2 entry discards it
    /// the same way and parses that log again.
    ///
    /// 3: every keyed record carries a `RecordStamp` (first / last / final
    /// time, thinking tokens, attribute set, flags), and the file its
    /// attribute sets and the extras the history reads (limit events,
    /// `/usage` reports, cost states, compactions, first cwd). The codec is
    /// lossless: what does not fit is dropped or marked when a record is
    /// parsed, never when it is encoded.
    ///
    /// 4: the stamp's last and final times are absolute i64 instead of u32
    /// offsets from the first time, which a span over 49.7 days could not
    /// hold (the time was then read as not stated), and the boundary digest
    /// keeps `boundaryDigestLength` bytes. A version 3 entry is discarded and
    /// its log parsed again; as the history's
    /// `HistoryFileWatermark.parserVersion`, the bump also makes the history
    /// re-ingest every file a version 3 parse fed it.
    static let formatVersion: UInt32 = 4
    /// The format whose name the entry directory carries. Version 4 replaced
    /// version 3 before any release wrote version 3, so it kept that
    /// directory: what a development build of version 3 left there fails
    /// the version check, is deleted and parsed again.
    static let directoryFormat: UInt32 = 3
    static let magic: [UInt8] = Array("AMCU".utf8)
    /// How many bytes before the parsed boundary `boundaryDigest` covers.
    static let boundarySampleLength = 4096

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
    }

    /// One directory per released format. A build of another format — the
    /// installed app beside a newer local build, which `make run` leaves
    /// running — deletes every entry it cannot decode and prunes every file
    /// it did not write, so sharing a directory would have each build throw
    /// the other's entries away and reparse the whole corpus at every
    /// complete scan.
    static var defaultDirectory: URL {
        supportDirectory.appendingPathComponent("claude-usage-cache-v\(directoryFormat)", isDirectory: true)
    }

    /// The directories earlier formats used: version 1's unversioned one,
    /// then one per version below `directoryFormat`.
    static var legacyDirectories: [URL] {
        [supportDirectory.appendingPathComponent("claude-usage-cache", isDirectory: true)]
            + (2..<max(2, directoryFormat)).map {
                supportDirectory.appendingPathComponent("claude-usage-cache-v\($0)", isDirectory: true)
            }
    }

    /// A legacy directory nothing has written for this long belongs to no
    /// running build any more and is removed by the next complete scan.
    static let legacyIdleInterval: TimeInterval = 7 * 86_400

    /// Days are cut at local midnight when a record is parsed, so an entry
    /// is only valid under the calendar and time zone it was parsed in.
    static func currentCalendarTag() -> String {
        "\(Calendar.current.identifier)|\(TimeZone.current.identifier)"
    }

    static func entryFileName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".usage"
    }

    /// How many bytes of SHA-256 a boundary digest keeps: 14 is the most a
    /// `Data` holds inline, so the digest every file's cached value carries
    /// costs no heap object of its own. A rewrite still passes for
    /// an append with a chance of only 2^-112.
    static let boundaryDigestLength = 14

    /// The first `boundaryDigestLength` bytes of SHA-256 over `bytes`.
    static func boundaryDigest(of bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes).prefix(boundaryDigestLength))
    }

    struct Entry: Sendable, Equatable {
        let fingerprint: LogFileFingerprint
        /// Byte offset (a line boundary) up to which `value` accounts for the file.
        let parsedBytes: Int64
        let value: ClaudeFileUsage
    }

    struct Statistics: Sendable, Equatable {
        var entriesRead = 0
        var invalidEntries = 0
        var writes = 0
        var rejectedWrites = 0
        var failedWrites = 0
    }

    enum DecodeError: Error, Equatable {
        case tooShort
        case badMagic
        case version(UInt32)
        case checksum
        case truncated
        case calendarTag
        case path
    }

    let directory: URL
    let calendarTag: String
    /// The scan that last stored each path, so a scan that started earlier
    /// and finished later cannot put its older view over a newer one.
    private var latestScan: [String: UInt64] = [:]
    private var stats = Statistics()

    let legacyDirectories: [URL]

    init(directory: URL, calendarTag: String = ClaudeUsageCacheStore.currentCalendarTag(),
         legacyDirectories: [URL] = []) {
        self.directory = directory
        self.calendarTag = calendarTag
        self.legacyDirectories = legacyDirectories
    }

    func statistics() -> Statistics { stats }

    private func url(for path: String) -> URL {
        directory.appendingPathComponent(Self.entryFileName(for: path))
    }

    /// The stored entry for `path`, or nil when there is none or what is
    /// there cannot be trusted — in which case it is deleted.
    func entry(for path: String) -> Entry? {
        let url = url(for: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        stats.entriesRead += 1
        do {
            let entry = try Self.decode(data, calendarTag: calendarTag)
            guard entry.fingerprint.path == path else { throw DecodeError.path }
            return entry
        } catch {
            stats.invalidEntries += 1
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Writes `entry` unless a later-started scan already stored this path.
    /// Returns whether it was written.
    @discardableResult
    func save(_ entry: Entry, scan: UInt64 = 0) -> Bool {
        let path = entry.fingerprint.path
        if let latest = latestScan[path], latest > scan {
            stats.rejectedWrites += 1
            return false
        }
        let data = Self.encode(entry, calendarTag: calendarTag)
        let temp = directory.appendingPathComponent("\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp)
            guard rename(temp.path, url(for: path).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            stats.failedWrites += 1
            return false
        }
        latestScan[path] = scan
        stats.writes += 1
        return true
    }

    /// Deletes every file in the directory that is not the entry of one of
    /// `paths` — entries of logs that are gone, and temp files a crash left.
    /// Only a scan that listed every log file may call this; an empty list
    /// is a listing that failed, not an empty corpus, and prunes nothing.
    func prune(keeping paths: [String], now: Date = Date()) {
        guard !paths.isEmpty else { return }
        let keep = Set(paths.map(Self.entryFileName(for:)))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let kept = Set(paths)
        latestScan = latestScan.filter { kept.contains($0.key) }
        removeIdleLegacyDirectories(now: now)
    }

    /// Removes each legacy directory none of whose files was written in the
    /// last `legacyIdleInterval`: a build of that format still running
    /// rewrites the live session's entry every minute, so an idle directory
    /// is one nothing will read again.
    private func removeIdleLegacyDirectories(now: Date) {
        let fm = FileManager.default
        for legacy in legacyDirectories {
            guard let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { continue }
            let newest = names.compactMap { name in
                (try? fm.attributesOfItem(atPath: legacy.appendingPathComponent(name).path))?[.modificationDate] as? Date
            }.max()
            if let newest, now.timeIntervalSince(newest) < Self.legacyIdleInterval { continue }
            try? fm.removeItem(at: legacy)
        }
    }

    // MARK: Layout

    // Little-endian throughout. Strings are a length prefix plus UTF-8.
    //
    //   magic "AMCU"            4
    //   formatVersion           u32
    //   calendarTag             u16 length, bytes
    //   path                    u32 length, bytes
    //   size                    i64
    //   modifiedAt              f64 (bit pattern)
    //   hasIdentity             u8
    //   fileID, volumeID        u64, u64 (zero without identity)
    //   parsedBytes             i64
    //   boundaryDigest          u8 length, bytes
    //   models                  u32 count, each u16 length + bytes
    //   attributeSets           u16 count, each: version s8, effort s8, entrypoint s8
    //   facts                   usageHighWaterMs i64?, firstCwd s16, firstCwdMs i64?,
    //                           firstEntrypoint s8, firstCcVersion s8
    //   limitEvents             u32 count, each: uuid s8, requestID s8, tsMs i64,
    //                           windowID s8, status s8, resetsAtMs i64?, overageStatus s8,
    //                           overageDisabledReason s8, isUsingOverage tri,
    //                           fallbackAvailable tri, source u8 (0 quotaLimits,
    //                           1 rate_limit_info), apiError s8, ccVersion s8
    //   usageReports            u32 count, each: uuid s8, tsMs i64, ccVersion s8,
    //                           hasLimits u8, extraEnabled tri, extraMonthlyLimit i64?,
    //                           extraUsedCredits i64?, limits u8 count, each: index u8,
    //                           kind s8, group s8, hasPercent u8, percent f64,
    //                           severity s8, isActive tri, resetsAtMs i64?, scopeModel s8
    //   costStates              u32 count, each: sessionID s8, startTimeMs i64,
    //                           totalDurationMs i64, totalAPIDurationMs i64?,
    //                           totalCostUSD f64, hasUnknownModelCost u8, afterTsMs i64?,
    //                           models u8 count, each: modelKey s8, 6 × i64, costUSD f64
    //   compactEvents           u32 count, each: uuid s8, tsMs i64, trigger s8,
    //                           preTokens i64?, postTokens i64?
    //   keyed                   u32 count, each: hi u64, lo u64, day f64,
    //                           finality u8, earlier-iteration count u8,
    //                           model u32 (index), 5 × i64 counts, stamp
    //                           (firstMs i64, latestMs i64, ownFinalMs i64,
    //                           thinking u32, attributes u16, flags u8), then per
    //                           earlier iteration: model u32, 5 × i64
    //   unkeyed                 u32 count, each: day f64, model u32, 5 × i64
    //   checksum                SHA-256 of everything above, 32 bytes
    //
    // s8 = u8 length (0xFF = nil) + UTF-8; s16 = u16 length (0xFFFF = nil) +
    // UTF-8; i64? = Int64.min for nil; tri = u8 0 false, 1 true, 2 nil.
    // Everything new sits before the keyed count, so an empty entry still
    // ends "keyed u32, unkeyed u32" and a record's finality stays at offset 24.

    static let checksumLength = 32
    /// A keyed record with no earlier iterations: 70 bytes of usage plus a
    /// 31-byte stamp.
    static let keyedRecordLength = 101
    /// One earlier iteration: model index and five counts.
    static let iterationLength = 44
    /// Most events of each kind one file keeps (the first ones, in file order).
    static let maxEventsPerKind = 4_096
    /// Most `limits[]` entries one `/usage` report keeps.
    static let maxReportLimits = 16
    /// Most models one cost state keeps (sorted by key).
    static let maxCostStateModels = 32
    private static let limitEventMinLength = 27
    private static let usageReportMinLength = 29
    private static let reportLimitMinLength = 23
    private static let costStateMinLength = 43
    private static let costStateModelMinLength = 57
    private static let compactEventMinLength = 26
    private static let attributeSetMinLength = 3
    private static let limitEventSources = ["quotaLimits", "rate_limit_info"]

    nonisolated static func encode(_ entry: Entry, calendarTag: String) -> Data {
        var models: [String] = []
        var modelIndex: [String: UInt32] = [:]
        func index(_ model: String) -> UInt32 {
            if let known = modelIndex[model] { return known }
            let next = UInt32(models.count)
            models.append(model)
            modelIndex[model] = next
            return next
        }
        let keyedModels = entry.value.keyed.map { index($0.usage.model) }
        let iterationModels = entry.value.keyed.map { $0.earlierIterations.map { index($0.model) } }
        let unkeyedModels = entry.value.unkeyed.map { index($0.model) }

        let extras = entry.value.extras
        let extrasEstimate = 64 + entry.value.attributeSets.count * 32 + (extras.firstCwd?.utf8.count ?? 0)
            + extras.limitEvents.count * 160 + extras.usageReports.count * 400
            + extras.costStates.count * 300 + extras.compactEvents.count * 80
        var w = ByteWriter(capacity: 128 + entry.value.keyed.count * keyedRecordLength
                           + entry.value.unkeyed.count * 52 + extrasEstimate)
        w.bytes(magic)
        w.u32(formatVersion)
        w.string16(calendarTag)
        w.string32(entry.fingerprint.path)
        w.i64(entry.fingerprint.size)
        w.f64(entry.fingerprint.modifiedAt)
        if let fileID = entry.fingerprint.fileID, let volumeID = entry.fingerprint.volumeID {
            w.u8(1)
            w.u64(fileID)
            w.u64(volumeID)
        } else {
            w.u8(0)
            w.u64(0)
            w.u64(0)
        }
        w.i64(entry.parsedBytes)
        let digest = entry.value.boundaryDigest.prefix(255)
        w.u8(UInt8(digest.count))
        w.bytes(digest)
        w.u32(UInt32(models.count))
        for model in models { w.string16(model) }
        encodeExtras(entry.value, into: &w)
        w.u32(UInt32(entry.value.keyed.count))
        for ((record, model), earlierModels) in zip(zip(entry.value.keyed, keyedModels), iterationModels) {
            w.u64(record.key.hi)
            w.u64(record.key.lo)
            w.f64(record.usage.day.timeIntervalSince1970)
            w.u8(record.finality.rawValue)
            // The scanner splits at most `ClaudeJSONLScanner.maxIterations`.
            w.u8(UInt8(record.earlierIterations.count))
            w.u32(model)
            w.counts(record.usage.counts)
            w.i64(record.stamp.firstMs)
            w.i64(record.stamp.latestMs)
            w.i64(record.stamp.ownFinalMs)
            w.u32(record.stamp.thinking)
            w.u16(record.stamp.attributes)
            w.u8(record.stamp.flags.rawValue)
            for (iteration, iterationModel) in zip(record.earlierIterations, earlierModels) {
                w.u32(iterationModel)
                w.counts(iteration.counts)
            }
        }
        w.u32(UInt32(entry.value.unkeyed.count))
        for (usage, model) in zip(entry.value.unkeyed, unkeyedModels) {
            w.f64(usage.day.timeIntervalSince1970)
            w.u32(model)
            w.counts(usage.counts)
        }
        let checksum = SHA256.hash(data: w.data)
        w.bytes(checksum)
        return w.data
    }

    /// Attribute sets, file facts and the four event lists, in layout order.
    /// Every value was bounded when it was parsed; a value out of bounds here
    /// is a bug (asserted) and is written as nil, never cut.
    private nonisolated static func encodeExtras(_ value: ClaudeFileUsage, into w: inout ByteWriter) {
        assert(value.attributeSets.count <= Int(UInt16.max))
        w.u16(UInt16(min(value.attributeSets.count, Int(UInt16.max))))
        for set in value.attributeSets.prefix(Int(UInt16.max)) {
            w.string8(set.version)
            w.string8(set.effort)
            w.string8(set.entrypoint)
        }
        let e = value.extras
        w.i64(value.usageHighWaterMs)
        w.string16(optional: e.firstCwd)
        w.optionalI64(e.firstCwdMs)
        w.string8(e.firstEntrypoint)
        w.string8(e.firstCcVersion)

        w.u32(UInt32(e.limitEvents.count))
        for event in e.limitEvents {
            w.string8(event.uuid)
            w.string8(event.requestID)
            w.i64(event.tsMs)
            w.string8(event.windowID)
            w.string8(event.status)
            w.optionalI64(event.resetsAtMs)
            w.string8(event.overageStatus)
            w.string8(event.overageDisabledReason)
            w.tri(event.isUsingOverage)
            w.tri(event.fallbackAvailable)
            let source = limitEventSources.firstIndex(of: event.source)
            assert(source != nil, "unknown limit event source")
            w.u8(UInt8(source ?? 0))
            w.string8(event.apiError)
            w.string8(event.ccVersion)
        }

        w.u32(UInt32(e.usageReports.count))
        for report in e.usageReports {
            w.string8(report.uuid)
            w.i64(report.tsMs)
            w.string8(report.ccVersion)
            w.u8(report.hasLimits ? 1 : 0)
            w.tri(report.extraEnabled)
            w.optionalI64(report.extraMonthlyLimit.map(Int64.init))
            w.optionalI64(report.extraUsedCredits.map(Int64.init))
            assert(report.limits.count <= maxReportLimits)
            w.u8(UInt8(min(report.limits.count, Int(UInt8.max))))
            for limit in report.limits.prefix(Int(UInt8.max)) {
                assert((0...Int(UInt8.max)).contains(limit.index))
                w.u8(UInt8(clamping: limit.index))
                w.string8(limit.kind)
                w.string8(limit.group)
                w.u8(limit.percent == nil ? 0 : 1)
                w.f64(limit.percent ?? 0)
                w.string8(limit.severity)
                w.tri(limit.isActive)
                w.optionalI64(limit.resetsAtMs)
                w.string8(limit.scopeModel)
            }
        }

        w.u32(UInt32(e.costStates.count))
        for state in e.costStates {
            w.string8(state.sessionID)
            w.i64(state.startTimeMs)
            w.i64(state.totalDurationMs)
            w.optionalI64(state.totalAPIDurationMs)
            w.f64(state.totalCostUSD)
            w.u8(state.hasUnknownModelCost ? 1 : 0)
            w.optionalI64(state.afterTsMs)
            assert(state.models.count <= maxCostStateModels)
            w.u8(UInt8(min(state.models.count, Int(UInt8.max))))
            for model in state.models.prefix(Int(UInt8.max)) {
                w.string8(model.modelKey)
                for count in [model.input, model.output, model.cacheRead, model.cacheCreation, model.thinking, model.webSearch] {
                    w.i64(Int64(count))
                }
                w.f64(model.costUSD)
            }
        }

        w.u32(UInt32(e.compactEvents.count))
        for event in e.compactEvents {
            w.string8(event.uuid)
            w.i64(event.tsMs)
            w.string8(event.trigger)
            w.optionalI64(event.preTokens.map(Int64.init))
            w.optionalI64(event.postTokens.map(Int64.init))
        }
    }

    nonisolated static func decode(_ data: Data, calendarTag: String) throws -> Entry {
        guard data.count >= magic.count + 4 + checksumLength else { throw DecodeError.tooShort }
        return try data.withUnsafeBytes { raw -> Entry in
            let bodyEnd = raw.count - checksumLength
            var r = ByteReader(raw: raw, limit: bodyEnd)
            guard try r.bytes(magic.count).elementsEqual(magic) else { throw DecodeError.badMagic }
            let version = try r.u32()
            guard version == formatVersion else { throw DecodeError.version(version) }
            var hasher = SHA256()
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<bodyEnd]))
            guard hasher.finalize().elementsEqual(raw[bodyEnd...]) else { throw DecodeError.checksum }

            guard try r.string16() == calendarTag else { throw DecodeError.calendarTag }
            let path = try r.string32()
            let size = try r.i64()
            let modifiedAt = try r.f64()
            let hasIdentity = try r.u8() != 0
            let fileID = try r.u64()
            let volumeID = try r.u64()
            let parsedBytes = try r.i64()
            // The checksum says these bytes are what was written; this says
            // what was written makes sense as a file, so a resume can never
            // seek before the start or past the end.
            guard size >= 0, parsedBytes >= 0, parsedBytes <= size, modifiedAt.isFinite else {
                throw DecodeError.truncated
            }
            let digest = try r.data(Int(try r.u8()))
            let modelCount = try r.count(elementSize: 2)
            var models: [String] = []
            models.reserveCapacity(modelCount)
            for _ in 0..<modelCount { models.append(try r.string16()) }
            func model(_ index: UInt32) throws -> String {
                guard index < UInt32(models.count) else { throw DecodeError.truncated }
                return models[Int(index)]
            }
            var value = ClaudeFileUsage(keyed: [], unkeyed: [], boundaryDigest: digest)
            try decodeExtras(&r, into: &value)
            let keyedCount = try r.count(elementSize: keyedRecordLength)
            var keyed: [KeyedUsage] = []
            keyed.reserveCapacity(keyedCount)
            for _ in 0..<keyedCount {
                let key = DedupKey(hi: try r.u64(), lo: try r.u64())
                let day = try r.day()
                guard let finality = UsageFinality(rawValue: try r.u8()) else { throw DecodeError.truncated }
                let earlierCount = Int(try r.u8())
                let usage = DayModelUsage(day: day, model: try model(try r.u32()), counts: try r.counts())
                let stamp = try r.stamp(finality: finality, attributeSets: value.attributeSets.count)
                var earlier: [DayModelUsage] = []
                if earlierCount > 0 {
                    earlier.reserveCapacity(earlierCount)
                    for _ in 0..<earlierCount {
                        earlier.append(DayModelUsage(day: day, model: try model(try r.u32()), counts: try r.counts()))
                    }
                }
                keyed.append(KeyedUsage(key: key, usage: usage, earlierIterations: earlier, finality: finality, stamp: stamp))
            }
            let unkeyedCount = try r.count(elementSize: 52)
            var unkeyed: [DayModelUsage] = []
            unkeyed.reserveCapacity(unkeyedCount)
            for _ in 0..<unkeyedCount {
                let day = try r.day()
                let model = try model(try r.u32())
                unkeyed.append(DayModelUsage(day: day, model: model, counts: try r.counts()))
            }
            guard r.offset == bodyEnd else { throw DecodeError.truncated }
            value.keyed = keyed
            value.unkeyed = unkeyed
            return Entry(
                fingerprint: LogFileFingerprint(
                    path: path, size: size, modifiedAt: modifiedAt,
                    fileID: hasIdentity ? fileID : nil, volumeID: hasIdentity ? volumeID : nil),
                parsedBytes: parsedBytes,
                value: value)
        }
    }

    /// The inverse of `encodeExtras`. Every count is checked against the bytes
    /// left before anything is allocated, every string must be valid UTF-8,
    /// every flag byte one the layout defines and every float finite.
    private nonisolated static func decodeExtras(_ r: inout ByteReader, into value: inout ClaudeFileUsage) throws {
        let setCount = try r.count16(elementSize: attributeSetMinLength)
        var sets: [RecordAttributes] = []
        sets.reserveCapacity(setCount)
        for _ in 0..<setCount {
            sets.append(RecordAttributes(version: try r.string8(), effort: try r.string8(), entrypoint: try r.string8()))
        }
        value.attributeSets = sets
        value.usageHighWaterMs = try r.i64()
        guard value.usageHighWaterMs == RecordStamp.noTime || ByteReader.plausibleMs(value.usageHighWaterMs) else {
            throw DecodeError.truncated
        }
        var e = HistoryFileEvents()
        e.firstCwd = try r.string16Optional()
        e.firstCwdMs = try r.optionalI64()
        e.firstEntrypoint = try r.string8()
        e.firstCcVersion = try r.string8()

        let limitCount = try r.count(elementSize: limitEventMinLength)
        guard limitCount <= maxEventsPerKind else { throw DecodeError.truncated }
        e.limitEvents.reserveCapacity(limitCount)
        for _ in 0..<limitCount {
            let uuid = try r.requiredString8()
            let requestID = try r.string8()
            let tsMs = try r.i64()
            let windowID = try r.requiredString8()
            let status = try r.string8()
            let resetsAtMs = try r.optionalI64()
            let overageStatus = try r.string8()
            let overageDisabledReason = try r.string8()
            let isUsingOverage = try r.tri()
            let fallbackAvailable = try r.tri()
            let source = Int(try r.u8())
            guard source < limitEventSources.count else { throw DecodeError.truncated }
            e.limitEvents.append(LimitEventObservation(
                uuid: uuid, requestID: requestID, tsMs: tsMs, windowID: windowID, status: status,
                resetsAtMs: resetsAtMs, overageStatus: overageStatus, overageDisabledReason: overageDisabledReason,
                isUsingOverage: isUsingOverage, fallbackAvailable: fallbackAvailable,
                source: limitEventSources[source], apiError: try r.string8(), ccVersion: try r.string8()))
        }

        let reportCount = try r.count(elementSize: usageReportMinLength)
        guard reportCount <= maxEventsPerKind else { throw DecodeError.truncated }
        e.usageReports.reserveCapacity(reportCount)
        for _ in 0..<reportCount {
            let uuid = try r.requiredString8()
            let tsMs = try r.i64()
            let ccVersion = try r.string8()
            let hasLimits = try r.bool()
            let extraEnabled = try r.tri()
            let extraMonthlyLimit = try r.optionalI64().map { Int($0) }
            let extraUsedCredits = try r.optionalI64().map { Int($0) }
            let count = Int(try r.u8())
            guard count <= maxReportLimits, count <= (r.limit - r.offset) / reportLimitMinLength else {
                throw DecodeError.truncated
            }
            var limits: [UsageReportLimit] = []
            limits.reserveCapacity(count)
            for _ in 0..<count {
                let index = Int(try r.u8())
                let kind = try r.requiredString8()
                let group = try r.string8()
                let hasPercent = try r.bool()
                let percent = try r.finiteF64()
                guard hasPercent || percent.bitPattern == 0 else { throw DecodeError.truncated }
                limits.append(UsageReportLimit(
                    index: index, kind: kind, group: group, percent: hasPercent ? percent : nil,
                    severity: try r.string8(), isActive: try r.tri(), resetsAtMs: try r.optionalI64(),
                    scopeModel: try r.string8()))
            }
            e.usageReports.append(UsageReportObservation(
                uuid: uuid, tsMs: tsMs, ccVersion: ccVersion, hasLimits: hasLimits, extraEnabled: extraEnabled,
                extraMonthlyLimit: extraMonthlyLimit, extraUsedCredits: extraUsedCredits, limits: limits))
        }

        let costCount = try r.count(elementSize: costStateMinLength)
        guard costCount <= maxEventsPerKind else { throw DecodeError.truncated }
        e.costStates.reserveCapacity(costCount)
        for _ in 0..<costCount {
            let sessionID = try r.requiredString8()
            let startTimeMs = try r.i64()
            let totalDurationMs = try r.i64()
            let totalAPIDurationMs = try r.optionalI64()
            let totalCostUSD = try r.finiteF64()
            let hasUnknownModelCost = try r.bool()
            let afterTsMs = try r.optionalI64()
            let count = Int(try r.u8())
            guard count <= maxCostStateModels, count <= (r.limit - r.offset) / costStateModelMinLength else {
                throw DecodeError.truncated
            }
            var models: [CostStateModel] = []
            models.reserveCapacity(count)
            for _ in 0..<count {
                let key = try r.requiredString8()
                var counts: [Int] = []
                for _ in 0..<6 { counts.append(Int(try r.i64())) }
                models.append(CostStateModel(
                    modelKey: key, input: counts[0], output: counts[1], cacheRead: counts[2],
                    cacheCreation: counts[3], thinking: counts[4], webSearch: counts[5], costUSD: try r.finiteF64()))
            }
            e.costStates.append(CostStateObservation(
                sessionID: sessionID, startTimeMs: startTimeMs, totalDurationMs: totalDurationMs,
                totalAPIDurationMs: totalAPIDurationMs, totalCostUSD: totalCostUSD,
                hasUnknownModelCost: hasUnknownModelCost, afterTsMs: afterTsMs, models: models))
        }

        let compactCount = try r.count(elementSize: compactEventMinLength)
        guard compactCount <= maxEventsPerKind else { throw DecodeError.truncated }
        e.compactEvents.reserveCapacity(compactCount)
        for _ in 0..<compactCount {
            e.compactEvents.append(CompactEventObservation(
                uuid: try r.requiredString8(), tsMs: try r.i64(), trigger: try r.string8(),
                preTokens: try r.optionalI64().map { Int($0) }, postTokens: try r.optionalI64().map { Int($0) }))
        }
        value.extras = e
    }
}

// MARK: - Bytes

private struct ByteWriter {
    private(set) var data: Data

    init(capacity: Int) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func bytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 { data.append(contentsOf: bytes) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }

    /// At most 65,535 bytes; longer text is cut, which only a calendar tag or
    /// a model id of that length could hit.
    mutating func string16(_ s: String) {
        let utf8 = Array(s.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(utf8.count))
        bytes(utf8)
    }

    mutating func string32(_ s: String) {
        let utf8 = Array(s.utf8)
        u32(UInt32(utf8.count))
        bytes(utf8)
    }

    /// u8 length, 0xFF = nil. Parsing keeps such strings at 254 bytes or
    /// fewer; a longer one is a bug and is written as nil, never cut.
    mutating func string8(_ s: String?) {
        guard let s else { return u8(0xFF) }
        let count = s.utf8.count
        assert(count < 0xFF, "string8 over its bound")
        guard count < 0xFF else { return u8(0xFF) }
        u8(UInt8(count))
        bytes(s.utf8)
    }

    /// u16 length, 0xFFFF = nil.
    mutating func string16(optional s: String?) {
        guard let s else { return u16(0xFFFF) }
        let count = s.utf8.count
        assert(count < 0xFFFF, "string16 over its bound")
        guard count < 0xFFFF else { return u16(0xFFFF) }
        u16(UInt16(count))
        bytes(s.utf8)
    }

    /// `Int64.min` stands for nil, so it can never be a value.
    mutating func optionalI64(_ v: Int64?) {
        assert(v != Int64.min, "Int64.min is the nil marker")
        i64(v ?? Int64.min)
    }

    mutating func tri(_ v: Bool?) { u8(v.map { $0 ? 1 : 0 } ?? 2) }

    mutating func counts(_ c: TokenCounts) {
        i64(Int64(c.input))
        i64(Int64(c.output))
        i64(Int64(c.cacheWrite5m))
        i64(Int64(c.cacheWrite1h))
        i64(Int64(c.cacheRead))
    }
}

private struct ByteReader {
    let raw: UnsafeRawBufferPointer
    let limit: Int
    var offset = 0

    init(raw: UnsafeRawBufferPointer, limit: Int) {
        self.raw = raw
        self.limit = limit
    }

    private mutating func take(_ n: Int) throws -> Int {
        guard n >= 0, offset <= limit - n else { throw ClaudeUsageCacheStore.DecodeError.truncated }
        defer { offset += n }
        return offset
    }

    mutating func bytes(_ n: Int) throws -> Slice<UnsafeRawBufferPointer> {
        let start = try take(n)
        return raw[start..<start + n]
    }

    mutating func data(_ n: Int) throws -> Data { Data(try bytes(n)) }
    mutating func u8() throws -> UInt8 { raw[try take(1)] }

    mutating func u16() throws -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: try take(2), as: UInt16.self))
    }

    mutating func u32() throws -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: try take(4), as: UInt32.self))
    }

    mutating func u64() throws -> UInt64 {
        UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: try take(8), as: UInt64.self))
    }

    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    mutating func day() throws -> Date {
        let seconds = try f64()
        guard seconds.isFinite else { throw ClaudeUsageCacheStore.DecodeError.truncated }
        return Date(timeIntervalSince1970: seconds)
    }

    mutating func string16() throws -> String {
        String(decoding: try bytes(Int(try u16())), as: UTF8.self)
    }

    mutating func string32() throws -> String {
        String(decoding: try bytes(Int(try u32())), as: UTF8.self)
    }

    /// A count that the remaining bytes could actually hold.
    mutating func count(elementSize: Int) throws -> Int {
        let count = Int(try u32())
        guard count <= (limit - offset) / elementSize else { throw ClaudeUsageCacheStore.DecodeError.truncated }
        return count
    }

    mutating func count16(elementSize: Int) throws -> Int {
        let count = Int(try u16())
        guard count <= (limit - offset) / elementSize else { throw ClaudeUsageCacheStore.DecodeError.truncated }
        return count
    }

    /// Valid UTF-8 or a throw: `String(decoding:)` would repair damage into
    /// a string that encodes to other bytes.
    private mutating func strictString(_ n: Int) throws -> String {
        let raw = try bytes(n)
        let s = String(decoding: raw, as: UTF8.self)
        guard s.utf8.elementsEqual(raw) else { throw ClaudeUsageCacheStore.DecodeError.truncated }
        return s
    }

    mutating func string8() throws -> String? {
        let n = try u8()
        return n == 0xFF ? nil : try strictString(Int(n))
    }

    mutating func requiredString8() throws -> String {
        guard let s = try string8() else { throw ClaudeUsageCacheStore.DecodeError.truncated }
        return s
    }

    mutating func string16Optional() throws -> String? {
        let n = try u16()
        return n == 0xFFFF ? nil : try strictString(Int(n))
    }

    mutating func optionalI64() throws -> Int64? {
        let v = try i64()
        return v == Int64.min ? nil : v
    }

    mutating func tri() throws -> Bool? {
        switch try u8() {
        case 0: return false
        case 1: return true
        case 2: return nil
        default: throw ClaudeUsageCacheStore.DecodeError.truncated
        }
    }

    mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw ClaudeUsageCacheStore.DecodeError.truncated
        }
    }

    mutating func finiteF64() throws -> Double {
        let v = try f64()
        guard v.isFinite else { throw ClaudeUsageCacheStore.DecodeError.truncated }
        return v
    }

    /// A time the parser could have produced (`ClaudeJSONLScanner.epochMs`):
    /// within ±10^15 ms, so no arithmetic on it can overflow.
    static func plausibleMs(_ ms: Int64) -> Bool { ms > -1_000_000_000_000_000 && ms < 1_000_000_000_000_000 }

    /// A record's stamp, held to what a parse can produce: no later time
    /// without a first time, plausible times with first <= final <= last
    /// (the first is a MIN over the key's records, the last a MAX over the
    /// counted ones, the final one of them), a final time only on a final
    /// record, a last time never on a zeroed one, known flags, an attribute
    /// set that exists.
    mutating func stamp(finality: UsageFinality, attributeSets: Int) throws -> RecordStamp {
        var s = RecordStamp()
        s.firstMs = try i64()
        s.latestMs = try i64()
        s.ownFinalMs = try i64()
        s.thinking = try u32()
        s.attributes = try u16()
        let flags = try u8()
        s.flags = RequestFlags(rawValue: flags)
        let known = RequestFlags.fast.rawValue | RequestFlags.abortedMidStream.rawValue
        let noTime = RecordStamp.noTime
        let timesValid: Bool
        if s.firstMs == noTime {
            timesValid = s.latestMs == noTime && s.ownFinalMs == noTime
        } else {
            let lastValid = s.latestMs == noTime || (Self.plausibleMs(s.latestMs) && s.latestMs >= s.firstMs)
            let finalValid = s.ownFinalMs == noTime
                || (s.latestMs != noTime && s.ownFinalMs >= s.firstMs && s.ownFinalMs <= s.latestMs)
            timesValid = Self.plausibleMs(s.firstMs) && lastValid && finalValid
        }
        guard timesValid,
              flags & ~known == 0,
              Int(s.attributes) <= attributeSets,
              finality == .final || s.ownFinalMs == noTime,
              finality != .zeroed || s.latestMs == noTime else {
            throw ClaudeUsageCacheStore.DecodeError.truncated
        }
        return s
    }

    mutating func counts() throws -> TokenCounts {
        var c = TokenCounts()
        c.input = Int(try i64())
        c.output = Int(try i64())
        c.cacheWrite5m = Int(try i64())
        c.cacheWrite1h = Int(try i64())
        c.cacheRead = Int(try i64())
        return c
    }
}
