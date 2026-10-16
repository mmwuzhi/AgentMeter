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

/// One deduplicated usage record of a file.
struct KeyedUsage: Sendable, Equatable {
    let key: DedupKey
    let usage: DayModelUsage
}

/// What one log file contributes to the usage report, up to a line boundary:
/// the statistics behind every record that carries usage, and nothing of the
/// conversation itself.
struct ClaudeFileUsage: Sendable, Equatable {
    /// One entry per key, in file order — the first occurrence of a repeated
    /// key wins. Kept per record rather than pre-aggregated so
    /// `ClaudeJSONLScanner.usageReport(files:)` can drop a record another
    /// file already contributed: resuming a session copies the earlier
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

    static let empty = ClaudeFileUsage(keyed: [], unkeyed: [],
                                       boundaryDigest: ClaudeUsageCacheStore.boundaryDigest(of: Data()))
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
        store: ClaudeUsageCacheStore(directory: ClaudeUsageCacheStore.defaultDirectory))

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
    static let formatVersion: UInt32 = 1
    static let magic: [UInt8] = Array("AMCU".utf8)
    /// How many bytes before the parsed boundary `boundaryDigest` covers.
    static let boundarySampleLength = 4096

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
            .appendingPathComponent("claude-usage-cache", isDirectory: true)
    }

    /// Days are cut at local midnight when a record is parsed, so an entry
    /// is only valid under the calendar and time zone it was parsed in.
    static func currentCalendarTag() -> String {
        "\(Calendar.current.identifier)|\(TimeZone.current.identifier)"
    }

    static func entryFileName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".usage"
    }

    /// The first 16 bytes of SHA-256 over `bytes`.
    static func boundaryDigest(of bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes).prefix(16))
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

    init(directory: URL, calendarTag: String = ClaudeUsageCacheStore.currentCalendarTag()) {
        self.directory = directory
        self.calendarTag = calendarTag
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
    func prune(keeping paths: [String]) {
        guard !paths.isEmpty else { return }
        let keep = Set(paths.map(Self.entryFileName(for:)))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let kept = Set(paths)
        latestScan = latestScan.filter { kept.contains($0.key) }
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
    //   keyed                   u32 count, each: hi u64, lo u64, day f64,
    //                           model u32 (index), 5 × i64 counts
    //   unkeyed                 u32 count, each: day f64, model u32, 5 × i64
    //   checksum                SHA-256 of everything above, 32 bytes

    static let checksumLength = 32

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
        let unkeyedModels = entry.value.unkeyed.map { index($0.model) }

        var w = ByteWriter(capacity: 128 + entry.value.keyed.count * 68 + entry.value.unkeyed.count * 52)
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
        w.u32(UInt32(entry.value.keyed.count))
        for (record, model) in zip(entry.value.keyed, keyedModels) {
            w.u64(record.key.hi)
            w.u64(record.key.lo)
            w.f64(record.usage.day.timeIntervalSince1970)
            w.u32(model)
            w.counts(record.usage.counts)
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
            let keyedCount = try r.count(elementSize: 68)
            var keyed: [KeyedUsage] = []
            keyed.reserveCapacity(keyedCount)
            for _ in 0..<keyedCount {
                let key = DedupKey(hi: try r.u64(), lo: try r.u64())
                let day = try r.day()
                let model = try model(try r.u32())
                keyed.append(KeyedUsage(key: key, usage: DayModelUsage(day: day, model: model, counts: try r.counts())))
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
            return Entry(
                fingerprint: LogFileFingerprint(
                    path: path, size: size, modifiedAt: modifiedAt,
                    fileID: hasIdentity ? fileID : nil, volumeID: hasIdentity ? volumeID : nil),
                parsedBytes: parsedBytes,
                value: ClaudeFileUsage(keyed: keyed, unkeyed: unkeyed, boundaryDigest: digest))
        }
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
