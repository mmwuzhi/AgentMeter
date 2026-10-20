import CryptoKit
import Foundation

// The pure pieces of the request merge: the key bytes, the record and
// attribute signatures, observation validation, the accounting day. No SQLite
// here, so the test oracle and the store use the very same functions.

/// `dict.kind`: what a label in `dict` names.
enum HistoryLabelKind: Int64, Sendable, CaseIterable {
    case model = 1, ccVersion = 2, effort = 3, entrypoint = 4, plan = 5, tier = 6, scopeName = 7
}

extension DedupKey {
    /// The 16 bytes stored in `request.key`: the SHA-256 prefix the key was cut
    /// from, in digest order (`hi` and `lo` were loaded little-endian from it).
    var historyBytes: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(16)
        withUnsafeBytes(of: hi.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: lo.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    init?(historyBytes bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for i in 0..<8 { hi |= UInt64(bytes[i]) << (8 * UInt64(i)) }
        for i in 0..<8 { lo |= UInt64(bytes[8 + i]) << (8 * UInt64(i)) }
        self.init(hi: hi, lo: lo)
    }

    /// Lowercase hex of `historyBytes`: how the logical dump and the queries name a key.
    var historyHex: String { HistoryHex.encode(historyBytes) }
}

enum HistoryHex {
    static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let h = nibble(chars[i]), let l = nibble(chars[i + 1]) else { return nil }
            out.append(h << 4 | l)
            i += 2
        }
        return out
    }
}

/// Little-endian canonical bytes for the content hashes (`rec_sig`, report keys).
struct HistoryCanonicalBytes {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        u32(UInt32(truncatingIfNeeded: utf8.count))
        bytes.append(contentsOf: utf8)
    }
    mutating func optional<T>(_ v: T?, _ write: (inout HistoryCanonicalBytes, T) -> Void) {
        if let v { u8(1); write(&self, v) } else { u8(0) }
    }

    var sha256: SHA256.Digest { SHA256.hash(data: bytes) }
}

/// `rec_sig`: the first 8 bytes of SHA-256 over the record's BILLING content
/// only (finality, the parts in order with their model and five counts, the
/// thinking count), read big-endian and stored as a signed Int64. Timestamps,
/// version, effort, entrypoint and flags are deliberately not in it: copies of
/// one record that differ only there (a fork's re-stamped copy) must tie on it,
/// so the request row is the same whichever copy arrived first.
enum HistoryRecordSignature {
    static func compute(finality: UsageFinality, parts: [RequestPart], thinking: Int?) -> Int64 {
        var w = HistoryCanonicalBytes()
        writeBilling(&w, finality: finality, parts: parts, thinking: thinking)
        return signedPrefix(w)
    }

    static func compute(_ o: RequestObservation) -> Int64 {
        compute(finality: o.finality, parts: o.parts, thinking: o.thinkingTokens)
    }

    static func writeBilling(_ w: inout HistoryCanonicalBytes, finality: UsageFinality, parts: [RequestPart],
                             thinking: Int?) {
        w.u8(finality.rawValue)
        w.u32(UInt32(truncatingIfNeeded: parts.count))
        for part in parts {
            w.string(part.model)
            w.i64(Int64(part.counts.input))
            w.i64(Int64(part.counts.output))
            w.i64(Int64(part.counts.cacheWrite5m))
            w.i64(Int64(part.counts.cacheWrite1h))
            w.i64(Int64(part.counts.cacheRead))
        }
        w.optional(thinking) { $0.i64(Int64($1)) }
    }

    /// The first 8 digest bytes, big-endian, as the signed value SQL compares.
    static func signedPrefix(_ w: HistoryCanonicalBytes) -> Int64 {
        var value: UInt64 = 0
        for byte in w.sha256.prefix(8) { value = value << 8 | UInt64(byte) }
        return Int64(bitPattern: value)
    }
}

/// `request_occurrence.att_sig`: the last term of the attribute rank
/// `(ingest_version, finality, output_total, att_sig)` that decides which
/// observation of ONE file sets the occurrence's version, effort and
/// entrypoint. A transcript rewritten in place can state one key twice with
/// an equal rank; union semantics keep both contributions, and without this
/// term the attributes would be those of whichever arrived first.
///
/// Signed 64 bits, read and stored like `rec_sig`: the high 32 bits are
/// `rec_sig`'s, the low 32 the first 4 bytes of SHA-256 over the billing
/// content AND those three labels. When the two contents' counts differ, the
/// attributes follow the content `rec_sig` ranks higher, as the row's counts
/// do when this file holds the row's winning record (unless both `rec_sig`s
/// share their high 32 bits); when only the labels differ, `rec_sig` ties
/// (labels are deliberately not in it) and the label hash decides, except
/// for a 2^-32 tie, where the first arrival keeps its labels.
enum HistoryAttributeSignature {
    static func compute(_ o: RequestObservation) -> Int64 {
        compute(o, recSig: HistoryRecordSignature.compute(o))
    }

    /// The same, given the observation's `rec_sig`.
    static func compute(_ o: RequestObservation, recSig: Int64) -> Int64 {
        var w = HistoryCanonicalBytes()
        HistoryRecordSignature.writeBilling(&w, finality: o.finality, parts: o.parts, thinking: o.thinkingTokens)
        w.optional(o.ccVersion) { $0.string($1) }
        w.optional(o.effort) { $0.string($1) }
        w.optional(o.entrypoint) { $0.string($1) }
        let high = UInt64(bitPattern: recSig) & 0xFFFF_FFFF_0000_0000
        let low = UInt64(bitPattern: HistoryRecordSignature.signedPrefix(w)) >> 32
        return Int64(bitPattern: high | low)
    }
}

/// The record rank, higher wins:
/// `(ingest_version, finality, output_total, rec_sig, -final_key)` with
/// `final_key = final_ms ?? +inf`. Comparable in Swift exactly as the SQL row
/// value compares it (signed everywhere).
struct HistoryRecordRank: Comparable, Sendable {
    let ingestVersion: Int64
    let finality: Int64
    let outputTotal: Int64
    let recSig: Int64
    let negFinalKey: Int64

    init(ingestVersion: Int64, observation o: RequestObservation) {
        self.ingestVersion = ingestVersion
        finality = Int64(o.finality.rawValue)
        outputTotal = o.parts.reduce(0) { $0 + Int64($1.counts.output) }
        recSig = HistoryRecordSignature.compute(o)
        negFinalKey = -(o.finalMs ?? Int64.max)
    }

    static func < (a: Self, b: Self) -> Bool {
        (a.ingestVersion, a.finality, a.outputTotal, a.recSig, a.negFinalKey)
            < (b.ingestVersion, b.finality, b.outputTotal, b.recSig, b.negFinalKey)
    }
}

/// Validation BEFORE a transaction, so one bad observation never rolls back
/// the others of its transaction (up to `HistoryStore.scanChunkObservations`).
/// A rejected observation is skipped and counted.
enum HistoryObservationCheck {
    /// A count above this is not a token count (and could overflow a sum).
    static let maxCount = 1 << 48
    /// `usage.iterations` is split up to 32 elements by the scanner.
    static let maxParts = 64
    /// Version, effort and entrypoint (the scanner holds them to 64 printable bytes).
    static let maxLabelBytes = 256
    /// A model name is stored as it is when it is 1 to this many printable
    /// ASCII bytes (the scanner takes `message.model` unchecked).
    static let maxModelBytes = 128
    /// The model a part is stored under when its own name is not such a
    /// label. The part and its counts are kept: the usage report counts them
    /// whatever the model is called, so skipping the observation would leave
    /// the store short of tokens the report has.
    static let unrecognizedModel = "<unrecognized>"

    /// The observation as the store merges it, or nil when it must be skipped
    /// (a count or time out of range, an over-long attribute label). Two
    /// normalisations: a part's unusable model name becomes
    /// `unrecognizedModel`, and `finalMs` of a non-final observation is
    /// dropped (`RequestObservation` documents it as nil unless final; a stray
    /// value would otherwise enter the rank).
    static func normalized(_ o: RequestObservation) -> RequestObservation? {
        guard !o.parts.isEmpty, o.parts.count <= maxParts else { return nil }
        var parts = o.parts
        for i in parts.indices {
            let c = parts[i].counts
            for v in [c.input, c.output, c.cacheWrite5m, c.cacheWrite1h, c.cacheRead] where v < 0 || v > maxCount {
                return nil
            }
            if !isPrintableASCII(parts[i].model, maxBytes: maxModelBytes) { parts[i].model = unrecognizedModel }
        }
        if let t = o.thinkingTokens, t < 0 || t > maxCount { return nil }
        for ts in [o.firstMs, o.lastMs, o.finalMs] where !HistoryTime.isStorable(ts) { return nil }
        for label in [o.ccVersion, o.effort, o.entrypoint] where (label?.utf8.count ?? 0) > maxLabelBytes {
            return nil
        }
        let finalMs = o.finality == .final ? o.finalMs : nil
        guard parts != o.parts || finalMs != o.finalMs else { return o }
        return RequestObservation(key: o.key, parts: parts, finality: o.finality, firstMs: o.firstMs,
                                  lastMs: o.lastMs, finalMs: finalMs, thinkingTokens: o.thinkingTokens,
                                  ccVersion: o.ccVersion, effort: o.effort, entrypoint: o.entrypoint, flags: o.flags)
    }

    /// 1 to `maxBytes` bytes, every one printable ASCII (0x20-0x7E).
    static func isPrintableASCII(_ s: String, maxBytes: Int) -> Bool {
        var count = 0
        for byte in s.utf8 {
            count += 1
            guard count <= maxBytes, byte >= 0x20, byte <= 0x7E else { return false }
        }
        return count > 0
    }
}

/// NULL-aware MIN/MAX: SQLite's scalar `min(NULL, x)` is NULL; these are not.
enum HistoryNullAware {
    static func min(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a else { return b }
        guard let b else { return a }
        return Swift.min(a, b)
    }

    static func max(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a else { return b }
        guard let b else { return a }
        return Swift.max(a, b)
    }
}

/// Byte order of SQLite's BINARY collation, which `ORDER BY path` uses. Swift's
/// `String <` compares canonically equivalent strings as equal, which two
/// different paths in a UNIQUE column are not.
func historyBinaryLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// The owner rule applied to the FILE of an event copy: the copy in the file
/// that minimises (birth IS NULL, birth ?? +inf, path in byte order) owns the
/// row, the same order the request owner uses after its `last_ms IS NULL`
/// term. A total order on files (paths are unique), so the stored row is a
/// function of the set of copies, never of their arrival order.
struct HistoryFileRank: Comparable {
    let birthMs: Int64?
    let path: String

    static func < (a: Self, b: Self) -> Bool {
        if (a.birthMs == nil) != (b.birthMs == nil) { return a.birthMs != nil }
        let x = a.birthMs ?? .max, y = b.birthMs ?? .max
        if x != y { return x < y }
        return historyBinaryLess(a.path, b.path)
    }

    static func == (a: Self, b: Self) -> Bool { a.birthMs == b.birthMs && a.path.utf8.elementsEqual(b.path.utf8) }
}

/// `acct_day`: the Gregorian calendar day (YYYYMMDD) of a time in the
/// accounting zone. Never `Calendar.current` (a Japanese-calendar year would
/// corrupt YYYYMMDD). Caches the last day's bounds, so a run of nearby times
/// costs one calendar computation; the cache must answer exactly what an
/// uncached computation would, or the day of a key would depend on which
/// other times the same transaction looked up first.
struct HistoryAccountingDays {
    let timeZone: TimeZone
    private let calendar: Calendar
    private var lo = Int64.max
    private var hi = Int64.min
    private var cached: Int64 = 0

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    mutating func day(_ ms: Int64?) -> Int64? {
        guard let ms else { return nil }
        if ms >= lo && ms < hi { return cached }
        let date = HistoryTime.date(ms: ms)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        let value = Int64(y) * 10_000 + Int64(m) * 100 + Int64(d)
        lo = .max
        hi = .min
        // The day's own interval, not startOfDay + 1 day: where DST starts at
        // midnight the day begins at 01:00, and a day later is 01:00 of the
        // next day, which would serve that day's first hour as this one. A day
        // whose UTC offset differs at its two ends is not cached at all: a
        // fall-back at (or just after) midnight repeats wall times of the
        // previous day, so its instants need not be one run of one date.
        if let interval = calendar.dateInterval(of: .day, for: date),
           timeZone.secondsFromGMT(for: interval.start)
            == timeZone.secondsFromGMT(for: interval.end.addingTimeInterval(-0.001)) {
            let start = Int64((interval.start.timeIntervalSince1970 * 1000).rounded(.up))
            let end = Int64((interval.end.timeIntervalSince1970 * 1000).rounded(.up))
            if ms >= start && ms < end {
                lo = start
                hi = end
            }
        }
        cached = value
        return value
    }
}

/// Test-only switches that turn ONE merge mechanism off, so the property test
/// can prove each is load-bearing (negative controls). Always empty in the app.
struct HistoryMergeMutations: OptionSet, Sendable {
    let rawValue: Int
    /// Skip step 3: rows of a beaten record with more parts survive.
    static let noStaleCleanup = HistoryMergeMutations(rawValue: 1 << 0)
    /// Rank without `rec_sig`: equal-rank records of different content tie, first wins.
    static let noRecSigTieBreak = HistoryMergeMutations(rawValue: 1 << 1)
    /// Rank without `-final_key`: copies with different `final_ms` tie, first wins.
    static let noFinalMsTieBreak = HistoryMergeMutations(rawValue: 1 << 2)
    /// New rows INSERTed with the observing file's values as placeholders,
    /// and step 4 skipped for the whole key when the idx-0 row already
    /// matches. (The store inserts the final derived values and updates per
    /// row; with placeholders, only the per-row UPDATE keeps the result
    /// order-independent.)
    static let keyLevelDerivedSkip = HistoryMergeMutations(rawValue: 1 << 3)
    /// Event copies keep the first arrival (`ON CONFLICT DO NOTHING`) instead
    /// of the owner rule; cost states keep the first `after_ts_ms` instead of
    /// the MAX.
    static let firstArrivalEvents = HistoryMergeMutations(rawValue: 1 << 4)
    /// Attribute rank without `att_sig`: observations of one file with an equal
    /// (version, finality, output) tie, the first one's attributes win.
    static let noAttSigTieBreak = HistoryMergeMutations(rawValue: 1 << 5)
}
