import Foundation

public enum AgentStatusState: String, Codable, Sendable, CaseIterable {
    case working
    case waiting
    case idle
    case error

    public var priority: Int {
        switch self {
        case .error: return 3
        case .waiting: return 2
        case .working: return 1
        case .idle: return 0
        }
    }

    /// The state a `Stop` event should record. Claude Code fires `Stop` when
    /// the main agent's turn ends even while background subagents or shell
    /// tasks it launched are still running, and lists those under
    /// `background_tasks` — "session is paused waiting for background work",
    /// in the hooks reference's words. Such a turn end is a pause, not
    /// idleness: the row stays `working` until a later `Stop` (the one after
    /// the task notification wakes the main agent) arrives with an empty list.
    /// A subagent's tool calls do rewrite the state through `PreToolUse`, but
    /// a long thinking stretch fires nothing, and that is the gap this closes.
    public static func resolvedStopState(backgroundTasks: HookBackgroundTasks?) -> AgentStatusState {
        (backgroundTasks?.total ?? 0) > 0 ? .working : .idle
    }
}

/// What a hook event says about the session's in-flight background work: the
/// `background_tasks` array on `Stop` (and `SubagentStop`) input. Hook input is
/// untrusted, so decoding never fails — a throw here would abort the whole
/// stdin decode and lose the write. A value that is not an array counts as no
/// tasks, and an entry that is not a JSON object is skipped. An entry's `type`
/// is read only to tell subagents from other task kinds for the row's wording.
public struct HookBackgroundTasks: Decodable, Sendable, Equatable {
    /// Well-formed entries, whatever their kind.
    public var total: Int
    /// Entries whose `type` is `subagent`.
    public var subagents: Int

    public init(total: Int, subagents: Int) {
        self.total = total
        self.subagents = subagents
    }

    public init(from decoder: Decoder) throws {
        var total = 0
        var subagents = 0
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                let index = array.currentIndex
                // `superDecoder()` steps past the element whatever its shape,
                // so a malformed entry cannot stall the loop; the index check
                // is a belt for a container that did not step.
                guard let element = try? array.superDecoder(), array.currentIndex > index else { break }
                guard let entry = try? element.container(keyedBy: EntryKey.self) else { continue }
                total += 1
                if (try? entry.decodeIfPresent(String.self, forKey: .type)) == "subagent" {
                    subagents += 1
                }
            }
        }
        self.init(total: total, subagents: subagents)
    }

    private enum EntryKey: String, CodingKey {
        case type
    }
}

/// One live Claude Code session status written by the hook helper and read by
/// AgentMeter. The process ancestry lets the app disambiguate two sessions
/// running from the same working directory even before their transcripts can
/// be mapped to processes.
public struct AgentStatusPayload: Codable, Sendable, Equatable {
    public var state: AgentStatusState
    public var sessionID: String
    public var message: String?
    public var cwd: String?
    public var processAncestry: [Int]?
    /// Background tasks Claude Code reported still in flight when this state
    /// was recorded (`Stop` input). Nil when the event carried no
    /// `background_tasks`, as `PreToolUse` and the other events do not; files
    /// written before the field existed decode with nil as well.
    public var pendingBackgroundTasks: Int?
    /// How many of `pendingBackgroundTasks` are subagents.
    public var pendingSubagents: Int?
    public var updatedAt: Date

    public init(
        state: AgentStatusState,
        sessionID: String,
        message: String? = nil,
        cwd: String? = nil,
        processAncestry: [Int]? = nil,
        pendingBackgroundTasks: Int? = nil,
        pendingSubagents: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.state = state
        self.sessionID = sessionID
        self.message = message
        self.cwd = cwd
        self.processAncestry = processAncestry
        self.pendingBackgroundTasks = pendingBackgroundTasks
        self.pendingSubagents = pendingSubagents
        self.updatedAt = updatedAt
    }
}
