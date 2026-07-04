import Foundation

enum ActiveAgentService {
    static func fetch() async -> [ActiveAgent] {
        await Task.detached {
            parsePSOutput(runPS(), observedAt: Date())
        }.value
    }

    static func parsePSOutput(_ output: String, observedAt: Date) -> [ActiveAgent] {
        output.split(separator: "\n")
            .compactMap { ProcessRow(line: String($0)) }
            .compactMap { row in
                guard let provider = provider(for: row.command),
                      !isHelperCommand(row.command) else { return nil }
                return ActiveAgent(
                    provider: provider,
                    pid: row.pid,
                    parentPID: row.parentPID,
                    command: row.command,
                    elapsedSeconds: row.elapsedSeconds,
                    observedAt: observedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.provider.rawValue != rhs.provider.rawValue {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                return lhs.elapsedSeconds > rhs.elapsedSeconds
            }
    }

    private static func runPS() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,etime=,command="]
        process.currentDirectoryURL = SubprocessWorkingDirectory.url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func provider(for command: String) -> Provider? {
        let pieces = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let executable = pieces.first else { return nil }
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        switch name {
        case "claude":
            return .claude
        case "codex":
            return .codex
        default:
            return nil
        }
    }

    private static func isHelperCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("agentmeter.app/contents/macos/agentmeter") { return true }
        if lower.contains("claude /usage") { return true }
        if lower.contains("codex app-server") { return true }
        if lower.contains("/applications/codex.app/contents/") && !lower.contains("/resources/codex ") {
            return true
        }
        return false
    }

    struct ProcessRow {
        let pid: Int
        let parentPID: Int
        let elapsedSeconds: TimeInterval
        let command: String

        init?(line: String) {
            let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 4,
                  let pid = Int(parts[0]),
                  let parentPID = Int(parts[1]),
                  let elapsedSeconds = Self.parseElapsed(parts[2]) else { return nil }
            self.pid = pid
            self.parentPID = parentPID
            self.elapsedSeconds = elapsedSeconds
            self.command = parts[3]
        }

        private static func parseElapsed(_ raw: String) -> TimeInterval? {
            let daySplit = raw.split(separator: "-", maxSplits: 1).map(String.init)
            let days: Int
            let time: String
            if daySplit.count == 2 {
                days = Int(daySplit[0]) ?? 0
                time = daySplit[1]
            } else {
                days = 0
                time = raw
            }
            let parts = time.split(separator: ":").compactMap { Int($0) }
            let seconds: Int
            switch parts.count {
            case 2:
                seconds = parts[0] * 60 + parts[1]
            case 3:
                seconds = parts[0] * 3_600 + parts[1] * 60 + parts[2]
            default:
                return nil
            }
            return TimeInterval(days * 86_400 + seconds)
        }
    }
}
