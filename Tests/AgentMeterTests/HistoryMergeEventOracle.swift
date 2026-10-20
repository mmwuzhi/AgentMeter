import Foundation
@testable import AgentMeter

// Fork-copied events for the property test, and their closed form: every
// keyed event row is the copy of the file that ranks first by (birth IS NULL,
// birth, path bytes); a cost state merges `after_ts_ms` as a NULL-aware MAX.

enum HMEvent: Sendable {
    case limit(LimitEventObservation)
    case report(UsageReportObservation)
    case compact(CompactEventObservation)
    case cost(CostStateObservation)
}

/// One copy of an event template in one file; visible in a prefix snapshot
/// whose cut is greater than `position`.
struct HMEventCopy: Sendable {
    let path: String
    let position: Int
    let template: Int
    let event: HMEvent
}

enum HMEvents {
    /// 1-3 templates, each copied into 1-3 distinct files with a fresh uuid per
    /// copy (as a fork re-stamps them) and, for cost states, a per-file
    /// `after_ts_ms`. Template keys are unique, so a file never holds two
    /// events with one key.
    static func make(_ rng: inout HistorySplitMix64, paths: [String], sessions: [String], counts: [String: Int],
                     base: Int64) -> [HMEventCopy] {
        var copies: [HMEventCopy] = []
        var uuid = 0
        for t in 0..<Int.random(in: 1...3, using: &rng) {
            let kind = Int.random(in: 0..<4, using: &rng)
            let requestID: String? = Bool.random(using: &rng) ? "req_\(t)" : nil
            let cc = ["2.1.1", "2.1.2"].randomElement(using: &rng)!
            let ts = base + Int64(t)
            for path in paths.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)) {
                uuid += 1
                let u = "u\(t)-\(uuid)"
                let event: HMEvent
                switch kind {
                case 0:
                    event = .limit(LimitEventObservation(
                        uuid: u, requestID: requestID, tsMs: ts, windowID: "five_hour", status: "rejected",
                        resetsAtMs: base + 3_600_000, overageStatus: nil, overageDisabledReason: nil, isUsingOverage: false,
                        fallbackAvailable: nil, source: "quotaLimits", apiError: nil, ccVersion: cc))
                case 1:
                    event = .report(UsageReportObservation(
                        uuid: u, tsMs: ts, ccVersion: cc, hasLimits: true, extraEnabled: nil, extraMonthlyLimit: nil,
                        extraUsedCredits: nil, limits: [
                            UsageReportLimit(index: 0, kind: "session", group: nil, percent: Double(10 * (t + 1)),
                                             severity: nil, isActive: true, resetsAtMs: base + 3_600_000, scopeModel: nil),
                            UsageReportLimit(index: 1, kind: "weekly_scoped", group: nil, percent: 2.5, severity: nil,
                                             isActive: nil, resetsAtMs: nil, scopeModel: "Fable"),
                        ]))
                case 2:
                    event = .compact(CompactEventObservation(uuid: u, tsMs: ts, trigger: t % 2 == 0 ? "auto" : nil,
                                                             preTokens: 1_000 + t, postTokens: nil))
                default:
                    let after: Int64? = [nil, 0, 3, 5].randomElement(using: &rng)!.map { base + Int64($0) }
                    event = .cost(CostStateObservation(
                        sessionID: sessions[t % sessions.count], startTimeMs: 100 + Int64(t), totalDurationMs: 50,
                        totalAPIDurationMs: 40, totalCostUSD: 0.5, hasUnknownModelCost: false, afterTsMs: after,
                        models: [CostStateModel(modelKey: "m1[1m]", input: 1, output: 2, cacheRead: 3, cacheCreation: 4,
                                                thinking: 0, webSearch: 0, costUSD: 0.5)]))
                }
                copies.append(HMEventCopy(path: path, position: Int.random(in: 0..<counts[path]!, using: &rng),
                                          template: t, event: event))
            }
        }
        return copies
    }

    /// What a batch of `path` cut after `cut` records carries.
    static func events(_ copies: [HMEventCopy], path: String, cut: Int) -> HistoryFileEvents {
        var e = HistoryFileEvents()
        for c in copies where c.path == path && c.position < cut {
            switch c.event {
            case let .limit(x): e.limitEvents.append(x)
            case let .report(x): e.usageReports.append(x)
            case let .compact(x): e.compactEvents.append(x)
            case let .cost(x): e.costStates.append(x)
            }
        }
        return e
    }

    /// The dump's event lines by the closed form.
    static func lines(_ copies: [HMEventCopy], births: [String: Int64]) -> [String] {
        typealias F = HistoryLogicalDump.Field
        func rank(_ p: String) -> HistoryFileRank { HistoryFileRank(birthMs: births[p], path: p) }
        func owner(_ group: [HMEventCopy]) -> HMEventCopy { group.min { rank($0.path) < rank($1.path) }! }
        func source(_ p: String) -> HistorySourceFile { HistorySourceFile.parse(path: p) }
        func bool(_ b: Bool?) -> Int64? { b.map { $0 ? 1 : 0 } }
        var keyed: [String: [HMEventCopy]] = [:]
        var order: [String] = []
        for c in copies {
            let key: String
            switch c.event {
            case let .limit(x): key = "L" + HistoryEventCheck.limitKey(x)
            case let .report(x): key = "U" + HistoryEventCheck.reportKey(x)
            case let .compact(x): key = "X" + HistoryEventCheck.compactKey(x)
            case let .cost(x): key = "C\(x.sessionID)|\(x.startTimeMs)|\(x.totalDurationMs)"
            }
            if keyed[key] == nil { order.append(key) }
            keyed[key, default: []].append(c)
        }
        var lines: [String] = []
        for key in order {
            let group = keyed[key]!
            let o = owner(group)
            let s = source(o.path)
            switch o.event {
            case let .limit(x):
                lines.append(HistoryLogicalDump.line("L", [
                    .s(HistoryEventCheck.limitKey(x)), .s(x.uuid), .s(x.requestID), .s(s.sessionID), .s(s.agentID),
                    .i(Int64(s.fileClass.rawValue)), .i(x.tsMs), .s(x.windowID), .s(x.status), .i(x.resetsAtMs),
                    .i(HistoryEpoch.seconds(ms: x.resetsAtMs)), .s(x.overageStatus), .s(x.overageDisabledReason),
                    .i(bool(x.isUsingOverage)), .i(bool(x.fallbackAvailable)), .s(x.source), .s(x.apiError), .s(x.ccVersion),
                    .s(o.path)] as [F]))
            case let .report(x):
                let k = HistoryEventCheck.reportKey(x)
                lines.append(HistoryLogicalDump.line("U", [
                    .s(k), .s(x.uuid), .s(s.sessionID), .i(x.tsMs), .s(x.ccVersion), .i(x.hasLimits ? 1 : 0),
                    .i(bool(x.extraEnabled)), .i(x.extraMonthlyLimit.map(Int64.init)), .i(x.extraUsedCredits.map(Int64.init)),
                    .s(o.path)] as [F]))
                for l in x.limits {
                    guard let w = l.windowID else { continue }
                    lines.append(HistoryLogicalDump.line("UL", [
                        .s(k), .i(Int64(l.index)), .s(w), .s(l.kind), .s(l.group), .d(l.percent), .s(l.severity),
                        .i(bool(l.isActive)), .i(l.resetsAtMs), .i(HistoryEpoch.seconds(ms: l.resetsAtMs)), .s(l.scopeModel)] as [F]))
                }
            case let .compact(x):
                lines.append(HistoryLogicalDump.line("X", [
                    .s(HistoryEventCheck.compactKey(x)), .s(s.sessionID), .i(x.tsMs), .s(x.trigger),
                    .i(x.preTokens.map(Int64.init)), .i(x.postTokens.map(Int64.init)), .s(o.path)] as [F]))
            case let .cost(x):
                var after: Int64?
                for c in group { if case let .cost(y) = c.event { after = HistoryNullAware.max(after, y.afterTsMs) } }
                lines.append(HistoryLogicalDump.line("C", [
                    .s(x.sessionID), .i(x.startTimeMs), .i(x.totalDurationMs), .i(x.totalAPIDurationMs), .d(x.totalCostUSD),
                    .i(x.hasUnknownModelCost ? 1 : 0), .i(after)] as [F]))
                for m in x.models {
                    lines.append(HistoryLogicalDump.line("CM", [
                        .s(x.sessionID), .i(x.startTimeMs), .i(x.totalDurationMs), .s(m.modelKey), .i(Int64(m.input)),
                        .i(Int64(m.output)), .i(Int64(m.cacheRead)), .i(Int64(m.cacheCreation)), .i(Int64(m.thinking)),
                        .i(Int64(m.webSearch)), .d(m.costUSD)] as [F]))
                }
            }
        }
        return lines.sorted(by: historyBinaryLess)
    }
}
