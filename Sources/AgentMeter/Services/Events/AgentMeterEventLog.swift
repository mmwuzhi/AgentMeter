import Foundation

// `events.jsonl` is an operation log: one JSON object per line, appended as
// things change, replayed in order on load.
//
//   {"event":{...},"op":"event","v":1}                       a new event (or, after a
//                                                           compaction, an event whole)
//   {"delivery":{...},"id":"...","op":"delivery","v":1}     its notification was decided
//   {"at":1792458306123,"ids":["...",...],"op":"read","v":1} these were read
//   {"op":"unreadOverflow","unreadOverflow":{...},"v":1}    unread events dropped at
//                                                           the cap (running total)
//
// Replay rules, which make applying a line twice harmless (two instances, or
// a writer re-reading its own lines): the first `event` line of an id wins;
// a `delivery` line replaces the delivery only when it is further along
// (`AgentMeterEventDelivery.State.rank`); a `read` line sets `readAt` only on
// an event still unread; the `unreadOverflow` line with the higher total
// wins. A line that does not decode (a torn tail, a
// newer build's change of a known field) is skipped. A line of a newer
// format (`v`) is applied when it decodes, and its presence stops this build
// from ever rewriting the file (`AgentMeterEventLogState.newestFormatVersion`),
// so a downgrade cannot drop what it cannot read. Adding a field or a case to
// anything written here therefore bumps `formatVersion`.

/// One line of the log.
enum AgentMeterEventLogEntry: Sendable, Equatable {
    case event(AgentMeterEvent)
    case delivery(id: String, delivery: AgentMeterEventDelivery)
    case read(ids: [String], at: Date)
    case unreadOverflow(AgentMeterUnreadOverflow)
}

/// Unread events the store dropped because unread events alone filled the
/// cap (`AgentMeterEventStore.Limits.maximumEvents`). The only way an unread
/// event ever leaves the store, and never silent: this running total is kept
/// in the log, survives compactions, and is what a view shows as "N older
/// unread events were removed".
struct AgentMeterUnreadOverflow: Hashable, Sendable {
    /// Unread events dropped so far, in every run.
    var count: Int
    /// The newest discovery time among them: an unread event discovered at
    /// or before this may be one of them.
    var throughDiscoveredAt: Date
    /// When the latest of them were dropped.
    var lastDroppedAt: Date

    init(count: Int, throughDiscoveredAt: Date, lastDroppedAt: Date) {
        self.count = count
        self.throughDiscoveredAt = AgentMeterEvent.wholeMilliseconds(throughDiscoveredAt)
        self.lastDroppedAt = AgentMeterEvent.wholeMilliseconds(lastDroppedAt)
    }

    /// This total plus `dropped`, dropped at `now`.
    func adding(_ dropped: [AgentMeterEvent], at now: Date) -> Self {
        let newest = dropped.map(\.discoveredAt).max() ?? throughDiscoveredAt
        return Self(count: count + dropped.count, throughDiscoveredAt: max(throughDiscoveredAt, newest), lastDroppedAt: now)
    }
}

extension AgentMeterUnreadOverflow: Codable {
    private enum CodingKeys: String, CodingKey {
        case count, throughDiscoveredAt, lastDroppedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(count: try c.decode(Int.self, forKey: .count),
                  throughDiscoveredAt: HistoryTime.date(ms: try c.decode(Int64.self, forKey: .throughDiscoveredAt)),
                  lastDroppedAt: HistoryTime.date(ms: try c.decode(Int64.self, forKey: .lastDroppedAt)))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encode(HistoryTime.ms(throughDiscoveredAt), forKey: .throughDiscoveredAt)
        try c.encode(HistoryTime.ms(lastDroppedAt), forKey: .lastDroppedAt)
    }
}

enum AgentMeterEventLogCodec {
    static let formatVersion = 1

    private struct Line: Codable {
        var v: Int
        var op: String
        var event: AgentMeterEvent?
        var id: String?
        var delivery: AgentMeterEventDelivery?
        var ids: [String]?
        var at: Int64?
        var unreadOverflow: AgentMeterUnreadOverflow?
    }

    /// Only the version, for a line whose body does not decode.
    private struct Header: Decodable {
        var v: Int
    }

    enum Decoded: Equatable {
        case entry(AgentMeterEventLogEntry, version: Int)
        /// Well-formed but not applicable here (an operation this build does
        /// not know); the version still counts.
        case unknown(version: Int)
        case unreadable
    }

    /// The line with its terminating newline. The encoder never writes a raw
    /// newline inside a value, so one entry is always one line.
    static func encode(_ entry: AgentMeterEventLogEntry) throws -> Data {
        let line: Line
        switch entry {
        case let .event(event):
            line = Line(v: formatVersion, op: "event", event: event)
        case let .delivery(id, delivery):
            line = Line(v: formatVersion, op: "delivery", id: id, delivery: delivery)
        case let .read(ids, at):
            line = Line(v: formatVersion, op: "read", ids: ids, at: HistoryTime.ms(at))
        case let .unreadOverflow(overflow):
            line = Line(v: formatVersion, op: "unreadOverflow", unreadOverflow: overflow)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(line)
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data, using decoder: JSONDecoder) -> Decoded {
        guard let parsed = try? decoder.decode(Line.self, from: line) else {
            if let header = try? decoder.decode(Header.self, from: line) { return .unknown(version: header.v) }
            return .unreadable
        }
        switch parsed.op {
        case "event":
            guard let event = parsed.event else { return .unknown(version: parsed.v) }
            return .entry(.event(event), version: parsed.v)
        case "delivery":
            guard let id = parsed.id, let delivery = parsed.delivery else { return .unknown(version: parsed.v) }
            return .entry(.delivery(id: id, delivery: delivery), version: parsed.v)
        case "read":
            guard let ids = parsed.ids, let at = parsed.at else { return .unknown(version: parsed.v) }
            return .entry(.read(ids: ids, at: HistoryTime.date(ms: at)), version: parsed.v)
        case "unreadOverflow":
            guard let overflow = parsed.unreadOverflow else { return .unknown(version: parsed.v) }
            return .entry(.unreadOverflow(overflow), version: parsed.v)
        default:
            return .unknown(version: parsed.v)
        }
    }
}

/// The events a replay of the log arrives at, plus what the store needs to
/// decide on a compaction. Pure: no I/O, so tests drive it line by line.
struct AgentMeterEventLogState: Sendable {
    private(set) var events: [String: AgentMeterEvent] = [:]
    /// Lines of the file as this state knows it, readable or not. Each live
    /// event takes one; the rest are superseded and go at the next compaction.
    private(set) var lineCount = 0
    private(set) var unreadableLines = 0
    /// The highest `v` seen. Above `AgentMeterEventLogCodec.formatVersion`, a
    /// newer build wrote here and the file must not be rewritten.
    private(set) var newestFormatVersion = 0
    private(set) var unreadOverflow: AgentMeterUnreadOverflow?

    /// Lines a rewrite would write: one per live event, one for the overflow.
    var liveLines: Int { events.count + (unreadOverflow == nil ? 0 : 1) }
    var supersededLines: Int { max(0, lineCount - liveLines) }
    var hasNewerFormat: Bool { newestFormatVersion > AgentMeterEventLogCodec.formatVersion }

    /// Applies every complete line of `data` and returns how many bytes that
    /// was: up to and including the last newline. A torn last line stays
    /// unread until a later write completes it.
    @discardableResult
    mutating func consume(_ data: Data) -> Int {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return 0 }
        let decoder = JSONDecoder()
        for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) {
            guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { continue }
            lineCount += 1
            switch AgentMeterEventLogCodec.decode(Data(line), using: decoder) {
            case let .entry(entry, version):
                newestFormatVersion = max(newestFormatVersion, version)
                apply(entry)
            case let .unknown(version):
                newestFormatVersion = max(newestFormatVersion, version)
            case .unreadable:
                unreadableLines += 1
            }
        }
        return lastNewline - data.startIndex + 1
    }

    /// Applies one entry as if its line had been read. Returns whether
    /// anything changed.
    @discardableResult
    mutating func apply(_ entry: AgentMeterEventLogEntry) -> Bool {
        switch entry {
        case let .event(event):
            guard events[event.id] == nil else { return false }
            events[event.id] = event
            return true
        case let .delivery(id, delivery):
            guard var event = events[id], event.delivery.isSuperseded(by: delivery) else { return false }
            event.delivery = delivery
            events[id] = event
            return true
        case let .read(ids, at):
            var changed = false
            for id in ids {
                guard var event = events[id], event.readAt == nil else { continue }
                event.readAt = AgentMeterEvent.wholeMilliseconds(at)
                events[id] = event
                changed = true
            }
            return changed
        case let .unreadOverflow(overflow):
            guard overflow.count > (unreadOverflow?.count ?? 0) else { return false }
            unreadOverflow = overflow
            return true
        }
    }

    /// Counts lines written for entries already applied with `apply`.
    mutating func noteLinesWritten(_ count: Int) {
        lineCount += count
    }

    /// Takes over an event the file does not have (yet), without a line.
    mutating func carry(_ event: AgentMeterEvent) {
        if events[event.id] == nil { events[event.id] = event }
    }

    mutating func remove(_ ids: some Sequence<String>) {
        for id in ids { events.removeValue(forKey: id) }
    }

    /// After the file was rewritten as one line per live event, plus the
    /// overflow line.
    mutating func didRewrite() {
        lineCount = liveLines
        unreadableLines = 0
        newestFormatVersion = liveLines == 0 ? 0 : AgentMeterEventLogCodec.formatVersion
    }

    struct Pruning: Equatable {
        var ids: [String] = []
        /// The unread events among `ids`, oldest first: only when unread
        /// events alone exceed the cap, and only as many as it takes.
        var unread: [AgentMeterEvent] = []

        var isEmpty: Bool { ids.isEmpty }
    }

    /// What falls outside the limits at `now`. Time removes read events only:
    /// a read event older than `retention` goes, an unread one stays however
    /// old it is. Past `maximumEvents`, the oldest read events go first; only
    /// when unread events alone exceed it do the oldest unread ones go, and
    /// those are counted in `unreadOverflow`.
    ///
    /// An unread event its producer recorded for the history only (its
    /// delivery suppressed with one of `historyOnlyReasons`) waits for no
    /// one: it is kept and dropped like a read event, and never counted as
    /// overflow. It stays unread; nothing invents a time the user read it.
    func pruning(now: Date, retention: TimeInterval, maximumEvents: Int,
                 historyOnlyReasons: Set<String> = []) -> Pruning {
        let horizon = now.addingTimeInterval(-retention)
        var drop: [String] = []
        var read: [AgentMeterEvent] = []
        var unread: [AgentMeterEvent] = []
        for event in events.values {
            if event.isUnread, !Self.isHistoryOnly(event, reasons: historyOnlyReasons) {
                unread.append(event)
            } else if event.occurredAt < horizon {
                drop.append(event.id)
            } else {
                read.append(event)
            }
        }
        var excess = read.count + unread.count - max(0, maximumEvents)
        guard excess > 0 else { return Pruning(ids: drop) }
        read.sort(by: Self.oldestFirst)
        let oldestRead = read.prefix(excess)
        drop += oldestRead.map(\.id)
        excess -= oldestRead.count
        guard excess > 0 else { return Pruning(ids: drop) }
        unread.sort(by: Self.oldestFirst)
        let oldestUnread = Array(unread.prefix(excess))
        return Pruning(ids: drop + oldestUnread.map(\.id), unread: oldestUnread)
    }

    static func isHistoryOnly(_ event: AgentMeterEvent, reasons: Set<String>) -> Bool {
        event.delivery.state == .suppressed && reasons.contains(event.delivery.reason ?? "")
    }

    /// Discovery order, then occurrence, then id: total, so a rewrite of the
    /// same events is the same file.
    static func oldestFirst(_ a: AgentMeterEvent, _ b: AgentMeterEvent) -> Bool {
        if a.discoveredAt != b.discoveredAt { return a.discoveredAt < b.discoveredAt }
        if a.occurredAt != b.occurredAt { return a.occurredAt < b.occurredAt }
        return a.id < b.id
    }
}
