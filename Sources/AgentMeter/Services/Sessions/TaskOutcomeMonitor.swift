import AgentStatusCore
import Darwin
import Foundation
import os

/// One pass of the detector over every session, with what this run already
/// handed on. Each outcome goes out once per run; across runs the event
/// store's id dedup (`AgentMeterEventStore.record`) keeps a restart from
/// announcing it again.
struct TaskOutcomeTracker {
    var timing: TaskOutcomeDetector.Timing = .standard
    /// Outcome ids handed on (or, for `unresolved`, dropped) this run.
    private(set) var settled: Set<String> = []
    /// Transcript verdicts by turn, so a settled interrupted turn is not
    /// re-read on every pass.
    private var verdicts: [String: TaskTranscriptVerdict] = [:]
    /// Each session's last registry reading, to ride over a pass that missed
    /// it: Claude Code rewrites the file in place, and a read that lands
    /// mid-write twice is skipped (`ClaudeSessionRegistry.readAll`).
    private var lastReadings: [String: (reading: TaskOutcomeRegistryReading, at: Date)] = [:]
    /// The earliest stamp of the current wait, by turn, so a re-stamped
    /// `waiting` (Claude Code rewrites an unchanged status at times) does not
    /// restart the delay.
    private var waitingSince: [String: Date] = [:]
    static let maximumRemembered = 10_000
    static let registryCarryOver: TimeInterval = 3

    init(timing: TaskOutcomeDetector.Timing = .standard) {
        self.timing = timing
    }

    /// New outcomes (never `unresolved`) and when to look again.
    mutating func evaluate(
        ledgers: [TaskLedger],
        registry: [String: TaskOutcomeRegistryReading],
        payloads: [String: AgentStatusPayload],
        now: Date,
        transcript: (String?) -> TaskTranscriptVerdict
    ) -> (outcomes: [TaskOutcome], nextCheck: Date?) {
        var outcomes: [TaskOutcome] = []
        var nextCheck: Date?
        var turns: Set<String> = []
        for ledger in ledgers {
            let turn = ledger.task.map {
                "\(ledger.sessionID)|\($0.key)|\($0.segment)|\(HistoryTime.ms($0.lastPromptAt))"
            } ?? ledger.sessionID
            turns.insert(turn)
            let reading = self.reading(for: ledger, turn: turn, in: registry, now: now)
            let evaluation = TaskOutcomeDetector.evaluate(
                ledger,
                registry: reading,
                payload: payloads[ledger.sessionID],
                now: now,
                timing: timing,
                transcript: {
                    if let cached = verdicts[turn] { return cached }
                    let verdict = transcript(ledger.transcriptPath)
                    verdicts[turn] = verdict
                    return verdict
                }
            )
            if let check = evaluation.nextCheck { nextCheck = min(nextCheck ?? check, check) }
            for outcome in evaluation.outcomes where settled.insert(outcome.id).inserted {
                if outcome.kind != .unresolved { outcomes.append(outcome) }
            }
        }
        if settled.count > Self.maximumRemembered { settled.removeAll(keepingCapacity: true) }
        if verdicts.count > Self.maximumRemembered { verdicts.removeAll(keepingCapacity: true) }
        let sessions = Set(ledgers.map(\.sessionID))
        lastReadings = lastReadings.filter { sessions.contains($0.key) }
        waitingSince = waitingSince.filter { turns.contains($0.key) }
        return (outcomes, nextCheck)
    }

    private mutating func reading(
        for ledger: TaskLedger, turn: String, in registry: [String: TaskOutcomeRegistryReading], now: Date
    ) -> TaskOutcomeRegistryReading? {
        let sessionID = ledger.sessionID
        var reading = registry[sessionID]
        if let reading {
            lastReadings[sessionID] = (reading, now)
        } else if ledger.endedAt == nil, let last = lastReadings[sessionID],
                  now.timeIntervalSince(last.at) <= Self.registryCarryOver {
            reading = last.reading
        }
        if var waiting = reading, waiting.status == .waiting, let stamp = waiting.statusUpdatedAt {
            let first = min(waitingSince[turn] ?? stamp, stamp)
            waitingSince[turn] = first
            waiting.statusUpdatedAt = first
            return waiting
        }
        waitingSince[turn] = nil
        return reading
    }
}

/// Watches the turn ledgers and runs the detector: on a ledger change (a
/// directory watch on `agent-status/turns/`, where every write is an atomic
/// rename), and on a timer while something awaits time or the registry
/// (Claude Code rewrites its registry files in place, which a directory
/// watch does not see). With nothing pending it wakes every `idleInterval`.
/// All work runs on one private utility queue; outcomes go to `deliver`.
final class TaskOutcomeMonitor: @unchecked Sendable {
    struct Environment: Sendable {
        var ledgerDirectory: URL
        var readLedgers: @Sendable () -> [TaskLedger]
        /// Live processes' registry entries, by session id.
        var readRegistry: @Sendable () -> [String: TaskOutcomeRegistryReading]
        /// Status payloads, by session id.
        var readPayloads: @Sendable () -> [String: AgentStatusPayload]
        var transcriptVerdict: @Sendable (String?) -> TaskTranscriptVerdict
        /// Deletes ledgers last written before the cutoff whose session has
        /// no live process.
        var sweepLedgers: @Sendable (_ before: Date, _ liveSessions: Set<String>) -> Void
        var now: @Sendable () -> Date

        static func live() -> Environment {
            Environment(
                ledgerDirectory: TaskLedgerStore.directory,
                readLedgers: { TaskLedgerStore.readAll().map(\.ledger) },
                readRegistry: {
                    TaskOutcomeMonitor.liveRegistry(ClaudeSessionRegistry.readAll(),
                                                    processStart: TaskOutcomeMonitor.processStartDate, now: Date())
                },
                readPayloads: { TaskOutcomeMonitor.payloadsBySession(AgentStatusStore.readAll()) },
                transcriptVerdict: { TranscriptTailClassifier.verdict(atPath: $0) },
                sweepLedgers: { TaskOutcomeMonitor.sweepLedgers(in: TaskLedgerStore.directory, before: $0, liveSessions: $1) },
                now: { Date() }
            )
        }
    }

    static let idleInterval: TimeInterval = 30
    static let minimumInterval: TimeInterval = 0.25
    /// Ledger writes come in bursts (a prompt, then a Stop a second later).
    static let watchDebounce: TimeInterval = 0.25
    static let sweepInterval: TimeInterval = 3600
    /// A ledger untouched this long, for a session with no live process,
    /// has nothing left to tell.
    static let ledgerRetention: TimeInterval = 24 * 3600

    private let environment: Environment
    private let deliver: @Sendable ([TaskOutcome]) -> Void
    private let queue = DispatchQueue(label: "agentmeter.task-outcomes", qos: .utility)
    private var tracker: TaskOutcomeTracker
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var lastSweep: Date?
    private var running = false
    private static let logger = Logger(subsystem: "com.shu.agentmeter", category: "task-outcomes")

    init(
        environment: Environment = .live(),
        timing: TaskOutcomeDetector.Timing = .standard,
        deliver: @escaping @Sendable ([TaskOutcome]) -> Void
    ) {
        self.environment = environment
        self.deliver = deliver
        self.tracker = TaskOutcomeTracker(timing: timing)
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.pass() }
            timer.resume()
            self.timer = timer
            schedule(after: 0)
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            watcher?.cancel()
            watcher = nil
            timer?.cancel()
            timer = nil
        }
    }

    /// One pass now, on the caller's thread (tests).
    func evaluateNow() {
        queue.sync { pass() }
    }

    private func pass() {
        let now = environment.now()
        if running { ensureWatcher() }
        let registry = environment.readRegistry()
        if lastSweep.map({ now.timeIntervalSince($0) >= Self.sweepInterval }) ?? true {
            lastSweep = now
            environment.sweepLedgers(now.addingTimeInterval(-Self.ledgerRetention), Set(registry.keys))
        }
        let ledgers = environment.readLedgers()
        let payloads = ledgers.isEmpty ? [:] : environment.readPayloads()
        let result = tracker.evaluate(
            ledgers: ledgers, registry: registry, payloads: payloads, now: now,
            transcript: environment.transcriptVerdict)
        if !result.outcomes.isEmpty {
            // One line per outcome: kind, confidence and numbers only, never a
            // session, path or title.
            for outcome in result.outcomes {
                Self.logger.notice("AgentMeter: task outcome \(outcome.kind.rawValue, privacy: .public) confidence=\(outcome.confidence.rawValue, privacy: .public) segment=\(outcome.segment, privacy: .public) duration=\(Int(outcome.duration), privacy: .public)s")
            }
            deliver(result.outcomes)
        }
        guard running else { return }
        let delay = result.nextCheck.map { $0.timeIntervalSince(now) } ?? Self.idleInterval
        schedule(after: min(max(delay, Self.minimumInterval), Self.idleInterval))
    }

    private func schedule(after delay: TimeInterval) {
        timer?.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(100))
    }

    /// Opens the watch on the ledger directory, creating it (0700, as the
    /// helper does) when missing; reopens it after the directory was
    /// replaced.
    private func ensureWatcher() {
        if let watcher, !watcher.isCancelled { return }
        let path = environment.ledgerDirectory.path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
            }
            schedule(after: Self.watchDebounce)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// The live process's entry per session (newest status wins when two
    /// processes claim one session). An entry whose process is gone, or
    /// whose PID a later process reuses (the registry's own start-time
    /// guard, as the rows apply it), does not count.
    static func liveRegistry(
        _ entries: [Int: ClaudeSessionRegistryEntry],
        processStart: (Int) -> Date?,
        now: Date
    ) -> [String: TaskOutcomeRegistryReading] {
        var result: [String: (Date, TaskOutcomeRegistryReading)] = [:]
        for entry in entries.values {
            guard let sessionID = entry.sessionID, let started = processStart(entry.pid),
                  ClaudeSessionRegistry.entry(for: entry.pid, processStartedAt: started, observedAt: now, in: entries) != nil
            else { continue }
            let updated = entry.statusUpdatedAt ?? .distantPast
            if let existing = result[sessionID], existing.0 >= updated { continue }
            result[sessionID] = (updated, TaskOutcomeRegistryReading(entry))
        }
        return result.mapValues(\.1)
    }

    /// When the process started, from the kernel; nil when there is none.
    static func processStartDate(_ pid: Int) -> Date? {
        guard pid > 0, let value = pid_t(exactly: pid) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, value]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    static func sweepLedgers(in directory: URL, before cutoff: Date, liveSessions: Set<String>) {
        for (ledger, modifiedAt) in TaskLedgerStore.readAll(in: directory)
        where modifiedAt < cutoff && !liveSessions.contains(ledger.sessionID) {
            TaskLedgerStore.remove(sessionID: ledger.sessionID, in: directory)
        }
    }

    static func payloadsBySession(_ payloads: [AgentStatusPayload]) -> [String: AgentStatusPayload] {
        var result: [String: AgentStatusPayload] = [:]
        for payload in payloads where (result[payload.sessionID]?.updatedAt ?? .distantPast) < payload.updatedAt {
            result[payload.sessionID] = payload
        }
        return result
    }
}
