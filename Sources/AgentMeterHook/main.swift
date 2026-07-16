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

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case message
        case title
        case error
        case errorDetails = "error_details"
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
    guard isatty(STDIN_FILENO) == 0,
          let data = try? FileHandle.standardInput.read(upToCount: 128 * 1024),
          !data.isEmpty else { return nil }
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

do {
    switch command {
    case "working", "waiting", "idle", "error":
        guard let state = AgentStatusState(rawValue: command) else { fail("unknown command: \(command)") }
        try AgentStatusStore.write(
            AgentStatusPayload(
                state: state,
                sessionID: resolvedSessionID(),
                message: resolvedMessage(for: state),
                cwd: resolvedCWD(),
                processAncestry: processAncestry()
            )
        )
    case "remove":
        AgentStatusStore.remove(sessionID: resolvedSessionID())
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
