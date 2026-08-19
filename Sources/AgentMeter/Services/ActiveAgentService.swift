import AgentStatusCore
import Darwin
import Foundation

enum ActiveAgentService {
    private static let sessionUsageCache = LogFileParseCache<SessionUsageSummary>()

    static func fetch() async -> [ActiveAgent] {
        await Task.detached {
            let agents = parsePSOutput(runPS().output, observedAt: Date())
            return attachStatus(await enrichSessionUsage(agents))
        }.value
    }

    static func attachStatus(
        _ agents: [ActiveAgent],
        payloads: [AgentStatusPayload] = AgentStatusStore.readAll()
    ) -> [ActiveAgent] {
        let claudePIDs = Set(agents.lazy.filter { $0.provider == .claude }.map(\.pid))
        var byPID: [Int: AgentStatusPayload] = [:]
        var bySession: [String: AgentStatusPayload] = [:]

        for payload in payloads {
            if let pid = payload.processAncestry?.first(where: claudePIDs.contains),
               payload.updatedAt > (byPID[pid]?.updatedAt ?? .distantPast) {
                byPID[pid] = payload
            }
            if payload.updatedAt > (bySession[payload.sessionID]?.updatedAt ?? .distantPast) {
                bySession[payload.sessionID] = payload
            }
        }

        return agents.map { agent in
            guard agent.provider == .claude else { return agent }
            let processPayload = byPID[agent.pid].flatMap { payload -> AgentStatusPayload? in
                let startedAt = agent.observedAt.addingTimeInterval(-agent.elapsedSeconds)
                return payload.updatedAt >= startedAt.addingTimeInterval(-5) ? payload : nil
            }
            let payload = processPayload ?? agent.session.flatMap { bySession[$0.id] }
            guard let payload else { return agent }
            var agent = agent
            agent.status = payload.state
            return agent
        }
    }

    static func parsePSOutput(_ output: String, observedAt: Date) -> [ActiveAgent] {
        let rows = processRows(from: output)
        let executableByPID = executablePathMap(for: rows)
        let pids = agentPIDs(in: rows, executableByPID: executableByPID)
        let cwdByPID = cwdMap(for: pids)
        let hasCodexAgent = rows.contains { row in
            guard pids.contains(row.pid),
                  let process = agentProcess(row, executablePath: executableByPID[row.pid]) else { return false }
            return process.provider == .codex
        }
        let codexRolloutFiles = hasCodexAgent ? CodexRolloutReader.rolloutFiles() : []
        return parseProcessRows(
            rows,
            observedAt: observedAt,
            executableLookup: { executableByPID[$0] },
            cwdLookup: { cwdByPID[$0] },
            sessionLookup: { provider, cwd, startedAt, observedAt, rolloutIdentifier in
                currentSession(
                    provider: provider,
                    cwd: cwd,
                    startedAt: startedAt,
                    observedAt: observedAt,
                    codexRolloutIdentifier: rolloutIdentifier,
                    codexRolloutFiles: codexRolloutFiles
                )
            }
        )
    }

    private static func processRows(from output: String) -> [ProcessRow] {
        output.split(separator: "\n")
            .compactMap { line -> ProcessRow? in ProcessRow(line: String(line)) }
    }

    private static func agentPIDs(in rows: [ProcessRow], executableByPID: [Int: String]) -> [Int] {
        rows.compactMap { row -> Int? in
            guard let process = agentProcess(row, executablePath: executableByPID[row.pid]),
                  !isHelperProcess(process) else { return nil }
            return row.pid
        }
    }

    static func parsePSOutput(
        _ output: String,
        observedAt: Date,
        cwdLookup: (Int) -> String?,
        sessionLookup: (Provider, String?, Date, Date) -> ActiveAgentSession?
    ) -> [ActiveAgent] {
        parseProcessRows(
            processRows(from: output),
            observedAt: observedAt,
            executableLookup: { _ in nil },
            cwdLookup: cwdLookup,
            sessionLookup: { provider, cwd, startedAt, observedAt, _ in
                sessionLookup(provider, cwd, startedAt, observedAt)
            }
        )
    }

    private static func parseProcessRows(
        _ rows: [ProcessRow],
        observedAt: Date,
        executableLookup: (Int) -> String?,
        cwdLookup: (Int) -> String?,
        sessionLookup: (Provider, String?, Date, Date, String?) -> ActiveAgentSession?
    ) -> [ActiveAgent] {
        let candidates: [AgentCandidate] = rows
            .compactMap { row -> AgentCandidate? in
                guard let process = agentProcess(row, executablePath: executableLookup(row.pid)),
                      !isHelperProcess(process) else { return nil }
                let cwd = cwdLookup(row.pid)
                let startedAt = observedAt.addingTimeInterval(-row.elapsedSeconds)
                let rolloutIdentifier = codexRolloutIdentifier(
                    from: row.command,
                    executablePath: process.executablePath
                )
                return AgentCandidate(
                    row: row,
                    provider: process.provider,
                    cwd: cwd,
                    startedAt: startedAt,
                    codexRolloutIdentifier: rolloutIdentifier
                )
            }
        let groupCounts = Dictionary(
            grouping: candidates.compactMap { candidate -> SessionGroup? in
                guard let cwd = candidate.cwd else { return nil }
                return SessionGroup(provider: candidate.provider, cwd: cwd)
            },
            by: { $0 }
        ).mapValues(\.count)

        let ppidByPID = Dictionary(
            rows.map { ($0.pid, $0.parentPID) },
            uniquingKeysWith: { first, _ in first }
        )
        let providerByAgentPID = Dictionary(
            candidates.map { ($0.row.pid, $0.provider) },
            uniquingKeysWith: { first, _ in first }
        )
        func nearestAgentAncestor(of candidate: AgentCandidate) -> Int? {
            var current = ppidByPID[candidate.row.pid]
            var visited = Set<Int>()
            while let pid = current,
                  pid > 1,
                  visited.insert(pid).inserted,
                  visited.count <= 64 {
                if providerByAgentPID[pid] == candidate.provider { return pid }
                current = ppidByPID[pid]
            }
            return nil
        }

        return candidates
            .map { candidate in
                let session = candidate.cwd.flatMap { cwd -> ActiveAgentSession? in
                    let group = SessionGroup(provider: candidate.provider, cwd: cwd)
                    guard candidate.codexRolloutIdentifier != nil
                            || groupCounts[group, default: 0] <= 1 else { return nil }
                    return sessionLookup(
                        candidate.provider,
                        cwd,
                        candidate.startedAt,
                        observedAt,
                        candidate.codexRolloutIdentifier
                    )
                }
                return ActiveAgent(
                    provider: candidate.provider,
                    pid: candidate.row.pid,
                    parentPID: candidate.row.parentPID,
                    command: candidate.row.command,
                    elapsedSeconds: candidate.row.elapsedSeconds,
                    observedAt: observedAt,
                    tty: candidate.row.tty,
                    cwd: candidate.cwd,
                    session: session,
                    parentAgentPID: nearestAgentAncestor(of: candidate)
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
            arguments: ["-axo", "pid=,ppid=,tty=,etime=,command="],
            timeout: 2
        )
    }

    private static func agentProcess(_ row: ProcessRow, executablePath: String?) -> AgentProcess? {
        let resolvedPath: String
        if let executablePath,
           provider(forExecutablePath: executablePath) != nil {
            resolvedPath = executablePath
        } else if let inferredPath = inferredExecutablePath(from: row.command) {
            // Script-based installs can report the interpreter from
            // `proc_pidpath`; retain the explicit argv[0] fallback for them.
            resolvedPath = inferredPath
        } else {
            return nil
        }
        guard let provider = provider(forExecutablePath: resolvedPath) else { return nil }
        return AgentProcess(
            provider: provider,
            executablePath: resolvedPath,
            arguments: commandArguments(row.command, executablePath: resolvedPath)
        )
    }

    private static func provider(forExecutablePath executablePath: String) -> Provider? {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        let provider: Provider
        switch name {
        case "claude":
            provider = .claude
        case "codex":
            provider = .codex
        default:
            return nil
        }
        return provider
    }

    private static func isHelperProcess(_ process: AgentProcess) -> Bool {
        let arguments = Set(process.arguments.map { $0.lowercased() })
        if arguments.contains("--help") || arguments.contains("--version") { return true }
        switch process.provider {
        case .claude:
            return arguments.contains("/usage")
        case .codex:
            if arguments.contains("app-server") { return true }
            return process.executablePath.lowercased().contains(".app/contents/macos/codex")
        case .copilot:
            return true
        }
    }

    /// Codex Desktop's per-task sandbox includes the task's visualization root
    /// in its command. That final UUID is also the rollout filename UUID, so it
    /// can disambiguate multiple tasks that share a working directory.
    static func codexRolloutIdentifier(from command: String, executablePath: String) -> String? {
        let lowerPath = executablePath.lowercased()
        let arguments = Set(commandArguments(command, executablePath: executablePath).map { $0.lowercased() })
        guard lowerPath.hasSuffix(".app/contents/resources/codex"),
              arguments.contains("sandbox") else { return nil }

        let marker = "/.codex/visualizations/"
        var remainder = command[...]
        var identifiers = Set<String>()

        while let markerRange = remainder.range(of: marker) {
            let suffix = remainder[markerRange.upperBound...]
            let path = suffix.prefix { character in
                !character.isWhitespace
                    && character != "\""
                    && character != "'"
                    && character != ","
                    && character != "}"
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            if components.count >= 4 {
                let candidate = String(components[3]).lowercased()
                if UUID(uuidString: candidate) != nil {
                    identifiers.insert(candidate)
                }
            }
            remainder = suffix
        }

        guard identifiers.count == 1 else { return nil }
        return identifiers.first
    }

    /// Synthetic `ps` fixtures cannot be resolved with `proc_pidpath`. Keep a
    /// conservative fallback for tests and restricted environments: app-bundle
    /// commands are accepted only at the two real agent executable locations.
    private static func inferredExecutablePath(from command: String) -> String? {
        let lower = command.lowercased()
        if lower.contains(".app/contents/") {
            // Nested Chromium/Electron helpers often contain a second
            // `Contents/MacOS/Codex` path. They are never interactive agents.
            if lower.contains("/contents/frameworks/") { return nil }
            for marker in [".app/contents/resources/codex", ".app/contents/macos/codex"] {
                guard let range = command.range(of: marker, options: .caseInsensitive) else { continue }
                let prefix = command[..<range.lowerBound]
                guard !prefix.contains(where: { $0.isWhitespace }),
                      hasCommandBoundary(in: command, after: range.upperBound) else { continue }
                return String(command[..<range.upperBound])
            }
            return nil
        }
        if let range = command.range(
            of: "/library/application support/claude/claude-code/claude",
            options: .caseInsensitive
        ) {
            let prefix = command[..<range.lowerBound]
            guard !prefix.contains(where: { $0.isWhitespace }),
                  hasCommandBoundary(in: command, after: range.upperBound) else { return nil }
            return String(command[..<range.upperBound])
        }
        return command.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private static func hasCommandBoundary(in command: String, after index: String.Index) -> Bool {
        index == command.endIndex || command[index].isWhitespace
    }

    private static func commandArguments(_ command: String, executablePath: String) -> [String] {
        if command.hasPrefix(executablePath) {
            return command.dropFirst(executablePath.count).split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return command.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
    }

    private static func executablePathMap(for rows: [ProcessRow]) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (Int, String)? in
            let lower = row.command.lowercased()
            guard lower.contains("codex") || lower.contains("claude"),
                  let path = executablePath(forPID: row.pid) else { return nil }
            return (row.pid, path)
        })
    }

    private static func executablePath(forPID pid: Int) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro Swift cannot import.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(Int32(pid), bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func cwdMap(for pids: [Int]) -> [Int: String] {
        let uniquePIDs = Array(Set(pids)).sorted()
        guard !uniquePIDs.isEmpty else { return [:] }
        let output = runProcess(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-p", uniquePIDs.map(String.init).joined(separator: ","), "-d", "cwd", "-Fpn"],
            timeout: 1
        )
        guard !output.isEmpty else { return [:] }
        return cwdMap(fromLsofOutput: output)
    }

    static func cwdMap(fromLsofOutput output: String) -> [Int: String] {
        var currentPID: Int?
        var cwdByPID: [Int: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("p") {
                currentPID = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let currentPID {
                cwdByPID[currentPID] = String(line.dropFirst())
            }
        }
        return cwdByPID
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
        observedAt: Date,
        codexRolloutIdentifier: String?,
        codexRolloutFiles: [URL]
    ) -> ActiveAgentSession? {
        guard let cwd, !cwd.isEmpty else { return nil }
        switch provider {
        case .claude:
            return latestClaudeSession(cwd: cwd, startedAt: startedAt, observedAt: observedAt)
        case .codex:
            if let codexRolloutIdentifier {
                return identifiedCodexSession(
                    identifier: codexRolloutIdentifier,
                    cwd: cwd,
                    observedAt: observedAt,
                    rolloutFiles: codexRolloutFiles
                )
            }
            return latestCodexSession(
                cwd: cwd,
                startedAt: startedAt,
                observedAt: observedAt,
                rolloutFiles: codexRolloutFiles
            )
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

    private static func latestCodexSession(
        cwd: String,
        startedAt: Date,
        observedAt: Date,
        rolloutFiles: [URL]
    ) -> ActiveAgentSession? {
        let candidates = sessionFiles(
            in: rolloutFiles.suffix(120),
            startedAt: startedAt,
            observedAt: observedAt
        )
        for candidate in candidates {
            if let session = codexSession(from: candidate.url, modifiedAt: candidate.modifiedAt, cwd: cwd) {
                return session
            }
        }
        return nil
    }

    static func identifiedCodexSession(
        identifier: String,
        cwd: String,
        observedAt: Date,
        rolloutFiles: [URL]
    ) -> ActiveAgentSession? {
        guard let url = rolloutFiles.first(where: {
            $0.lastPathComponent.hasSuffix("-\(identifier).jsonl")
        }), let modifiedAt = modificationDate(for: url),
            modifiedAt <= observedAt.addingTimeInterval(60) else { return nil }
        return codexSession(from: url, modifiedAt: modifiedAt, cwd: cwd)
    }

    private static func codexSession(from url: URL, modifiedAt: Date, cwd: String) -> ActiveAgentSession? {
        guard let metadata = codexMetadata(from: url), metadata.cwd == cwd else { return nil }
        return ActiveAgentSession(
            id: metadata.sessionID,
            projectPath: metadata.cwd,
            projectName: projectName(for: metadata.cwd),
            branch: nil,
            lastUpdatedAt: modifiedAt,
            source: "codex rollout",
            logPath: url.path
        )
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
        guard let fingerprint = LogFileFingerprint.current(for: url) else {
            return await uncachedSessionUsageSummary(provider: provider, url: url)
        }
        if let cached = await sessionUsageCache.value(for: fingerprint) {
            return cached
        }
        guard let summary = await uncachedSessionUsageSummary(provider: provider, url: url) else { return nil }
        await sessionUsageCache.store(summary, for: fingerprint)
        return summary
    }

    static func clearSessionUsageCacheForTests() async {
        await sessionUsageCache.clear()
    }

    private static func uncachedSessionUsageSummary(provider: Provider, url: URL) async -> SessionUsageSummary? {
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
        var seen = Set<String>()
        var totals: [String: TokenCounts] = [:]
        try? JSONLLineReader.forEachLine(in: url) { line in
            guard line.contains("\"usage\""),
                  let object = jsonObject(from: line),
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let model = (message["model"] as? String) ?? "default"
            if model == "<synthetic>" { return }

            let messageID = (message["id"] as? String) ?? ""
            let requestID = (object["requestId"] as? String) ?? ""
            let dedup = messageID + "|" + requestID
            if !messageID.isEmpty {
                guard seen.insert(dedup).inserted else { return }
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
        var model = "gpt-5-codex"
        var totals: [String: TokenCounts] = [:]
        try? JSONLLineReader.forEachLine(in: url) { line in
            // Skip the JSON parse for lines that carry neither a model nor a
            // token_count event — the bulk of a rollout log.
            guard line.contains("token_count") || line.contains("\"model\""),
                  let object = jsonObject(from: line),
                  let payload = object["payload"] as? [String: Any] else { return }
            if let nextModel = payload["model"] as? String {
                model = nextModel
            }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return }
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
        let codexRolloutIdentifier: String?
    }

    private struct AgentProcess {
        let provider: Provider
        let executablePath: String
        let arguments: [String]
    }

    private struct SessionGroup: Hashable {
        let provider: Provider
        let cwd: String
    }

    struct ProcessRow {
        let pid: Int
        let parentPID: Int
        let tty: String?
        let elapsedSeconds: TimeInterval
        let command: String

        init?(line: String) {
            let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 4 || parts.count == 5,
                  let pid = Int(parts[0]),
                  let parentPID = Int(parts[1]) else { return nil }
            self.pid = pid
            self.parentPID = parentPID
            if let elapsedSeconds = Self.parseElapsed(parts[2]) {
                // Backward-compatible test/parser input without the TTY column.
                self.tty = nil
                self.elapsedSeconds = elapsedSeconds
                self.command = parts.dropFirst(3).joined(separator: " ")
            } else {
                guard parts.count == 5,
                      let elapsedSeconds = Self.parseElapsed(parts[3]) else { return nil }
                self.tty = Self.normalizeTTY(parts[2])
                self.elapsedSeconds = elapsedSeconds
                self.command = parts[4]
            }
        }

        private static func normalizeTTY(_ raw: String) -> String? {
            (raw == "??" || raw == "?" || raw.isEmpty) ? nil : raw
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
