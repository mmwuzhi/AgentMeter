import AgentStatusCore
import Darwin
import Foundation

private struct HookInput: Decodable {
    let sessionID: String?
    let cwd: String?
    let message: String?
    let title: String?
    let error: String?
    let errorDetails: String?
    /// Set only when the event fired inside a subagent.
    let agentID: String?
    /// `Stop` input only. Decoded leniently by `HookBackgroundTaskList`, so a
    /// malformed array cannot fail the whole input and drop the write.
    let backgroundTasks: HookBackgroundTaskList?

    // Read for the turn ledger (`TaskLedger`). Every one is lenient: a value
    // of an unexpected type reads as absent instead of failing the input, so
    // nothing the payload write depended on before can break it now.
    let hookEventName: LenientString?
    let promptID: LenientString?
    /// Matched against a tag prefix in memory; never stored.
    let prompt: LenientString?
    let transcriptPath: LenientString?
    let notificationType: LenientString?
    let reason: LenientString?
    let stopHookActive: LenientBool?
    let sessionCrons: LenientCount?
    let toolResponse: ToolResponse?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case message
        case title
        case error
        case errorDetails = "error_details"
        case agentID = "agent_id"
        case backgroundTasks = "background_tasks"
        case hookEventName = "hook_event_name"
        case promptID = "prompt_id"
        case prompt
        case transcriptPath = "transcript_path"
        case notificationType = "notification_type"
        case reason
        case stopHookActive = "stop_hook_active"
        case sessionCrons = "session_crons"
        case toolResponse = "tool_response"
    }
}

private struct LenientString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

private struct LenientBool: Decodable {
    let value: Bool?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Bool.self)
    }
}

/// An array's length, without decoding its elements.
private struct LenientCount: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        value = (try? decoder.unkeyedContainer()).map { $0.count ?? 0 }
    }
}

/// The one field of a tool's response the ledger reads: the id of the shell
/// a `Bash` call left running in the background. Any other shape (a string,
/// an array, an MCP result) has none.
private struct ToolResponse: Decodable {
    let backgroundTaskID: String?
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: Key.self)
        backgroundTaskID = (try? container?.decodeIfPresent(String.self, forKey: .backgroundTaskID)) ?? nil
    }
    private enum Key: String, CodingKey {
        case backgroundTaskID = "backgroundTaskId"
    }
}

private func environmentValue(_ key: String) -> String? {
    let value = ProcessInfo.processInfo.environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
}

private func usage() -> String {
    """
    usage:
      agentmeter-hook <working|waiting|idle|error> [--session ID] [--cwd PATH] [--message TEXT]
      agentmeter-hook remove [--session ID]
      agentmeter-hook show   [--session ID]
      agentmeter-hook path

    Claude Code hooks provide session_id, cwd, and event details as JSON on stdin.
    Explicit options are available for diagnostics and override stdin fields.
    `idle` records `working` instead while the Stop input lists background_tasks
    still in flight (subagents, shell jobs); the next Stop with none returns idle.
    `error` writes nothing when the input carries agent_id (a subagent's failure).
    Main-agent prompt, Stop, StopFailure, permission notices, session end, and
    background shell launches also update the session's turn ledger
    (agent-status/turns/), which AgentMeter reads to tell when a task finished.
    """
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n" + usage() + "\n").utf8))
    exit(64)
}

private func parseOptions(_ arguments: [String]) -> [String: String] {
    let allowed = Set(["session", "cwd", "message"])
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        guard flag.hasPrefix("--"), index + 1 < arguments.count else {
            fail("unexpected argument: \(flag)")
        }
        let key = String(flag.dropFirst(2))
        guard allowed.contains(key) else { fail("unknown option: \(flag)") }
        options[key] = arguments[index + 1]
        index += 2
    }
    return options
}

private func hookInput() -> HookInput? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    // Whole, not the first 128 KB: a PostToolUse input carries the tool's
    // response, and a large Read cut off there failed to decode on every
    // such call (`HookStandardInput`). Past its cap nothing correct can be
    // written — the session id is inside the document that was refused.
    guard let data = HookStandardInput.readAll(from: FileHandle.standardInput) else { exit(0) }
    guard !data.isEmpty else { return nil }
    guard let input = try? JSONDecoder().decode(HookInput.self, from: data) else {
        fail("invalid Claude hook JSON on stdin")
    }
    return input
}

private func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
          size >= MemoryLayout<kinfo_proc>.stride else { return nil }
    return info.kp_eproc.e_ppid
}

/// Capture the hook's parent chain. AgentMeter can then match a payload to the
/// exact Claude process even when several sessions share one working directory.
private func processAncestry() -> [Int] {
    var result: [Int] = []
    var current = getppid()
    for _ in 0..<32 where current > 1 {
        result.append(Int(current))
        guard let parent = parentPID(of: current), parent != current else { break }
        current = parent
    }
    return result
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("missing command") }
arguments.removeFirst()
if ["help", "--help", "-h"].contains(command) {
    print(usage())
    exit(0)
}

let options = parseOptions(arguments)
private let input = ["working", "waiting", "idle", "error", "remove"].contains(command)
    ? hookInput()
    : nil

func resolvedCWD() -> String {
    options["cwd"].flatMap { $0.isEmpty ? nil : $0 }
        ?? input?.cwd
        ?? environmentValue("CLAUDE_PROJECT_DIR")
        ?? environmentValue("PWD")
        ?? FileManager.default.currentDirectoryPath
}

func resolvedSessionID() -> String {
    options["session"].flatMap { $0.isEmpty ? nil : $0 }
        ?? input?.sessionID
        ?? environmentValue("CLAUDE_SESSION_ID")
        ?? environmentValue("CLAUDE_CODE_SESSION_ID")
        ?? resolvedCWD()
}

func resolvedMessage(for state: AgentStatusState) -> String? {
    if let message = options["message"], !message.isEmpty { return message }
    switch state {
    case .waiting:
        return input?.message ?? input?.title ?? "Waiting for your input"
    case .error:
        return input?.errorDetails ?? input?.error ?? "Run failed"
    case .working, .idle:
        return nil
    }
}

/// Records the event in the session's turn ledger. Best effort: a ledger
/// that cannot be written (lock held too long, disk full) costs a
/// notification, never the hook's exit status or its payload write.
func recordTaskLedgerEvent(sessionID: String, at date: Date) {
    guard let input,
          let event = TaskLedgerEvent.from(
              hookEventName: input.hookEventName?.value,
              agentID: input.agentID,
              promptID: input.promptID?.value,
              prompt: input.prompt?.value,
              backgroundTasks: input.backgroundTasks,
              sessionCronCount: input.sessionCrons?.value,
              stopHookActive: input.stopHookActive?.value,
              error: input.error,
              notificationType: input.notificationType?.value,
              reason: input.reason?.value,
              backgroundTaskID: input.toolResponse?.backgroundTaskID,
              cwd: input.cwd,
              transcriptPath: input.transcriptPath?.value,
              attended: TaskLedgerEvent.attended(environmentValue: environmentValue("CLAUDE_CODE_SESSION_ATTENDED"),
                                                 sessionKind: environmentValue("CLAUDE_CODE_SESSION_KIND")),
              at: date
          ) else { return }
    _ = try? TaskLedgerStore.apply(event, sessionID: sessionID)
}

do {
    switch command {
    case "working", "waiting", "idle", "error":
        guard let requested = AgentStatusState(rawValue: command) else { fail("unknown command: \(command)") }
        // One clock reading for both files, so the detector can compare the
        // payload's time with the ledger's.
        let now = Date()
        let sessionID = resolvedSessionID()
        // `Stop` fires while background subagents may still be running; the
        // input's `background_tasks` says whether this turn end is a pause.
        // A subagent's own `StopFailure` writes nothing.
        let backgroundTasks = input?.backgroundTasks.map(HookBackgroundTasks.init)
        if let state = AgentStatusState.recordedState(
            requested: requested,
            backgroundTasks: backgroundTasks,
            agentID: input?.agentID
        ) {
            try AgentStatusStore.write(
                AgentStatusPayload(
                    state: state,
                    sessionID: sessionID,
                    message: resolvedMessage(for: state),
                    cwd: resolvedCWD(),
                    processAncestry: processAncestry(),
                    pendingBackgroundTasks: backgroundTasks?.total,
                    pendingSubagents: backgroundTasks?.subagents,
                    updatedAt: now
                )
            )
        }
        recordTaskLedgerEvent(sessionID: sessionID, at: now)
    case "remove":
        let sessionID = resolvedSessionID()
        AgentStatusStore.remove(sessionID: sessionID)
        recordTaskLedgerEvent(sessionID: sessionID, at: Date())
    case "show":
        if let payload = AgentStatusStore.read(sessionID: resolvedSessionID()) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(payload), as: UTF8.self))
        } else {
            print("no status for session")
        }
    case "path":
        print(AgentStatusStore.directory.path)
    default:
        fail("unknown command: \(command)")
    }
} catch {
    FileHandle.standardError.write(Data(("\(error)\n").utf8))
    exit(1)
}
