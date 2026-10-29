import AgentStatusCore
import Darwin
import Foundation

enum ActiveAgentService {
    /// Codex rollouts, parsed here: the Claude usage scan does not read them.
    private static let codexTotalsCache = LogFileParseCache<CodexSessionTotals>()
    /// Claude session titles. Claude usage is not parsed here: a session row
    /// reads its transcripts' records through the usage scan's cache.
    private static let claudeTitleCache = LogFileParseCache<ClaudeSessionTitles>()

    /// `claudeCache` and `history` are the usage scan's (the app passes
    /// `.shared` and its history store); the defaults keep a caller off both.
    static func fetch(claudeCache: ClaudeUsageCache = .memoryOnly,
                      history: (any HistoryIngesting)? = nil) async -> [ActiveAgent] {
        await Task.detached {
            let payloads = AgentStatusStore.readAll()
            let registry = ClaudeSessionRegistry.readAll()
            let agents = parsePSOutput(runPS().output, observedAt: Date(), payloads: payloads, registry: registry)
            let enriched = await enrichSessionUsage(agents, claudeCache: claudeCache, history: history)
            return presentable(enriched, payloads: payloads, registry: registry)
        }.value
    }

    /// The popover's local status tick: the registry and the hook files
    /// re-read and re-attached to the rows the last full refresh built,
    /// without `ps`, `lsof`, a quota request or a transcript scan. A row whose
    /// process has exited is dropped; session, usage and observed time stay
    /// as that refresh found them, so ages do not move until it runs again.
    static func refreshStatuses(_ agents: [ActiveAgent]) async -> [ActiveAgent] {
        await Task.detached {
            refreshStatuses(
                agents,
                payloads: AgentStatusStore.readAll(),
                registry: ClaudeSessionRegistry.readAll(),
                isAlive: isProcessAlive
            )
        }.value
    }

    static func refreshStatuses(
        _ agents: [ActiveAgent],
        payloads: [AgentStatusPayload],
        registry: [Int: ClaudeSessionRegistryEntry],
        isAlive: (Int) -> Bool
    ) -> [ActiveAgent] {
        let live = agents.filter { isAlive($0.pid) }.map { agent -> ActiveAgent in
            var agent = agent
            agent.status = nil
            agent.statusUpdatedAt = nil
            agent.statusSource = nil
            agent.waitingReason = nil
            agent.pendingBackgroundTasks = nil
            agent.pendingSubagents = nil
            return agent
        }
        return presentable(live, payloads: payloads, registry: registry)
    }

    /// `kill(pid, 0)` delivers nothing and only asks whether the process
    /// exists; a process AgentMeter may not signal still exists.
    static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0, let value = pid_t(exactly: pid) else { return false }
        return kill(value, 0) == 0 || errno == EPERM
    }

    /// The rows the popover gets: hook state attached, then every process that
    /// has neither a hook state nor an attributed transcript dropped — it is
    /// only a PID; see `ActiveAgent.isBlank`.
    static func presentable(
        _ agents: [ActiveAgent],
        payloads: [AgentStatusPayload],
        registry: [Int: ClaudeSessionRegistryEntry] = [:]
    ) -> [ActiveAgent] {
        attachStatus(agents, payloads: payloads, registry: registry).filter { !$0.isBlank }
    }

    /// Newest hook payload per running agent PID. A payload is attributed to
    /// the nearest ancestor in its recorded process chain that is a live agent
    /// PID, so helpers spawned by a session report for their owning agent.
    static func latestPayloadsByPID(
        _ payloads: [AgentStatusPayload],
        agentPIDs: Set<Int>
    ) -> [Int: AgentStatusPayload] {
        var byPID: [Int: AgentStatusPayload] = [:]
        for payload in payloads {
            if let pid = payload.processAncestry?.first(where: agentPIDs.contains),
               payload.updatedAt > (byPID[pid]?.updatedAt ?? .distantPast) {
                byPID[pid] = payload
            }
        }
        return byPID
    }

    /// The hook payload attributable to this PID, guarded against PID reuse:
    /// it must have been written after the process started.
    static func hookPayload(
        for pid: Int,
        startedAt: Date,
        payloadsByPID: [Int: AgentStatusPayload]
    ) -> AgentStatusPayload? {
        guard let payload = payloadsByPID[pid],
              payload.updatedAt >= startedAt.addingTimeInterval(-5) else { return nil }
        return payload
    }

    /// `payloads` is required (no default) so every caller visibly shares one
    /// store snapshot with `parsePSOutput` — status and session identity must
    /// never be attributed from two different reads. `registry` is Claude
    /// Code's own session registry, read in the same tick.
    ///
    /// A payload attaches by process ancestry only. The helper always records
    /// the chain up from its parent, so a live process's own payloads always
    /// match by PID; a session-id match used to stand in when that failed, and
    /// what it matched was exactly what the PID guard had refused — a
    /// predecessor's payload after a crash or a `--resume`, which painted a
    /// fresh process green, yellow or red until its first hook event.
    ///
    /// A registry entry attaches by PID, guarded the same way against PID
    /// reuse (`ClaudeSessionRegistry.entry`), and only to a process that has
    /// already shown itself to be a session: one with a transcript of its own
    /// or a hook payload. The registry lists every Claude process, the
    /// short-lived helpers Claude Code spawns beside a session included, and
    /// a state alone would turn each of those into a row (`isBlank`).
    static func attachStatus(
        _ agents: [ActiveAgent],
        payloads: [AgentStatusPayload],
        registry: [Int: ClaudeSessionRegistryEntry] = [:]
    ) -> [ActiveAgent] {
        let claudePIDs = Set(agents.lazy.filter { $0.provider == .claude }.map(\.pid))
        let byPID = latestPayloadsByPID(payloads, agentPIDs: claudePIDs)

        return agents.map { agent in
            guard agent.provider == .claude else { return agent }
            let startedAt = agent.observedAt.addingTimeInterval(-agent.elapsedSeconds)
            let payload = hookPayload(for: agent.pid, startedAt: startedAt, payloadsByPID: byPID)
            let entry = agent.session != nil || payload != nil
                ? ClaudeSessionRegistry.entry(
                    for: agent.pid, processStartedAt: startedAt, observedAt: agent.observedAt, in: registry)
                : nil
            guard let resolved = resolveStatus(payload: payload, registry: entry) else {
                return agent
            }
            var agent = agent
            agent.status = resolved.state
            agent.statusUpdatedAt = resolved.updatedAt
            agent.statusSource = resolved.source
            agent.waitingReason = resolved.waitingReason
            agent.pendingBackgroundTasks = payload?.pendingBackgroundTasks
            agent.pendingSubagents = payload?.pendingSubagents
            return agent
        }
    }

    struct ResolvedStatus: Equatable, Sendable {
        var state: AgentStatusState
        var updatedAt: Date?
        var source: ActiveAgentStatusSource
        var waitingReason: ActiveAgentWaitingReason?
    }

    /// A `StopFailure` hook runs just before Claude Code writes `idle` for
    /// the same turn end (13 ms apart on 2026-10-16), the payload's time is
    /// whole seconds and the registry's milliseconds: an error written up to
    /// this long before the registry's own change still describes the state
    /// the registry is in.
    static let errorRegistryTolerance: TimeInterval = 10

    /// The row state from the two sources. The registry decides whenever it
    /// has a known state: it is Claude Code's own view, it moves on an
    /// interrupt and on an answered prompt, and a subagent's tool calls
    /// cannot touch it. Whichever of the two was written later does not
    /// matter — the registry describes the process now, the payload the last
    /// event — with one exception: a hook `error` stands beside a registry
    /// `idle` it was written for (within `errorRegistryTolerance` of it, or
    /// after it), because `StopFailure` is the only source that knows the
    /// turn failed. A later turn (`busy`, `waiting`, or an `idle` written
    /// well after the error) retires it. With no usable registry entry the
    /// payload is the state, as before the registry was read.
    static func resolveStatus(
        payload: AgentStatusPayload?,
        registry entry: ClaudeSessionRegistryEntry?
    ) -> ResolvedStatus? {
        if let entry, let state = entry.agentState {
            if let payload, payload.state == .error, state == .idle,
               payload.updatedAt >= (entry.statusUpdatedAt ?? .distantPast)
                   .addingTimeInterval(-errorRegistryTolerance) {
                return ResolvedStatus(state: .error, updatedAt: payload.updatedAt, source: .hook, waitingReason: nil)
            }
            return ResolvedStatus(
                state: state,
                updatedAt: entry.statusUpdatedAt,
                source: .registry,
                waitingReason: state == .waiting ? ActiveAgentWaitingReason(registryValue: entry.waitingFor) : nil
            )
        }
        guard let payload else { return nil }
        return ResolvedStatus(state: payload.state, updatedAt: payload.updatedAt, source: .hook, waitingReason: nil)
    }

    static func parsePSOutput(
        _ output: String,
        observedAt: Date,
        payloads: [AgentStatusPayload],
        registry: [Int: ClaudeSessionRegistryEntry] = [:]
    ) -> [ActiveAgent] {
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
        let claudePIDs = Set(rows.compactMap { row -> Int? in
            guard pids.contains(row.pid),
                  let process = agentProcess(row, executablePath: executableByPID[row.pid]),
                  process.provider == .claude else { return nil }
            return row.pid
        })
        let payloadsByPID = latestPayloadsByPID(payloads, agentPIDs: claudePIDs)
        let claudeStarts = Dictionary(
            rows.lazy.filter { claudePIDs.contains($0.pid) }
                .map { ($0.pid, observedAt.addingTimeInterval(-$0.elapsedSeconds)) },
            uniquingKeysWith: { first, _ in first }
        )
        let registryPins = registrySessionPins(registry, processes: claudeStarts, observedAt: observedAt)
        return parseProcessRows(
            rows,
            observedAt: observedAt,
            executableLookup: { executableByPID[$0] },
            cwdLookup: { cwdByPID[$0] },
            resolveSession: sessionResolver(
                payloadsByPID: payloadsByPID,
                registryPins: registryPins,
                identified: { identifiedClaudeSession(sessionID: $0, cwd: $1, observedAt: $2) },
                heuristic: { query, cwd in
                    currentSession(
                        provider: query.provider,
                        cwd: cwd,
                        startedAt: query.startedAt,
                        observedAt: query.observedAt,
                        codexRolloutIdentifier: query.codexRolloutIdentifier,
                        codexRolloutFiles: codexRolloutFiles
                    )
                }
            )
        )
    }

    /// Everything the session-resolution strategy may consider for one process.
    struct SessionQuery {
        let provider: Provider
        let pid: Int
        let cwd: String?
        let startedAt: Date
        let observedAt: Date
        let codexRolloutIdentifier: String?
        /// False when several same-provider agents share this cwd — the
        /// newest-file heuristic must not guess between them.
        let isSoleAgentForCWD: Bool
    }

    /// A transcript pin from the registry: the session id Claude Code itself
    /// records for a PID. Tried before the hook's pin, which names the same
    /// session but only once a hook event has fired, and is gone after a
    /// `/clear` until the next one; it is also what attributes transcripts
    /// with the hooks switched off.
    struct RegistrySessionPin: Equatable, Sendable {
        let sessionID: String
        let cwd: String?
    }

    /// One pin per live Claude PID whose entry passes the PID-lifetime guard
    /// and names a session no other live Claude process names. Two processes
    /// cannot both be one session, but a helper process spawned with a
    /// session's environment can register under its id, and a pin would list
    /// that session twice with its spend counted twice; so neither gets one,
    /// and both fall back to the hook's pin.
    static func registrySessionPins(
        _ registry: [Int: ClaudeSessionRegistryEntry],
        processes: [Int: Date],
        observedAt: Date
    ) -> [Int: RegistrySessionPin] {
        var pins: [Int: RegistrySessionPin] = [:]
        var holders: [String: Int] = [:]
        for (pid, startedAt) in processes {
            guard let entry = ClaudeSessionRegistry.entry(
                      for: pid, processStartedAt: startedAt, observedAt: observedAt, in: registry),
                  let sessionID = entry.sessionID,
                  isSafeSessionFilename(sessionID) else { continue }
            pins[pid] = RegistrySessionPin(sessionID: sessionID, cwd: entry.cwd)
            holders[sessionID, default: 0] += 1
        }
        return pins.filter { holders[$0.value.sessionID] == 1 }
    }

    /// The one session-resolution strategy: a pinned session ID — the
    /// registry's, else the hook's — ties a Claude PID to its exact transcript
    /// and beats the newest-file heuristic (it stays usable when several
    /// agents share a working directory); the heuristic itself runs only for
    /// a directory's single agent or an identified Codex rollout. Tests inject
    /// this same shape with fake leaf lookups, so the precedence they exercise
    /// is the production one.
    static func sessionResolver(
        payloadsByPID: [Int: AgentStatusPayload],
        registryPins: [Int: RegistrySessionPin] = [:],
        identified: @escaping (String, String, Date) -> ActiveAgentSession?,
        heuristic: @escaping (SessionQuery, String) -> ActiveAgentSession?
    ) -> (SessionQuery) -> ActiveAgentSession? {
        { query in
            if query.provider == .claude {
                var pins: [(sessionID: String, cwd: String?)] = []
                if let pin = registryPins[query.pid] {
                    pins.append((pin.sessionID, pin.cwd))
                }
                if let payload = hookPayload(for: query.pid, startedAt: query.startedAt, payloadsByPID: payloadsByPID) {
                    pins.append((payload.sessionID, payload.cwd))
                }
                // Claude Code names a transcript directory after the directory
                // the session was launched from, while the registry and the
                // hook report the session's *current* cwd. An `/add-dir` or a
                // cd makes those differ, and then the reported cwd alone
                // derives a project key no directory has — so try the process
                // cwd as well before giving up on a pinned transcript. Order
                // matters: the same session id can exist under two project
                // keys, and the process cwd is the weaker signal of the two.
                var tried: Set<String> = []
                for pin in pins {
                    for cwd in [pin.cwd, query.cwd].compactMap({ $0 })
                    where tried.insert(pin.sessionID + "\u{0}" + cwd).inserted {
                        if let session = identified(pin.sessionID, cwd, query.observedAt) {
                            return session
                        }
                    }
                }
                // Pinned but not on disk under either key — not written yet,
                // or filed elsewhere. The heuristic lists the same directory
                // and can only return some other session's transcript, so the
                // row stays state-only until a later tick finds the real one.
                // A payload written without a session id carries the cwd in
                // its place (manual helper use); that pins nothing.
                if pins.contains(where: { isSafeSessionFilename($0.sessionID) }) { return nil }
            }
            guard let cwd = query.cwd,
                  query.codexRolloutIdentifier != nil || query.isSoleAgentForCWD else { return nil }
            return heuristic(query, cwd)
        }
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
        resolveSession: (SessionQuery) -> ActiveAgentSession?,
        executableLookup: (Int) -> String? = { _ in nil }
    ) -> [ActiveAgent] {
        parseProcessRows(
            processRows(from: output),
            observedAt: observedAt,
            executableLookup: executableLookup,
            cwdLookup: cwdLookup,
            resolveSession: resolveSession
        )
    }

    private static func parseProcessRows(
        _ rows: [ProcessRow],
        observedAt: Date,
        executableLookup: (Int) -> String?,
        cwdLookup: (Int) -> String?,
        resolveSession: (SessionQuery) -> ActiveAgentSession?
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
                let soleForCWD = candidate.cwd.map { cwd in
                    groupCounts[SessionGroup(provider: candidate.provider, cwd: cwd), default: 0] <= 1
                } ?? false
                let session = resolveSession(SessionQuery(
                    provider: candidate.provider,
                    pid: candidate.row.pid,
                    cwd: candidate.cwd,
                    startedAt: candidate.startedAt,
                    observedAt: observedAt,
                    codexRolloutIdentifier: candidate.codexRolloutIdentifier,
                    isSoleAgentForCWD: soleForCWD
                ))
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
            if arguments.contains("/usage") { return true }
            // Claude Desktop's own main process is a `Claude` executable too
            // (/Applications/Claude.app/Contents/MacOS/Claude), with cwd `/`.
            // Its bundled Claude Code sits under Application Support/Claude/
            // claude-code/<version>/<hash>/claude.app/Contents/MacOS/claude
            // and stays an agent, like the Codex rule below.
            let path = process.executablePath.lowercased()
            return path.hasSuffix(".app/contents/macos/claude") && !path.contains("/claude-code/")
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

    static func cwdMap(for pids: [Int]) -> [Int: String] {
        let uniquePIDs = Array(Set(pids)).sorted()
        guard !uniquePIDs.isEmpty else { return [:] }
        // lsof exits 1 when any requested PID is gone — a `claude -p` that
        // ended between the ps snapshot and this call — and still prints the
        // cwd of every live one. Refusing that status dropped every cwd of
        // the tick, and with them every unpinned session. The locale is
        // stated because a login-item launch has none, and without one lsof
        // prints a non-ASCII path as `\xe6\x97\xa5…`, which matches no
        // project key and no transcript cwd.
        let output = runProcess(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-p", uniquePIDs.map(String.init).joined(separator: ","), "-d", "cwd", "-Fpn"],
            timeout: 1,
            environment: ["LC_ALL": "C.UTF-8"],
            acceptingExitStatuses: [0, 1]
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

    /// `environment` replaces the inherited one when given; nil inherits.
    static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        acceptingExitStatuses: Set<Int32> = [0]
    ) -> String {
        runProcessResult(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            environment: environment,
            acceptingExitStatuses: acceptingExitStatuses
        ).output
    }

    private static func runProcessResult(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        acceptingExitStatuses: Set<Int32> = [0]
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
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
        // Lossy on purpose: ps prints argv bytes raw, and one process anywhere
        // with a non-UTF-8 argument made the whole listing undecodable, which
        // emptied the session list (and its parse cache) for as long as that
        // process lived. The bad bytes become U+FFFD; every other row parses.
        let output = String(decoding: finalOutputData, as: UTF8.self)
        let stderr = String(decoding: finalStderrData, as: UTF8.self)
        guard acceptingExitStatuses.contains(process.terminationStatus) else {
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

    /// Exact transcript lookup for a hook-reported session ID. Both inputs are
    /// untrusted (they come from hook payloads) and both become path
    /// components, so anything that could escape the projects root is refused:
    /// the ID by charset, the cwd by requiring an absolute path and confirming
    /// the resolved directory still sits under the projects root.
    static func identifiedClaudeSession(
        sessionID: String,
        cwd: String,
        observedAt: Date,
        projectsRoot: URL? = nil
    ) -> ActiveAgentSession? {
        guard isSafeSessionFilename(sessionID), cwd.hasPrefix("/") else { return nil }
        let base = (projectsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true))
            .resolvingSymlinksInPath()
        // Traversal is ruled out on the *constructed* path, not the resolved
        // one. `claudeProjectKey` maps every character outside `[A-Za-z0-9]`
        // to `-`, so the key is always a single component and cannot walk out
        // of `base`; assert that here so a later change to the mangling cannot
        // quietly reintroduce a traversal.
        //
        // Deliberately no containment check on the resolved path: Claude Code's
        // SessionStart hook symlinks `projects/<key>` into a shared store, so
        // requiring the resolved directory to sit under `projects/` refuses the
        // layout Claude Code itself creates and loses the transcript for every
        // session on such a machine. It also bought nothing — planting that
        // symlink needs write access to `projects/`, and anyone holding it can
        // drop a crafted transcript in directly. `latestClaudeSession` (the
        // heuristic path) has always followed these symlinks; this is the same
        // rule, applied consistently.
        let key = claudeProjectKey(for: cwd)
        guard !key.isEmpty, !key.contains("/"), key != ".", key != ".." else { return nil }
        let url = base
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        guard let modifiedAt = modificationDate(for: url),
              modifiedAt <= observedAt.addingTimeInterval(60) else { return nil }
        let metadata = claudeMetadata(from: url)
        return ActiveAgentSession(
            id: metadata.sessionID ?? sessionID,
            projectPath: metadata.cwd ?? cwd,
            projectName: projectName(for: metadata.cwd ?? cwd),
            branch: metadata.branch,
            lastUpdatedAt: modifiedAt,
            source: "claude jsonl",
            logPath: url.path
        )
    }

    static func isSafeSessionFilename(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// The newest recent transcript under this cwd's key that was launched
    /// from this cwd. The launch check matters because two keys can be one
    /// directory: Claude Code's SessionStart hook symlinks every checkout of a
    /// repo into one shared store, and the newest file there was another
    /// checkout's live session — listed twice, its spend counted twice in the
    /// group. A transcript naming no cwd is accepted as before.
    static func latestClaudeSession(
        cwd: String,
        startedAt: Date,
        observedAt: Date,
        projectsRoot: URL? = nil
    ) -> ActiveAgentSession? {
        let root = (projectsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true))
            .appendingPathComponent(claudeProjectKey(for: cwd), isDirectory: true)
            .resolvingSymlinksInPath()
        let candidates = sessionFiles(
            under: root,
            matching: { $0.pathExtension == "jsonl" },
            startedAt: startedAt,
            observedAt: observedAt
        )
        // Each check reads a transcript head (256 KB), so a store full of the
        // other checkout's recent sessions is not read in full every tick.
        for candidate in candidates.prefix(32) {
            let metadata = claudeMetadata(from: candidate.url)
            if let launchCWD = metadata.cwd, launchCWD != cwd { continue }
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
        return nil
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

    /// What one transcript says about its session: spend so far, and the
    /// identity facts (model, effort, title) that ride along in the same scan.
    /// Spend is nil until a record has been counted; identity is independent
    /// of it, so a session titled before its first reply is still titled.
    struct SessionUsageSummary: Sendable, Equatable {
        let tokenCount: Int?
        let estimatedCostUSD: Double?
        /// Model behind the most recent token-bearing record, i.e. what the
        /// session is running now. Nil when no record named one.
        let model: String?
        /// Reasoning effort on that same record. Nil when it carried none.
        let effort: String?
        /// The session's title: the newest custom title wins over the newest
        /// generated one whatever order they were written in.
        let title: String?
    }

    static func enrichSessionUsage(
        _ agents: [ActiveAgent],
        claudeCache: ClaudeUsageCache = .memoryOnly,
        history: (any HistoryIngesting)? = nil
    ) async -> [ActiveAgent] {
        await PricingService.shared.ensureLoaded()
        // Forget sessions that are no longer running: titles and Codex totals
        // are kept per main transcript, and keeping one for every transcript
        // ever enriched would grow without bound over a long uptime. Claude's
        // records live in the usage scan's cache, which the scans prune.
        let mains = agents.compactMap { agent in
            agent.session?.logPath.flatMap { LogFileFingerprint.current(for: URL(fileURLWithPath: $0)) }
        }
        await claudeTitleCache.prune(keeping: mains)
        await codexTotalsCache.prune(keeping: mains)
        var enriched: [ActiveAgent] = []
        for var agent in agents {
            if let session = agent.session, session.logPath != nil {
                agent.session = await sessionWithUsage(session, provider: agent.provider, observedAt: agent.observedAt,
                                                       claudeCache: claudeCache, history: history)
            }
            enriched.append(agent)
        }
        return enriched
    }

    /// The session with spend and identity filled in from its transcript(s).
    /// Model, effort and title come from the main transcript only; tokens and
    /// cost add every subagent transcript. A Claude session's records are the
    /// usage scan's own (`ClaudeJSONLScanner.fileUsages`, through
    /// `claudeCache`), so the row counts each request as the usage report and
    /// the history do.
    static func sessionWithUsage(
        _ session: ActiveAgentSession,
        provider: Provider,
        observedAt: Date,
        claudeCache: ClaudeUsageCache = .memoryOnly,
        history: (any HistoryIngesting)? = nil
    ) async -> ActiveAgentSession {
        guard let logPath = session.logPath else { return session }
        var session = session
        let mainURL = URL(fileURLWithPath: logPath)
        func show(_ summary: SessionUsageSummary) {
            session.tokenCount = summary.tokenCount
            session.estimatedCostUSD = summary.estimatedCostUSD
            session.model = summary.model
            session.effort = summary.effort
            session.title = summary.title
        }
        guard provider == .claude else {
            if provider == .codex { show(await codexSummary(url: mainURL)) }
            session.subagents = []
            return session
        }
        let subagentURLs = subagentTranscripts(for: logPath, provider: provider)
        let usages = await ClaudeJSONLScanner.fileUsages(([mainURL] + subagentURLs).map(scanSpelling),
                                                         cache: claudeCache, history: history)
        let main = usages[0]
        show(await claudeSummary(main, titles: await claudeTitles(url: mainURL)))
        let (subagents, subagentUsages) = await subagentSummaries(
            Array(zip(subagentURLs, usages.dropFirst())),
            observedAt: observedAt
        )
        session.subagents = subagents
        guard !subagentUsages.isEmpty else { return session }
        // The session's figure counts each request once across all of its
        // transcripts, picked the way the usage report picks it: a request
        // two of them carry (a resumed workflow agent's copy) is one request.
        var selection = ClaudeJSONLScanner.UsageSelection()
        selection.add(main)
        for usage in subagentUsages { selection.add(usage) }
        let merged = await priced(selection.countsByModel())
        if merged.tokenCount > 0 {
            session.tokenCount = merged.tokenCount
            session.estimatedCostUSD = merged.costUSD
        }
        return session
    }

    /// `url` spelled the way the usage scan lists it: `jsonlFiles` resolves
    /// the symlink a `projects/<key>` entry may be (a session's `logPath`
    /// from the hook or the registry goes through it), and the scan's cache
    /// and the history key on that spelling. Read through any other, the same
    /// transcript would be cached and recorded twice. Rows keep showing the
    /// path they were given.
    static func scanSpelling(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent, isDirectory: false)
    }

    /// Subagent transcripts of a Claude session: `agent-<id>.jsonl` under the
    /// `subagents/` directory named after the main transcript, plus the agents
    /// of every Workflow run, which Claude Code files one level further down as
    /// `subagents/workflows/<runID>/agent-<id>.jsonl` (the `journal.jsonl`
    /// beside them is not a transcript and fails the name check). Derived from
    /// an already-attributed `logPath` only — never from hook input — so it
    /// adds no path component the hook could choose; the filename and the run
    /// directory are still checked against the same charset as a session id,
    /// and anything else in the directories (meta files, symlinks, a stray
    /// file, a deeper directory) is ignored. Direct subagents first, then each
    /// run in name order, so a tick reads them in one order.
    static func subagentTranscripts(for logPath: String, provider: Provider) -> [URL] {
        guard provider == .claude else { return [] }
        let directory = URL(fileURLWithPath: logPath)
            .deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
        let workflows = directory.appendingPathComponent("workflows", isDirectory: true)
        return agentTranscripts(in: directory)
            + subdirectories(of: workflows)
                .filter { isSafeSessionFilename($0) }
                .sorted()
                .flatMap { agentTranscripts(in: workflows.appendingPathComponent($0, isDirectory: true)) }
    }

    /// The `agent-<id>.jsonl` regular files directly inside `directory`, by name.
    private static func agentTranscripts(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { url in
                guard subagentID(fromTranscriptName: url.lastPathComponent) != nil else { return false }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            // Re-anchored on the main transcript's path: the listing comes back
            // with symlinks resolved (`/var` → `/private/var`), and the cache is
            // keyed by path, so the subagent files must be spelled the way the
            // session's own file is.
            .map { directory.appendingPathComponent($0.lastPathComponent, isDirectory: false) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Names of the real (non-symlink) subdirectories of `directory`; empty
    /// when it does not exist.
    private static func subdirectories(of directory: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return url.lastPathComponent
        }
    }

    /// `agent-<id>.jsonl` → `<id>`, for names in the session-id charset only.
    static func subagentID(fromTranscriptName name: String) -> String? {
        let prefix = "agent-"
        let suffix = ".jsonl"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              name.count > prefix.count + suffix.count else { return nil }
        let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return isSafeSessionFilename(id) ? id : nil
    }

    /// Meta files are a couple of hundred bytes; anything past this is not one
    /// Claude Code wrote and is ignored rather than parsed.
    private static let subagentMetaByteCap = 64 * 1024

    /// The subagent rows, plus the records of each transcript that has one,
    /// for the session's own figure.
    private static func subagentSummaries(
        _ transcripts: [(URL, ClaudeFileUsage)],
        observedAt: Date
    ) async -> ([ActiveSubagent], [ClaudeFileUsage]) {
        var subagents: [ActiveSubagent] = []
        var usages: [ClaudeFileUsage] = []
        for (url, usage) in transcripts {
            guard let id = subagentID(fromTranscriptName: url.lastPathComponent),
                  let modifiedAt = modificationDate(for: url) else { continue }
            usages.append(usage)
            // A subagent's title is never shown, so none is read.
            let summary = await claudeSummary(usage, titles: ClaudeSessionTitles())
            let meta = subagentMetadata(for: url)
            subagents.append(ActiveSubagent(
                id: id,
                logPath: url.path,
                lastUpdatedAt: modifiedAt,
                observedAt: observedAt,
                description: meta.description ?? firstPrompt(in: url),
                agentType: meta.agentType,
                tokenCount: summary.tokenCount,
                estimatedCostUSD: summary.estimatedCostUSD,
                model: summary.model,
                effort: summary.effort
            ))
        }
        // Newest activity first: what is running now sits above what finished.
        let rows = subagents.sorted { lhs, rhs in
            if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt > rhs.lastUpdatedAt }
            return lhs.id < rhs.id
        }
        return (rows, usages)
    }

    /// `description` and `agentType` from the sibling `agent-<id>.meta.json`.
    static func subagentMetadata(for transcript: URL) -> (description: String?, agentType: String?) {
        let url = transcript.deletingPathExtension().appendingPathExtension("meta.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        // Read one byte past the cap so an oversized file is recognised as such
        // instead of being parsed truncated.
        guard let data = try? handle.read(upToCount: subagentMetaByteCap + 1),
              data.count <= subagentMetaByteCap,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        return (object["description"] as? String, object["agentType"] as? String)
    }

    /// The first user record's text, for a subagent whose meta file names no
    /// description. `firstLines` already bounds the read; `SessionLabel` bounds
    /// what a row shows of it.
    private static func firstPrompt(in url: URL) -> String? {
        for line in firstLines(of: url, maxLines: 40) {
            guard let object = jsonObject(from: line),
                  object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String { return text }
            if let blocks = message["content"] as? [[String: Any]] {
                return blocks.lazy.compactMap { $0["text"] as? String }.first
            }
            return nil
        }
        return nil
    }

    /// Partial parse of one Codex rollout. Cached so an actively-appended log
    /// resumes at the last consumed line boundary rather than being re-read
    /// from the top: the popover polls this every refresh tick while it is
    /// open, and a busy session's log only grows.
    private struct CodexSessionTotals: Sendable {
        var totalsByModel: [String: TokenCounts] = [:]
        /// Codex rollouts name the model in a turn_context line and then emit
        /// bare `token_count` events, so a resume has to remember the last one.
        var lastModel = "gpt-5-codex"
        /// Model behind the newest counted record. Deliberately *not* the newest
        /// model seen: a Codex `turn_context` can name a model before that turn
        /// spends anything, and a session that has produced no tokens under a
        /// model is not running it yet.
        var currentModel: String? = nil
    }

    /// A Claude transcript's titles. They arrive on their own records
    /// (`ai-title` / `custom-title`), each kind overwriting its predecessor,
    /// and are kept apart because a generated title can land after a user-set
    /// one and must not displace it. Display text taken from the conversation,
    /// so it is read here, held in memory only, and never reaches the usage
    /// cache or the history.
    private struct ClaudeSessionTitles: Sendable {
        var aiTitle: String? = nil
        var customTitle: String? = nil

        var title: String? { customTitle ?? aiTitle }
    }

    static func sessionUsageSummary(
        provider: Provider, url: URL, claudeCache: ClaudeUsageCache = .memoryOnly
    ) async -> SessionUsageSummary? {
        switch provider {
        case .claude:
            let usage = await ClaudeJSONLScanner.fileUsages([scanSpelling(url)], cache: claudeCache)[0]
            return await claudeSummary(usage, titles: await claudeTitles(url: url))
        case .codex:
            return await codexSummary(url: url)
        case .copilot:
            return nil
        }
    }

    /// One transcript read for what this service still parses itself (Codex
    /// totals, Claude titles), resumed at the last line boundary `cache`
    /// holds for it, with a trailing record that is not yet newline-terminated
    /// folded in for display. Only the clean line-boundary state is cached, so
    /// a resume can't double-count; the trailing record is re-read from there
    /// once it is complete.
    private static func incrementalParse<Value: Sendable>(
        _ url: URL,
        cache: LogFileParseCache<Value>,
        empty: Value,
        consume: (JSONLLineReader.LogLine, inout Value) -> Void
    ) async -> Value {
        let fingerprint = LogFileFingerprint.current(for: url)
        if let fingerprint, let cached = await cache.value(for: fingerprint) {
            return cached
        }
        var value = empty
        var startOffset: Int64 = 0
        if let fingerprint, let base = await cache.incrementalBase(for: fingerprint) {
            value = base.value
            startOffset = base.parsedBytes
        }
        let result = try? JSONLLineReader.forEachCompleteLine(in: url, fromOffset: startOffset) { line in
            consume(line, &value)
        }
        if let fingerprint {
            await cache.store(value, for: fingerprint, parsedBytes: result?.consumed ?? startOffset)
        }
        guard let trailing = result?.trailing else { return value }
        var display = value
        JSONLLineReader.withLine(trailing) { consume($0, &display) }
        return display
    }

    /// A Claude transcript's title as its session row would show it (custom,
    /// else generated), for naming a task's session that is not in the rows
    /// (`TaskSessionLabel.resolve`). The rows' own parser and cache.
    static func claudeTranscriptTitle(at url: URL) async -> String? {
        await claudeTitles(url: url).title
    }

    private static func claudeTitles(url: URL) async -> ClaudeSessionTitles {
        await incrementalParse(url, cache: claudeTitleCache, empty: ClaudeSessionTitles()) { line, titles in
            consumeTitle(line: line, into: &titles)
        }
    }

    static func clearSessionUsageCacheForTests() async {
        await codexTotalsCache.clear()
        await claudeTitleCache.clear()
        await ClaudeUsageCache.memoryOnly.memory.clear()
    }

    /// A Claude transcript's row: its records' spend, model and effort of the
    /// request it counted last, and its title.
    private static func claudeSummary(_ usage: ClaudeFileUsage, titles: ClaudeSessionTitles) async -> SessionUsageSummary {
        let spend = await priced(usage.countsByModel())
        let latest = usage.latestCounted
        return SessionUsageSummary(
            tokenCount: spend.tokenCount > 0 ? spend.tokenCount : nil,
            estimatedCostUSD: spend.costUSD,
            model: latest?.model,
            effort: latest?.effort,
            title: titles.title
        )
    }

    private static func codexSummary(url: URL) async -> SessionUsageSummary {
        let totals = await incrementalParse(url, cache: codexTotalsCache, empty: CodexSessionTotals()) { line, totals in
            consumeCodex(line: line, into: &totals)
        }
        let spend = await priced(totals.totalsByModel)
        return SessionUsageSummary(
            tokenCount: spend.tokenCount > 0 ? spend.tokenCount : nil,
            estimatedCostUSD: spend.costUSD,
            model: totals.currentModel,
            effort: nil,
            title: nil
        )
    }

    /// Tokens and their cost under the current price table; no cost until a
    /// token has been counted.
    private static func priced(_ byModel: [String: TokenCounts]) async -> (tokenCount: Int, costUSD: Double?) {
        let tokenCount = byModel.values.reduce(0) { total, counts in
            total + totalTokens(in: counts)
        }
        guard tokenCount > 0 else { return (0, nil) }
        await PricingService.shared.ensureLoaded()
        var total = 0.0
        for (model, counts) in byModel {
            total += await PricingService.shared.cost(model: model, counts: counts)
        }
        return (tokenCount, total)
    }

    /// Cheap per-line pre-filters. These run over whole session transcripts, so
    /// they must not go through `String.contains`, which is locale-aware and
    /// allocates per candidate position.
    private static let tokenCountMarker = JSONLLineReader.Marker("token_count")
    private static let modelMarker = JSONLLineReader.Marker("\"model\"")
    /// Matches `"type":"ai-title"` and `"type":"custom-title"`; measured against
    /// a 190k-line transcript, every hit was one of the two.
    private static let titleMarker = JSONLLineReader.Marker("-title\"")
    /// How far into a line the marker is looked for. Title records start with
    /// their type, so the reader can check a bounded prefix.
    static let titleSearchLength = 64

    private static func consumeTitle(line: JSONLLineReader.LogLine, into titles: inout ClaudeSessionTitles) {
        guard line.contains(Self.titleMarker, withinFirst: Self.titleSearchLength),
              let object = line.jsonObject() else { return }
        switch object["type"] as? String {
        case "custom-title":
            // An empty custom title is the user clearing theirs.
            let title = (object["customTitle"] as? String) ?? ""
            titles.customTitle = title.isEmpty ? nil : title
        case "ai-title":
            titles.aiTitle = object["aiTitle"] as? String
        default:
            break
        }
    }

    private static func consumeCodex(
        line: JSONLLineReader.LogLine,
        into totals: inout CodexSessionTotals
    ) {
        // Skip the JSON parse for lines that carry neither a model nor a
        // token_count event — the bulk of a rollout log.
        guard line.contains(Self.tokenCountMarker) || line.contains(Self.modelMarker),
              let object = line.jsonObject(),
              let payload = object["payload"] as? [String: Any] else { return }
        if let nextModel = payload["model"] as? String {
            totals.lastModel = nextModel
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
        add(counts, to: &totals.totalsByModel, model: totals.lastModel)
        totals.currentModel = totals.lastModel
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

    /// The directory Claude Code files a cwd's transcripts under: every UTF-16
    /// code unit outside `[A-Za-z0-9]` becomes `-` (its regex runs without the
    /// `u` flag, so an astral character becomes two). Mapping only `/` and ` `
    /// missed every worktree — `.claude/worktrees/sample_12345` is filed as
    /// `--claude-worktrees-sample-12345` — so those sessions had no transcript,
    /// no model, no spend. A key longer than 200 characters gets a hash suffix
    /// in Claude Code that is not reproduced here; none on this machine is.
    static func claudeProjectKey(for cwd: String) -> String {
        String(decoding: cwd.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return unit
            default: return 0x2D
            }
        }, as: UTF16.self)
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
        // Lossy: the slice ends wherever 256 KB lands, and a cut inside a
        // multi-byte character made the strict decode nil — the whole head,
        // session id and launch cwd included, was lost for 1 transcript in 40
        // past that size (CJK prompts). Only the cut-off last line carries a
        // U+FFFD, and that line is not valid JSON anyway.
        let content = String(decoding: data, as: UTF8.self)
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
