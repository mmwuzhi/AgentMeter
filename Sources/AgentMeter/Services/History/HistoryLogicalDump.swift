import CryptoKit
import Foundation

/// The LOGICAL content of the request, occurrence, file, session and event
/// tables, joined back to logical values (key hex, path, session id, label
/// strings). No surrogate id, rowid or arrival-dependent value (ingest time,
/// scan ids, watermarks) is in it, so two databases that ingested the same set
/// of contributions in any order compare equal (order independence). Quota samples,
/// reset events and grants are arrival-stream data and are not part of it.
struct HistoryLogicalDump: Equatable, Sendable {
    struct File: Equatable, Sendable {
        var path: String
        var fileClass: Int64
        var sessionID: String
        var agentID: String?
        var runID: String?
        var birthMs: Int64?
    }

    struct Session: Equatable, Sendable {
        var sessionID: String
        var firstCwd: String?
        var firstCwdMs: Int64?
        var entrypoint: String?
        var ccVersion: String?
    }

    struct Request: Equatable, Sendable {
        var keyHex: String
        var idx: Int64
        var model: String
        var input: Int64, output: Int64, cacheWrite5m: Int64, cacheWrite1h: Int64, cacheRead: Int64
        var thinking: Int64?
        var finality: Int64
        var parts: Int64
        var outputTotal: Int64
        var recSig: Int64
        var ingestVersion: Int64
        var finalMs: Int64?
        var firstSeenMs: Int64?
        var lastSeenMs: Int64?
        var acctDay: Int64?
        var ownerPath: String
        var sessionID: String
        var fileClass: Int64
        var ccVersion: String?
        var effort: String?
        var entrypoint: String?
        var flags: Int64
    }

    struct Occurrence: Equatable, Sendable {
        var keyHex: String
        var path: String
        var firstMs: Int64?
        var lastMs: Int64?
        var ingestVersion: Int64
        var attFin: Int64
        var attOut: Int64
        /// Content-derived (`HistoryAttributeSignature`), so it is part of the
        /// logical content: it shows which observation set the attributes.
        var attSig: Int64
        var ccVersion: String?
        var effort: String?
        var entrypoint: String?
        var flags: Int64
    }

    var files: [File] = []
    var sessions: [Session] = []
    var requests: [Request] = []
    var occurrences: [Occurrence] = []
    /// One canonical line per event row (limit_event, usage_report_sample,
    /// usage_report_limit, cost_state_sample, cost_state_model, compact_event),
    /// prefixed with the table, in byte order. Limit, report and compaction
    /// lines end with the path of the file that owns the row.
    var events: [String] = []

    /// The canonical text: one line per row, tables in a fixed order.
    var text: String {
        var lines: [String] = []
        for f in files { lines.append(Self.line("F", [.s(f.path), .i(f.fileClass), .s(f.sessionID), .s(f.agentID), .s(f.runID), .i(f.birthMs)])) }
        for s in sessions {
            lines.append(Self.line("S", [.s(s.sessionID), .s(s.firstCwd), .i(s.firstCwdMs), .s(s.entrypoint), .s(s.ccVersion)]))
        }
        for r in requests {
            lines.append(Self.line("R", [
                .s(r.keyHex), .i(r.idx), .s(r.model), .i(r.input), .i(r.output), .i(r.cacheWrite5m), .i(r.cacheWrite1h),
                .i(r.cacheRead), .i(r.thinking), .i(r.finality), .i(r.parts), .i(r.outputTotal), .i(r.recSig),
                .i(r.ingestVersion), .i(r.finalMs), .i(r.firstSeenMs), .i(r.lastSeenMs), .i(r.acctDay), .s(r.ownerPath),
                .s(r.sessionID), .i(r.fileClass), .s(r.ccVersion), .s(r.effort), .s(r.entrypoint), .i(r.flags),
            ]))
        }
        for o in occurrences {
            lines.append(Self.line("O", [
                .s(o.keyHex), .s(o.path), .i(o.firstMs), .i(o.lastMs), .i(o.ingestVersion), .i(o.attFin), .i(o.attOut),
                .i(o.attSig), .s(o.ccVersion), .s(o.effort), .s(o.entrypoint), .i(o.flags),
            ]))
        }
        lines.append(contentsOf: events)
        return lines.joined(separator: "\n") + "\n"
    }

    var data: Data { Data(text.utf8) }

    /// The order-independence oracle: equal for every schedule that ingested
    /// the same contributions.
    var sha256Hex: String { HistoryHex.encode(SHA256.hash(data: data)) }

    enum Field {
        case i(Int64?)
        case d(Double?)
        case s(String?)
    }

    /// `~` is NULL; text is quoted with `\` escapes, so no value can forge a separator.
    static func line(_ table: String, _ fields: [Field]) -> String {
        var out = table
        for f in fields {
            out += "|"
            switch f {
            case let .i(v): out += v.map(String.init) ?? "~"
            case let .d(v): out += v.map { "d" + String($0.bitPattern, radix: 16) } ?? "~"
            case let .s(v):
                guard let v else { out += "~"; continue }
                var escaped = "\""
                for ch in v.unicodeScalars {
                    switch ch {
                    case "\\": escaped += "\\\\"
                    case "\"": escaped += "\\\""
                    case "\n": escaped += "\\n"
                    case "\r": escaped += "\\r"
                    default: escaped.unicodeScalars.append(ch)
                    }
                }
                out += escaped + "\""
            }
        }
        return out
    }
}
