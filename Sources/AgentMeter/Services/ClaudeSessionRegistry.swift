import AgentStatusCore
import Foundation

/// One process's entry in Claude Code's own session registry
/// (`~/.claude/sessions/<pid>.json`), reduced to the fields AgentMeter reads.
///
/// Claude Code writes `status` from its own turn state: `busy` while a turn
/// runs, `waiting` while a permission prompt or another dialog blocks it,
/// `idle` between turns, `shell` while the user's own `!` command runs. It
/// changes the moment a prompt is answered and when the user interrupts a
/// turn with Esc, which is where the hook payload stops moving: no hook event
/// fires for either. The file layout is Claude Code's internal one (`claude
/// agents --json` documents these field names), so every field is optional
/// here and an unknown status counts as the registry saying nothing.
struct ClaudeSessionRegistryEntry: Sendable, Equatable {
    enum Status: String, Sendable {
        case busy
        case waiting
        case idle
        case shell
    }

    let pid: Int
    let sessionID: String?
    let cwd: String?
    /// When Claude Code registered the process (`startedAt`, ms since 1970).
    let startedAt: Date?
    let status: Status?
    /// What a `waiting` process waits for, in Claude Code's own words
    /// (`permission prompt`, `input needed`, `dialog open`, …). Untrusted
    /// text, never rendered as is: `ActiveAgentWaitingReason` maps the known
    /// values and drops the rest.
    let waitingFor: String?
    let statusUpdatedAt: Date?

    /// The row state the registry status maps to. `shell` is the user's own
    /// command running in an idle session, so it is idle for the row.
    var agentState: AgentStatusState? {
        switch status {
        case .busy: return .working
        case .waiting: return .waiting
        case .idle, .shell: return .idle
        case nil: return nil
        }
    }
}

enum ClaudeSessionRegistry {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Claude Code's own cap on a registry file (262144 bytes in 2.1.300).
    static let maximumFileBytes = 256 * 1024
    /// Registration happens a few seconds after the process starts and `ps`
    /// reports its age in whole seconds. An entry that claims to predate its
    /// process by more than this was written by an earlier holder of the PID.
    static let startedAtTolerance: TimeInterval = 5
    /// An entry claiming to have started further into the future than this
    /// is garbage, not a clock skew.
    static let futureStartTolerance: TimeInterval = 60
    static let waitingForMaximumLength = 64

    /// Every readable entry, by PID. Only `<pid>.json` files count: the
    /// `<pid>.<hash>.key` files beside them hold the messaging-socket secret
    /// and are never opened. A file that cannot be read or decoded drops
    /// itself, not the listing.
    static func readAll(in directory: URL = directory) -> [Int: ClaudeSessionRegistryEntry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var entries: [Int: ClaudeSessionRegistryEntry] = [:]
        for url in urls {
            guard url.pathExtension == "json",
                  let namedPID = Int(url.deletingPathExtension().lastPathComponent),
                  namedPID > 0,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? maximumFileBytes + 1) <= maximumFileBytes,
                  let entry = readEntry(at: url),
                  entry.pid == namedPID else { continue }
            if let existing = entries[entry.pid],
               (existing.statusUpdatedAt ?? .distantPast) >= (entry.statusUpdatedAt ?? .distantPast) {
                continue
            }
            entries[entry.pid] = entry
        }
        return entries
    }

    /// Claude Code rewrites the file in place on every status change, so a
    /// read can land between the truncate and the write and see half a
    /// document. One short retry covers that window; a file still unreadable
    /// after it is skipped for this tick only, and the row keeps the hook's
    /// state until the next.
    private static func readEntry(at url: URL) -> ClaudeSessionRegistryEntry? {
        if let data = try? Data(contentsOf: url), let entry = decode(data) { return entry }
        usleep(30_000)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Lenient by design: hook input and registry files are both Claude
    /// Code's to change. Only `pid` is required; a field of the wrong type
    /// reads as absent, and keys AgentMeter does not use are never looked at.
    static func decode(_ data: Data) -> ClaudeSessionRegistryEntry? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = integer(object["pid"]), pid > 0 else { return nil }
        return ClaudeSessionRegistryEntry(
            pid: pid,
            sessionID: string(object["sessionId"]),
            cwd: string(object["cwd"]),
            startedAt: date(object["startedAt"]),
            status: string(object["status"]).flatMap(ClaudeSessionRegistryEntry.Status.init(rawValue:)),
            waitingFor: string(object["waitingFor"]).map { String($0.prefix(waitingForMaximumLength)) },
            statusUpdatedAt: date(object["statusUpdatedAt"])
        )
    }

    /// The entry for a live process, or nil when the file belongs to an
    /// earlier holder of the PID (its `startedAt` predates the process) or
    /// cannot be placed in time at all.
    static func entry(
        for pid: Int,
        processStartedAt: Date,
        observedAt: Date,
        in registry: [Int: ClaudeSessionRegistryEntry]
    ) -> ClaudeSessionRegistryEntry? {
        guard let entry = registry[pid], let startedAt = entry.startedAt,
              startedAt >= processStartedAt.addingTimeInterval(-startedAtTolerance),
              startedAt <= observedAt.addingTimeInterval(futureStartTolerance) else { return nil }
        return entry
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), abs(double) < 1e15 else { return nil }
            return Int(double)
        default:
            return nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Milliseconds since 1970, as Claude Code writes them. Bounded the way
    /// Claude Code bounds them (under 4e15), so a stray value cannot become
    /// a date in the year 100,000.
    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 4_000_000_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
