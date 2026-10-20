import Foundation

// The value types a scan, the quota refresh and the history store exchange.
// Everything here is plain `Sendable` data: nothing holds a connection, a
// file handle or a reference to the parse cache, so a batch can be built on
// the scan's thread, handed to `HistoryStore` and applied whenever its actor
// gets to it. Times are Unix milliseconds in UTC; a `nil` time is one the
// transcript did not state (never a fallback such as `Date()`).

enum HistoryTime {
    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// 10^15 ms (about 31,700 years either side of 1970), the scanner's own
    /// bound (`ClaudeJSONLScanner.epochMs`). The store keeps no time at or
    /// beyond it, so rounding a stored time (`HistoryEpoch.seconds`) or
    /// negating one (the rank's `-final_ms`) can never overflow.
    static let maxMagnitudeMs: Int64 = 1_000_000_000_000_000

    /// Whether the store may keep `ms`; nil ("not stated") always may.
    static func isStorable(_ ms: Int64?) -> Bool {
        guard let ms else { return true }
        return ms > -maxMagnitudeMs && ms < maxMagnitudeMs
    }
}

// MARK: - Where a record was read from

/// What kind of Claude Code transcript a record was read from. Decided by the
/// path alone, the same way `ActiveAgentService` finds a session's agents.
enum HistoryFileClass: Int, Sendable, Equatable, CaseIterable {
    /// `<project>/<sessionId>.jsonl`
    case main = 0
    /// `<project>/<sessionId>/subagents/agent-<id>.jsonl`
    case subagent = 1
    /// `<project>/<sessionId>/subagents/workflows/<runID>/agent-<id>.jsonl`
    case workflow = 2
    /// Anything else the scanner lists, e.g. a workflow's `journal.jsonl`.
    case other = 3
}

/// A transcript as the history identifies it. Every record's `sessionId` equals the main file's stem (or the parent
/// session directory's name for agent files), and `agentId` equals the
/// `agent-<id>` of the path, so nothing needs to be read from the records.
struct HistorySourceFile: Sendable, Equatable {
    let path: String
    let fileClass: HistoryFileClass
    let sessionID: String
    let agentID: String?
    let runID: String?
    /// `st_birthtime` in Unix ms. A batch never carries it (the scan does not
    /// stat); the store reads it (`HistoryDatabaseConfiguration.birthTime`)
    /// once, when it first registers the path, and never rewrites it, so which
    /// copy of a forked request owns it stays the same on every scan. A
    /// rebuilt or deleted database registers every path anew and reads the
    /// birth again. nil when unavailable; a nil birth ranks after every known
    /// one (`HistoryFileRank`).
    let birthMs: Int64?

    /// Class, session, agent and run read off the END of the path, in exactly
    /// the shapes the scanner lists (the resolved store path above them is not
    /// reliable: a project directory can be called anything):
    ///   `…/<session>.jsonl`                                            main
    ///   `…/<session>/subagents/agent-<id>.jsonl`                       subagent
    ///   `…/<session>/subagents/workflows/<runID>/agent-<id>.jsonl`     workflow
    /// Anything else (a workflow's `journal.jsonl`, a nested spawn, a path
    /// with more than one `subagents` component) is `.other`, never guessed.
    static func parse(path: String, birthMs: Int64? = nil) -> HistorySourceFile {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let name = parts.last ?? path
        let stem = name.hasSuffix(".jsonl") ? String(name.dropLast(".jsonl".count)) : name
        let agentPrefix = "agent-"
        let agent: String? = stem.hasPrefix(agentPrefix) && stem.count > agentPrefix.count
            ? String(stem.dropFirst(agentPrefix.count)) : nil
        let subagentDirs = parts.filter { $0 == "subagents" }.count
        func other(session: String) -> HistorySourceFile {
            HistorySourceFile(path: path, fileClass: .other, sessionID: session,
                              agentID: nil, runID: nil, birthMs: birthMs)
        }
        if parts.count >= 3, parts[parts.count - 2] == "subagents", subagentDirs == 1 {
            let session = parts[parts.count - 3]
            guard let agent else { return other(session: session) }
            return HistorySourceFile(path: path, fileClass: .subagent, sessionID: session,
                                     agentID: agent, runID: nil, birthMs: birthMs)
        }
        if parts.count >= 5, parts[parts.count - 3] == "workflows", parts[parts.count - 4] == "subagents",
           subagentDirs == 1 {
            let session = parts[parts.count - 5]
            guard let agent else { return other(session: session) }
            return HistorySourceFile(path: path, fileClass: .workflow, sessionID: session,
                                     agentID: agent, runID: parts[parts.count - 2], birthMs: birthMs)
        }
        if subagentDirs > 0 { return other(session: stem) }
        return HistorySourceFile(path: path, fileClass: .main, sessionID: stem,
                                 agentID: nil, runID: nil, birthMs: birthMs)
    }
}

/// What the history has accounted for of one transcript: the log file's
/// fingerprint and the parsed boundary the usage cache stood at. Two equal
/// watermarks mean the rows of this file are already in the store. Written in
/// the transaction of the file's last chunk, so rows never land without it.
/// It may move to FEWER parsed bytes (a transcript truncated and rewritten in
/// place): the store ingests the new content whole and keeps what the old
/// content contributed (union semantics: the store is append-only history).
struct HistoryFileWatermark: Sendable, Equatable {
    var fileID: UInt64?
    var volumeID: UInt64?
    var size: Int64
    var modifiedAt: TimeInterval
    var parsedBytes: Int64
    var boundaryDigest: Data
    /// `ClaudeUsageCacheStore.formatVersion` that produced the rows, so a
    /// parser change can re-ingest what an older parser stored.
    var parserVersion: Int
}

// MARK: - Requests

/// Facts about the request's records, OR-folded over EVERY record of the key
/// in a file (and over every file in the store): monotone, so the fold order
/// can never matter. They are not part of the record rank (`rec_sig`).
struct RequestFlags: OptionSet, Sendable, Equatable {
    let rawValue: UInt8
    /// `usage.speed == "fast"` on some record.
    static let fast = RequestFlags(rawValue: 1 << 0)
    /// `isAbortedMidStream` on some record: the user interrupted the request.
    static let abortedMidStream = RequestFlags(rawValue: 1 << 1)
}

/// One iteration of a request: the model it ran on and its five counts. An
/// ordinary request has one part; a request that fell back to another model
/// (`usage.iterations` with two elements) has one per attempt, in order.
struct RequestPart: Sendable, Equatable {
    var model: String
    var counts: TokenCounts
}

/// What one transcript file says about one request (`message.id|requestId`):
/// the record that stands for the request in that file (`KeyedUsage.outranks`)
/// plus the time span of all of the request's records there. A pure function
/// of the file's committed lines: a resumed parse and one from the top give
/// the same observation.
struct RequestObservation: Sendable, Equatable {
    let key: DedupKey
    /// ≥ 1 element. A zeroed replay has a single all-zero part.
    let parts: [RequestPart]
    let finality: UsageFinality
    /// MIN timestamp over every record of the key in this file, zeroed replays
    /// and records that did not count included.
    let firstMs: Int64?
    /// MAX timestamp over the key's non-zeroed records in this file, records
    /// that did not count included.
    let lastMs: Int64?
    /// Timestamp of the standing record itself; nil unless `finality == .final`.
    let finalMs: Int64?
    /// `usage.output_tokens_details.thinking_tokens` of the standing record, a
    /// subset of the last part's output; nil when not stated and for a zeroed replay.
    let thinkingTokens: Int?
    /// `version`, `effort`, `entrypoint` of the standing record itself (never
    /// of a replay that did not count).
    let ccVersion: String?
    let effort: String?
    let entrypoint: String?
    /// OR over every record of the key in the file (`RequestFlags`).
    let flags: RequestFlags
}

// MARK: - Raw events read from transcripts

/// A `<synthetic>` 429 record's `quotaLimits` (or, from Claude Code 2.1.299,
/// `apiErrorParams.rate_limit_info`): the window rejected a request at `tsMs`
/// and says when it resets. The only transcript-side anchor of "window hit
/// 100% at T". Deduplicated in a file by request id (uuid when there is
/// none); stored under `HistoryEventCheck.limitKey` (the request id, else
/// `uuid:<uuid>`), because a fork re-stamps the uuid but never the request id.
struct LimitEventObservation: Sendable, Equatable {
    let uuid: String
    let requestID: String?
    let tsMs: Int64
    /// `rateLimitType` verbatim (`five_hour` today).
    let windowID: String
    let status: String?
    /// `resetsAt` is epoch **seconds** in the record; stored here as ms.
    let resetsAtMs: Int64?
    let overageStatus: String?
    let overageDisabledReason: String?
    let isUsingOverage: Bool?
    let fallbackAvailable: Bool?
    /// Exactly `"quotaLimits"` or `"rate_limit_info"`: the key the figures were
    /// read from. `quotaLimits` wins when a record carries both.
    let source: String
    let apiError: String?
    let ccVersion: String?
}

/// One line of a `/usage` report's `rate_limits.limits[]`.
struct UsageReportLimit: Sendable, Equatable {
    let index: Int
    /// `session`, `weekly_all`, `weekly_scoped`, verbatim.
    let kind: String
    let group: String?
    let percent: Double?
    let severity: String?
    let isActive: Bool?
    let resetsAtMs: Int64?
    /// `scope.model.display_name`.
    let scopeModel: String?
    /// The id the same window has in `quota_sample`: `five_hour` for `session`,
    /// `seven_day` for `weekly_all`, `QuotaWindowID.scopedWeekly` for
    /// `weekly_scoped`; nil for an unknown kind or a scoped limit without a name
    /// (`ClaudeOAuthFetcher` skips those too).
    var windowID: String? {
        switch kind {
        case "session": return "five_hour"
        case "weekly_all": return "seven_day"
        case "weekly_scoped": return QuotaWindowID.scopedWeekly(displayName: scopeModel)
        default: return nil
        }
    }
}

/// A `system/local_command` record that carries `usageReport`: the user ran
/// `/usage` at `tsMs`. A third source of quota readings, next to OAuth and
/// the CLI scrape; never merged into OAuth labels.
struct UsageReportObservation: Sendable, Equatable {
    let uuid: String
    let tsMs: Int64
    let ccVersion: String?
    /// False when `rate_limits` or its `limits` is null: still proof the user ran `/usage`.
    let hasLimits: Bool
    let extraEnabled: Bool?
    let extraMonthlyLimit: Int?
    let extraUsedCredits: Int?
    let limits: [UsageReportLimit]
}

struct CostStateModel: Sendable, Equatable {
    /// Claude Code's own key, verbatim; a `[1m]` suffix marks 1M-context use
    /// (visible nowhere else).
    let modelKey: String
    let input: Int
    let output: Int
    let cacheRead: Int
    /// One total: the cost state has no 5m/1h split.
    let cacheCreation: Int
    let thinking: Int
    let webSearch: Int
    let costUSD: Double
}

/// A `cost-state` record: Claude Code's own cumulative per-session totals,
/// appended once per process exit and restored on resume. A snapshot, never
/// summed. Deduplicated in a file by `(startTimeMs, totalDurationMs)`; stored
/// per `(sessionID, startTimeMs, totalDurationMs)`, the first copy's totals
/// kept (every copy carries the same ones).
struct CostStateObservation: Sendable, Equatable {
    /// The RECORD's `sessionId` (a cost state is restored on resume), not the
    /// session the path names.
    let sessionID: String
    let startTimeMs: Int64
    let totalDurationMs: Int64
    let totalAPIDurationMs: Int64?
    let totalCostUSD: Double
    let hasUnknownModelCost: Bool
    /// The record carries no timestamp. This is the running MAX of the
    /// timestamps of the usage records parsed before the line in the same
    /// file (every record with `message.usage`, `<synthetic>` 429s, zeroed
    /// replays and records that did not count included) — NOT the last one in
    /// file order, which differs on 15 of 356 real lines. A lower bound of when
    /// the state was written; nil when no usage record came first. Copies in
    /// several files merge as a NULL-aware MAX.
    let afterTsMs: Int64?
    let models: [CostStateModel]
}

/// A `system/compact_boundary` record: the conversation was compacted. The
/// attribution phase only needs "this session has (no) compaction" and when.
/// In-file replays (same uuid) count once; stored under
/// `HistoryEventCheck.compactKey` (time, trigger, token counts), since a
/// fork's copy gets a new uuid.
struct CompactEventObservation: Sendable, Equatable {
    let uuid: String
    let tsMs: Int64
    /// `compactMetadata.trigger` (`manual` / `auto`).
    let trigger: String?
    let preTokens: Int?
    let postTokens: Int?
}

/// The small, whole-file extras of one transcript, at most
/// `ClaudeUsageCacheStore.maxEventsPerKind` per kind. Always sent whole: a
/// file has at most a few dozen, and every row is keyed idempotently.
///
/// Event owner rule: one event can arrive from several files (a fork copies
/// it). A limit event, `/usage` report or compaction row belongs to the copy
/// in the file that ranks first by `HistoryFileRank` (earliest birth, a nil
/// birth last, then path bytes), the same rule as a request's owner; a copy
/// replaces the stored row only from a strictly better-ranked file. So the
/// stored row never depends on which file arrived first. Rows are never
/// deleted when a file shrinks, is rewritten or disappears (union semantics).
struct HistoryFileEvents: Sendable, Equatable {
    var limitEvents: [LimitEventObservation] = []
    var usageReports: [UsageReportObservation] = []
    var costStates: [CostStateObservation] = []
    var compactEvents: [CompactEventObservation] = []
    /// `cwd`, `entrypoint` and `version` of the file's earliest FIRST-OF-KEY
    /// usage record that has a timestamp (ties: the smaller cwd in byte order,
    /// a record without a cwd losing), with that timestamp. Replays of older
    /// requests are not first of their key and never take part (178,194 real
    /// non-first records carry another cwd). `firstCwd` can be nil while
    /// `firstCwdMs` is set: that record stated no cwd, and the file then
    /// contributes nothing to its session row. Used for the session row of a
    /// MAIN file only (agent files in worktrees can have another cwd); the
    /// store keeps the earliest over every main-file contribution (ties: cwd,
    /// then entrypoint, then version, in byte order).
    var firstCwd: String?
    var firstCwdMs: Int64?
    var firstEntrypoint: String?
    var firstCcVersion: String?

    static let empty = HistoryFileEvents()
}

// MARK: - One scan's hand-off

struct HistoryFileBatch: Sendable {
    /// What changed since an earlier ingest of the same file: every key whose
    /// observation differs from the base's in ANY field (new keys, records that
    /// replaced one, records whose time span or flags grew — compared as
    /// `KeyedUsage` values, never by `ParseState.add`'s "counted" answer). Only
    /// a resumed parse has one. The store applies it only when its stored
    /// watermark IS this base (file id, parsed bytes, boundary digest, parser
    /// version); otherwise it ingests `allRequests()`. Events are always whole.
    struct Delta: Sendable {
        let basedOnParsedBytes: Int64
        let basedOnFileID: UInt64?
        let basedOnBoundaryDigest: Data
        let basedOnParserVersion: Int
        let requests: [RequestObservation]
    }

    /// The transcript's path; class, session, agent and run are parsed from it
    /// by the store (`HistorySourceFile.parse`), which also reads its birth time.
    let path: String
    /// The scan that produced the batch (`LogFileParseCache` ticket): the store
    /// drops a batch older than one it already applied (or found already
    /// applied) for the same path. The tickets it compares against live in
    /// memory only and reset on every open of the database, so after a
    /// restart any batch is accepted; union semantics make that harmless.
    let scan: UInt64
    let watermark: HistoryFileWatermark
    /// nil when the file was parsed from the top (cold start, rewritten file) or
    /// the cache answered from memory or disk.
    let delta: Delta?
    /// Every request of the committed state. Built on demand from the parse
    /// result the scan already holds (never by reading the transcript again):
    /// only a first ingest, a rebuilt database or a missed delta needs it, and
    /// an unchanged file needs nothing.
    let allRequests: @Sendable () -> [RequestObservation]
    let events: HistoryFileEvents
}

/// One usage scan's batches: one per file the scan listed whose read did not
/// fail, in path order. Handed over once, after the scan's last file, and
/// applied in pieces of at most `HistoryStore.scanChunkObservations`
/// observations per transaction. A scan that wrote a file, and every
/// complete-history scan, records its coverage (an `ingest_scan` row,
/// `meta.latest_scan_ms`, and `meta.complete_scan_ms` for a complete scan none
/// of whose files failed). A windowed scan that wrote no file writes nothing,
/// except `meta.latest_scan_ms` once the stored value is
/// `HistoryDatabase.latestScanGranularityMs` (15 minutes) old.
struct HistoryScanBatch: Sendable {
    let ticket: UInt64
    let startedMs: Int64
    /// The scan read every log file (the 6-hourly complete scan), not the recent-file window.
    let isCompleteHistory: Bool
    let files: [HistoryFileBatch]
    /// A session row's read (`ClaudeJSONLScanner.fileUsages`), not a scan.
    /// It covers only the few files a row reads, so it records no scan
    /// coverage, and each of its files applies only as a delta on exactly
    /// the watermark the store holds: anything else (no delta, or a delta on
    /// a state an in-flight scan has not submitted yet) is skipped without
    /// noting its ticket, and the next scan's batch brings that file instead
    /// of this read re-applying it whole.
    var isSessionRead = false
}

// MARK: - Quota readings

enum QuotaSampleSource: String, Sendable, Equatable, CaseIterable {
    case oauth, cli, appServer, rolloutFile
    /// Read from a build that did not record where a reading came from. Never
    /// stands in for `oauth`.
    case unknown
}

/// One window's reading at one moment. Natural key:
/// `(provider, windowID, source, readingMs)`.
struct QuotaSampleRow: Sendable, Equatable {
    struct Flags: OptionSet, Sendable, Equatable {
        let rawValue: Int
        /// Imported from `last-state.json`'s `quotaObservations`.
        static let legacy = Flags(rawValue: 1 << 0)
        /// `readingMs` is later than `recordedMs` (the clock was set back). The
        /// raw reading time is kept: rewriting it would change the natural key
        /// and store one joined flight twice.
        static let futureReading = Flags(rawValue: 1 << 1)
        /// The response named the window but stated no utilization; `usedPercent` is nil.
        static let valueNotStated = Flags(rawValue: 1 << 2)
    }

    let provider: Provider
    let windowID: String
    let source: QuotaSampleSource
    /// When the numbers were measured (`QuotaSnapshot.readingTime`).
    var readingMs: Int64
    let fetchedMs: Int64?
    /// Claude Code's `cachedUsageUtilization.fetchedAtMs` when a CLI scrape only echoed it.
    let cachedMs: Int64?
    /// When the app landed the reading.
    let recordedMs: Int64
    /// nil when the response stated no utilization (never a fabricated 0).
    let usedPercent: Double?
    let resetsAtMs: Int64?
    let cycleSeconds: Int?
    let isModelScoped: Bool?
    let isOneTimeCredit: Bool?
    let isActive: Bool?
    let severity: String?
    let lockedReason: String?
    /// The raw `scope.model.display_name` the window id was built from.
    let scopeName: String?
    /// `weekly_scoped_shares[].used_percent_of_weekly` / `allowance_percent_of_weekly`.
    let shareUsedOfWeekly: Double?
    let shareAllowanceOfWeekly: Double?
    let plan: String?
    let tier: String?
    var flags: Flags

    /// `resetsAt` rounded to the NEAREST 60 s: Claude's reset instants jitter by
    /// up to a second around the minute (59.979 and 0.005 both seen), which
    /// flooring would split into two epochs.
    var resetEpochSeconds: Int64? { HistoryEpoch.seconds(ms: resetsAtMs) }
}

// MARK: - Reset grants

/// One limit-reset grant, as `ClaudeResetGrantFetcher` already reads it
/// (no extra request): the history stores the set whenever it changes.
struct ResetGrantObservation: Sendable, Equatable {
    let id: String
    let resetsLeft: Int?
    let endsAtMs: Int64?
    /// The window keys the grant clears, sorted, comma-joined.
    let clears: String
}

// MARK: - Window ids

/// The one place a scope's display name becomes a window id, shared by
/// `ClaudeOAuthFetcher` and `UsageReportLimit.windowID` so both name the same
/// window the same way.
enum QuotaWindowID {
    /// `seven_day_<name>`: the name trimmed, lowercased, spaces → `_`. nil for a
    /// missing or empty name.
    static func scopedWeekly(displayName: String?) -> String? {
        guard let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return "seven_day_" + trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
    }
}

// MARK: - The seam

/// Where the scan and the refresh hand what they read. Every call is
/// non-isolated, never suspends, never throws and is applied in call order, so
/// a caller on the MainActor or on a scan thread never waits for the database.
/// Implementations must keep ONE consumer: a second drain starting while the
/// first yields reorders calls. A submission to an unavailable store is
/// dropped and counted, never retried: the next scan re-feeds what the usage
/// cache still holds.
protocol HistoryIngesting: Sendable {
    func submit(scan: HistoryScanBatch)
    func submit(quota: [QuotaSampleRow])
    /// The 24 h of `quotaObservations` an earlier build kept; applied once per database.
    func submit(legacyQuota: [QuotaSampleRow])
    /// The grant set as of `recordedMs`; stored only when it differs from the last stored set.
    func submit(resetGrants: [ResetGrantObservation], recordedMs: Int64)
}
