import Foundation

enum ActiveAgentService {
    static func fetch() async -> [ActiveAgent] {
        await Task.detached {
            let agents = parsePSOutput(runPS().output, observedAt: Date())
            return await enrichSessionUsage(agents)
        }.value
    }

    static func parsePSOutput(_ output: String, observedAt: Date) -> [ActiveAgent] {
        parsePSOutput(
            output,
            observedAt: observedAt,
            cwdLookup: cwd(for:),
            sessionLookup: currentSession(provider:cwd:startedAt:observedAt:)
        )
    }

    static func parsePSOutput(
        _ output: String,
        observedAt: Date,
        cwdLookup: (Int) -> String?,
        sessionLookup: (Provider, String?, Date, Date) -> ActiveAgentSession?
    ) -> [ActiveAgent] {
        let rows: [ProcessRow] = output.split(separator: "\n")
            .compactMap { line -> ProcessRow? in ProcessRow(line: String(line)) }
        let candidates: [AgentCandidate] = rows
            .compactMap { row -> AgentCandidate? in
                guard let provider = provider(for: row.command),
                      !isHelperCommand(row.command) else { return nil }
                let cwd = cwdLookup(row.pid)
                let startedAt = observedAt.addingTimeInterval(-row.elapsedSeconds)
                return AgentCandidate(row: row, provider: provider, cwd: cwd, startedAt: startedAt)
            }
        let groupCounts = Dictionary(
            grouping: candidates.compactMap { candidate -> SessionGroup? in
                guard let cwd = candidate.cwd else { return nil }
                return SessionGroup(provider: candidate.provider, cwd: cwd)
            },
            by: { $0 }
        ).mapValues(\.count)

        return candidates
            .map { candidate in
                let session = candidate.cwd.flatMap { cwd -> ActiveAgentSession? in
                    let group = SessionGroup(provider: candidate.provider, cwd: cwd)
                    guard groupCounts[group, default: 0] <= 1 else { return nil }
                    return sessionLookup(candidate.provider, cwd, candidate.startedAt, observedAt)
                }
                return ActiveAgent(
                    provider: candidate.provider,
                    pid: candidate.row.pid,
                    parentPID: candidate.row.parentPID,
                    command: candidate.row.command,
                    elapsedSeconds: candidate.row.elapsedSeconds,
                    observedAt: observedAt,
                    cwd: candidate.cwd,
                    session: session
                )
            }
            .sorted { lhs, rhs in
                if lhs.provider.rawValue != rhs.provider.rawValue {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                return lhs.elapsedSeconds > rhs.elapsedSeconds
            }
    }

    private struct ProcessResult: Sendable {
        var output: String = ""
        var stderr: String = ""
        var terminationStatus: Int32?
        var timedOut = false
        var launchError: String?
    }

    private final class PipeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let current = data
            lock.unlock()
            return current
        }
    }

    private static func runPS() -> ProcessResult {
        runProcessResult(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,etime=,command="],
            timeout: 2
        )
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
        if lower.contains("codex computer use.app") { return true }
        if lower.contains("/applications/codex.app/contents/") {
            if lower.contains("/resources/codex ") { return false }
            if lower.contains("/applications/codex.app/contents/macos/codex") { return false }
            return true
        }
        return false
    }

    private static func cwd(for pid: Int) -> String? {
        let output = runProcess(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"],
            timeout: 1
        )
        guard !output.isEmpty else { return nil }
        return output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("n") })
            .map { String($0.dropFirst()) }
    }

    static func runProcess(executable: URL, arguments: [String], timeout: TimeInterval) -> String {
        runProcessResult(executable: executable, arguments: arguments, timeout: timeout).output
    }

    private static func runProcessResult(executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = SubprocessWorkingDirectory.url
        let pipe = Pipe()
        let stderrPipe = Pipe()
        let outputBuffer = PipeBuffer()
        let stderrBuffer = PipeBuffer()
        process.standardOutput = pipe
        process.standardError = stderrPipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }
        do {
            try process.run()
        } catch {
            return ProcessResult(launchError: String(describing: error))
        }

        guard waitForExit(process, timeout: timeout) else {
            process.terminate()
            _ = waitForExit(process, timeout: 0.5)
            return ProcessResult(timedOut: true)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        let finalOutputData = outputBuffer.snapshot()
        let finalStderrData = stderrBuffer.snapshot()
        let output = String(data: finalOutputData, encoding: .utf8) ?? ""
        let stderr = String(data: finalStderrData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return ProcessResult(
                output: "",
                stderr: stderr,
                terminationStatus: process.terminationStatus
            )
        }
        return ProcessResult(
            output: output,
            stderr: stderr,
            terminationStatus: process.terminationStatus
        )
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }

    private static func currentSession(
        provider: Provider,
        cwd: String?,
        startedAt: Date,
        observedAt: Date
    ) -> ActiveAgentSession? {
        guard let cwd, !cwd.isEmpty else { return nil }
        switch provider {
        case .claude:
            return latestClaudeSession(cwd: cwd, startedAt: startedAt, observedAt: observedAt)
        case .codex:
            return latestCodexSession(cwd: cwd, startedAt: startedAt, observedAt: observedAt)
        case .copilot:
            return nil
        }
    }

    private static func latestClaudeSession(cwd: String, startedAt: Date, observedAt: Date) -> ActiveAgentSession? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(claudeProjectKey(for: cwd), isDirectory: true)
            .resolvingSymlinksInPath()
        let candidates = sessionFiles(
            under: root,
            matching: { $0.pathExtension == "jsonl" },
            startedAt: startedAt,
            observedAt: observedAt
        )
        guard let candidate = candidates.first else { return nil }
        let metadata = claudeMetadata(from: candidate.url)
        let id = metadata.sessionID ?? candidate.url.deletingPathExtension().lastPathComponent
        return ActiveAgentSession(
            id: id,
            projectPath: metadata.cwd ?? cwd,
            projectName: projectName(for: metadata.cwd ?? cwd),
            branch: metadata.branch,
            lastUpdatedAt: candidate.modifiedAt,
            source: "claude jsonl",
            logPath: candidate.url.path
        )
    }

    private static func latestCodexSession(cwd: String, startedAt: Date, observedAt: Date) -> ActiveAgentSession? {
        let candidates = sessionFiles(
            in: CodexRolloutReader.rolloutFiles().suffix(120),
            startedAt: startedAt,
            observedAt: observedAt
        )
        for candidate in candidates {
            guard let metadata = codexMetadata(from: candidate.url),
                  metadata.cwd == cwd else { continue }
            return ActiveAgentSession(
                id: metadata.sessionID,
                projectPath: metadata.cwd,
                projectName: projectName(for: metadata.cwd),
                branch: nil,
                lastUpdatedAt: candidate.modifiedAt,
                source: "codex rollout",
                logPath: candidate.url.path
            )
        }
        return nil
    }

    struct SessionUsageSummary: Sendable, Equatable {
        let tokenCount: Int
        let estimatedCostUSD: Double
    }

    private static func enrichSessionUsage(_ agents: [ActiveAgent]) async -> [ActiveAgent] {
        await PricingService.shared.ensureLoaded()
        var enriched: [ActiveAgent] = []
        for var agent in agents {
            if var session = agent.session,
               let logPath = session.logPath,
               let summary = await sessionUsageSummary(provider: agent.provider, url: URL(fileURLWithPath: logPath)) {
                session.tokenCount = summary.tokenCount
                session.estimatedCostUSD = summary.estimatedCostUSD
                agent.session = session
            }
            enriched.append(agent)
        }
        return enriched
    }

    static func sessionUsageSummary(provider: Provider, url: URL) async -> SessionUsageSummary? {
        let totalsByModel: [String: TokenCounts]
        switch provider {
        case .claude:
            totalsByModel = claudeSessionTokenCounts(from: url)
        case .codex:
            totalsByModel = codexSessionTokenCounts(from: url)
        case .copilot:
            return nil
        }
        let tokenCount = totalsByModel.values.reduce(0) { total, counts in
            total + totalTokens(in: counts)
        }
        guard tokenCount > 0 else { return nil }
        await PricingService.shared.ensureLoaded()
        var cost = 0.0
        for (model, counts) in totalsByModel {
            cost += await PricingService.shared.cost(model: model, counts: counts)
        }
        return SessionUsageSummary(tokenCount: tokenCount, estimatedCostUSD: cost)
    }

    private static func claudeSessionTokenCounts(from url: URL) -> [String: TokenCounts] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var seen = Set<String>()
        var totals: [String: TokenCounts] = [:]
        for line in content.split(separator: "\n") {
            guard line.contains("\"usage\""),
                  let object = jsonObject(from: String(line)),
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let model = (message["model"] as? String) ?? "default"
            if model == "<synthetic>" { continue }

            let messageID = (message["id"] as? String) ?? ""
            let requestID = (object["requestId"] as? String) ?? ""
            let dedup = messageID + "|" + requestID
            if !messageID.isEmpty {
                guard seen.insert(dedup).inserted else { continue }
            }

            var counts = TokenCounts()
            counts.input = (usage["input_tokens"] as? Int) ?? 0
            counts.output = (usage["output_tokens"] as? Int) ?? 0
            counts.cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            if let cacheCreation = usage["cache_creation"] as? [String: Any] {
                counts.cacheWrite5m = (cacheCreation["ephemeral_5m_input_tokens"] as? Int) ?? 0
                counts.cacheWrite1h = (cacheCreation["ephemeral_1h_input_tokens"] as? Int) ?? 0
            } else {
                counts.cacheWrite5m = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            }
            add(counts, to: &totals, model: model)
        }
        return totals
    }

    private static func codexSessionTokenCounts(from url: URL) -> [String: TokenCounts] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var model = "gpt-5-codex"
        var totals: [String: TokenCounts] = [:]
        for line in content.split(separator: "\n") {
            guard let object = jsonObject(from: String(line)),
                  let payload = object["payload"] as? [String: Any] else { continue }
            if let nextModel = payload["model"] as? String {
                model = nextModel
            }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { continue }
            let input = (last["input_tokens"] as? Int) ?? 0
            let cached = (last["cached_input_tokens"] as? Int) ?? 0
            let output = (last["output_tokens"] as? Int) ?? 0
            var counts = TokenCounts()
            counts.input = max(0, input - cached)
            counts.cacheRead = cached
            counts.output = output
            add(counts, to: &totals, model: model)
        }
        return totals
    }

    private static func add(_ counts: TokenCounts, to totals: inout [String: TokenCounts], model: String) {
        var existing = totals[model] ?? TokenCounts()
        existing.input += counts.input
        existing.output += counts.output
        existing.cacheWrite5m += counts.cacheWrite5m
        existing.cacheWrite1h += counts.cacheWrite1h
        existing.cacheRead += counts.cacheRead
        totals[model] = existing
    }

    private static func totalTokens(in counts: TokenCounts) -> Int {
        counts.input + counts.output + counts.cacheWrite5m + counts.cacheWrite1h + counts.cacheRead
    }

    private static func sessionFiles(
        under root: URL,
        matching predicate: (URL) -> Bool,
        startedAt: Date,
        observedAt: Date
    ) -> [(url: URL, modifiedAt: Date)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return sessionFiles(in: files.filter(predicate), startedAt: startedAt, observedAt: observedAt)
    }

    private static func sessionFiles(
        in files: ArraySlice<URL>,
        startedAt: Date,
        observedAt: Date
    ) -> [(url: URL, modifiedAt: Date)] {
        sessionFiles(in: Array(files), startedAt: startedAt, observedAt: observedAt)
    }

    private static func sessionFiles(
        in files: [URL],
        startedAt: Date,
        observedAt: Date
    ) -> [(url: URL, modifiedAt: Date)] {
        let lowerBound = startedAt.addingTimeInterval(-300)
        let upperBound = observedAt.addingTimeInterval(60)
        return files.compactMap { url in
            guard let modifiedAt = modificationDate(for: url),
                  modifiedAt >= lowerBound,
                  modifiedAt <= upperBound else { return nil }
            return (url, modifiedAt)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    private static func claudeProjectKey(for cwd: String) -> String {
        cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func projectName(for path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func claudeMetadata(from url: URL) -> (sessionID: String?, cwd: String?, branch: String?) {
        var sessionID: String?
        var cwd: String?
        var branch: String?
        for line in firstLines(of: url, maxLines: 40) {
            guard let object = jsonObject(from: line) else { continue }
            sessionID = sessionID ?? object["sessionId"] as? String
            cwd = cwd ?? object["cwd"] as? String
            branch = branch ?? object["gitBranch"] as? String
            if sessionID != nil, cwd != nil { break }
        }
        return (sessionID, cwd, branch)
    }

    private static func codexMetadata(from url: URL) -> (sessionID: String, cwd: String)? {
        for line in firstLines(of: url, maxLines: 12) {
            if let object = jsonObject(from: line),
               object["type"] as? String == "session_meta",
               let payload = object["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String {
                let id = (payload["session_id"] as? String)
                    ?? (payload["id"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "rollout-", with: "")
                return (id, cwd)
            }
            guard line.contains("\"session_meta\""),
                  let cwd = jsonStringValue(forKey: "cwd", in: line) else { continue }
            let id = jsonStringValue(forKey: "session_id", in: line)
                ?? jsonStringValue(forKey: "id", in: line)
                ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "rollout-", with: "")
            return (id, cwd)
        }
        return nil
    }

    private static func firstLines(of url: URL, maxLines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        let data: Data
        do {
            data = try handle.read(upToCount: 262_144) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            return []
        }
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        return content.split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: true)
            .prefix(maxLines)
            .map(String.init)
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jsonStringValue(forKey key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: "\"\(key)\""),
              let colon = line[keyRange.upperBound...].firstIndex(of: ":"),
              let openQuote = line[colon...].firstIndex(of: "\"") else { return nil }
        var index = line.index(after: openQuote)
        var escaped = false
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" && !escaped {
                let raw = String(line[openQuote...index])
                guard let data = raw.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(String.self, from: data)
            }
            escaped = character == "\\" && !escaped
            if character != "\\" { escaped = false }
            index = line.index(after: index)
        }
        return nil
    }

    private struct AgentCandidate {
        let row: ProcessRow
        let provider: Provider
        let cwd: String?
        let startedAt: Date
    }

    private struct SessionGroup: Hashable {
        let provider: Provider
        let cwd: String
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
