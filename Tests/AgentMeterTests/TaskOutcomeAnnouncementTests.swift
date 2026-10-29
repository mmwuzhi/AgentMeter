import AgentStatusCore
@testable import AgentMeter
import Foundation
import XCTest

/// What `TaskSessionLabel.resolve` asked the transcript reader for.
private actor TitleReads {
    var paths: [String] = []
    func add(_ path: String) { paths.append(path) }
    /// How many reads so far, this one included.
    func next(_ path: String) -> Int {
        paths.append(path)
        return paths.count
    }
}

final class TaskOutcomeAnnouncementTests: XCTestCase {
    private let launchedAt = Date(timeIntervalSince1970: 1_792_480_000)

    private func outcome(
        _ kind: TaskOutcome.Kind, ran duration: TimeInterval = 600, endingAt end: TimeInterval = 0,
        segment: Int = 0, origin: TaskLedgerTask.Origin = .human, crons: Bool = false,
        shells: Int = 0, error: String? = nil, reason: ActiveAgentWaitingReason? = nil
    ) -> TaskOutcome {
        let ended = launchedAt.addingTimeInterval(end)
        return TaskOutcome(
            kind: kind, confidence: .high, sessionID: "ffafe0d9-1111-2222-3333-444455556666", taskKey: "017d120c",
            segment: segment, origin: origin, occurredAt: ended, startedAt: ended.addingTimeInterval(-duration),
            endedAt: ended, cwd: "/Users/u/work/agentmeter", shellsStillRunning: shells, cronsArmed: crons,
            error: error, waitingReason: reason, id: "\(kind.rawValue)|x|\(segment)")
    }

    // MARK: Intent

    func testCompletedIsAnnouncedOnlyForAPersonsTaskOfAMinuteOrMore() {
        typealias Reason = TaskOutcomeAnnouncement.Reason
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed), launchedAt: launchedAt), .notify)
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, ran: 60), launchedAt: launchedAt), .notify)
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, ran: 59.9), launchedAt: launchedAt),
                       .recordOnly(reason: Reason.belowMinimumDuration))
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, origin: .report), launchedAt: launchedAt),
                       .recordOnly(reason: Reason.reportOrigin))
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, crons: true), launchedAt: launchedAt),
                       .recordOnly(reason: Reason.cronsArmed))
        // A follow-up segment is judged on its own length.
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, ran: 20, segment: 1), launchedAt: launchedAt),
                       .recordOnly(reason: Reason.belowMinimumDuration))
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.completed, ran: 90, segment: 1), launchedAt: launchedAt), .notify)
    }

    func testFailedAndWaitingIgnoreTheMinimumInterruptedIsNeverAnnounced() {
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.failed, ran: 3), launchedAt: launchedAt), .notify)
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.waiting, ran: 60), launchedAt: launchedAt), .notify)
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.interrupted), launchedAt: launchedAt),
                       .recordOnly(reason: TaskOutcomeAnnouncement.Reason.notAnnounced))
        // Item 2: an uncertain end is never announced, whatever its length.
        XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(.uncertain, ran: 3600, shells: 1), launchedAt: launchedAt),
                       .recordOnly(reason: TaskOutcomeAnnouncement.Reason.backgroundShellRunning))
    }

    func testOutcomesFromBeforeLaunchAreRecordedOnly() {
        for kind in [TaskOutcome.Kind.completed, .failed, .waiting] {
            XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(kind, endingAt: -121), launchedAt: launchedAt),
                           .recordOnly(reason: TaskOutcomeAnnouncement.Reason.beforeLaunch), "\(kind)")
            XCTAssertEqual(TaskOutcomeAnnouncement.intent(for: outcome(kind, endingAt: -119), launchedAt: launchedAt),
                           .notify, "\(kind)")
        }
    }

    // MARK: Event

    func testCompletedEventLeadsWithTheStatusAndNamesTheSessionByItsTitle() throws {
        let label = TaskSessionLabel(project: "AgentMeter", title: "Phase 1b\nnotifications\u{0007}")
        let event = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.completed, ran: 754, shells: 1),
                                                                 label: label, discoveredAt: launchedAt))
        XCTAssertEqual(event.kind, .taskCompleted)
        XCTAssertEqual(event.id, "completed|x|0")
        // On by default (2026-10-29): the status first, so truncation keeps
        // it, then the session as the session list names it.
        XCTAssertEqual(event.content.title, "Finished · Phase 1b notifications", "sanitized single line")
        XCTAssertEqual(event.content.body, "AgentMeter · Claude Code · ffafe0d9\n12m run · 1 background shell still running")
        XCTAssertEqual(event.content.notificationIdentifier, "agentmeter.task.ffafe0d9-1111-2222-3333-444455556666.017d120c")
        XCTAssertEqual(event.content.threadIdentifier, "agentmeter.task./Users/u/work/agentmeter")
        XCTAssertEqual(event.subject, AgentMeterEventSubject(
            provider: "claude", sessionID: "ffafe0d9-1111-2222-3333-444455556666", taskKey: "017d120c",
            projectPath: "/Users/u/work/agentmeter", sessionTitle: "Phase 1b notifications"))
        XCTAssertEqual(event.producerVersion, "task-outcome/1")
        XCTAssertEqual(event.occurredAt, launchedAt)

        // Switched off: project and short id in the banner, the title still
        // kept for the menu's list.
        let off = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.completed, ran: 754, shells: 1),
                                                               label: label, discoveredAt: launchedAt, showsSessionTitle: false))
        XCTAssertEqual(off.content.title, "Finished · AgentMeter")
        XCTAssertEqual(off.content.body, "Session ffafe0d9\n12m run · 1 background shell still running")
        XCTAssertEqual(off.subject.sessionTitle, "Phase 1b notifications")
    }

    func testWithoutATitleTheProjectAndShortIDNameIt() throws {
        let event = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.completed, ran: 3700, segment: 2),
                                                                 label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(event.content.title, "Finished · agentmeter", "the folder when no row names the project")
        XCTAssertEqual(event.content.body, "Session ffafe0d9\nFollow-up · 1h 1m run")
        XCTAssertNil(event.subject.sessionTitle, "no title is invented")
        // Never the task key (a prompt id) or the full session id as a title.
        XCTAssertFalse(event.content.title.contains("017d120c"))
        XCTAssertFalse((event.content.title + event.content.body).contains("ffafe0d9-1111"))
    }

    func testAHeadlessRunIsCalledSoNotTakenForTheUsersSession() throws {
        var run = outcome(.completed, ran: 180)
        run.launch = .headless
        let untitled = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: run, label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(untitled.content.title, "Finished · agentmeter")
        XCTAssertEqual(untitled.content.body, "Session ffafe0d9 · Headless run\n3m run")
        XCTAssertEqual(untitled.subject.sessionKind, "headless")
        let titled = try XCTUnwrap(TaskOutcomeAnnouncement.event(
            for: run, label: TaskSessionLabel(project: nil, title: "Batch the import chain"), discoveredAt: launchedAt))
        XCTAssertEqual(titled.content.body, "agentmeter · Headless run · ffafe0d9\n3m run")
        run.launch = .interactive
        let person = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: run, label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(person.content.body, "Session ffafe0d9\n3m run")
        XCTAssertEqual(person.subject.sessionKind, "interactive")
    }

    func testTheRegistrySaysWhichRunsAreHeadless() {
        XCTAssertEqual(TaskSessionLaunch(kind: "interactive", entrypoint: "claude-vscode"), .interactive)
        XCTAssertEqual(TaskSessionLaunch(kind: "interactive", entrypoint: "cli"), .interactive)
        XCTAssertEqual(TaskSessionLaunch(kind: "interactive", entrypoint: "sdk-py"), .interactive, "the kind says so")
        XCTAssertEqual(TaskSessionLaunch(kind: "print", entrypoint: "sdk-cli"), .headless)
        XCTAssertEqual(TaskSessionLaunch(kind: nil, entrypoint: "sdk-ts"), .headless)
        // Only known evidence: a kind or entrypoint this build does not know
        // says nothing, rather than calling the session a script's.
        XCTAssertNil(TaskSessionLaunch(kind: "sdk", entrypoint: nil))
        XCTAssertNil(TaskSessionLaunch(kind: "some-future-kind", entrypoint: "cli"))
        XCTAssertNil(TaskSessionLaunch(kind: nil, entrypoint: "sdk-future"))
        XCTAssertNil(TaskSessionLaunch(kind: nil, entrypoint: "claude-vscode"), "nothing assumed without the kind")
        XCTAssertNil(TaskSessionLaunch(kind: nil, entrypoint: nil))
        // A session: interactive when any entry is, headless only when all are.
        XCTAssertEqual(TaskSessionLaunch.combined([.headless, .interactive]), .interactive)
        XCTAssertEqual(TaskSessionLaunch.combined([.headless, .headless]), .headless)
        XCTAssertNil(TaskSessionLaunch.combined([.headless, nil]), "one entry unknown: not unambiguous")
        XCTAssertNil(TaskSessionLaunch.combined([]))
        let entry = ClaudeSessionRegistry.decode(Data(#"{"pid":42,"sessionId":"s","kind":"interactive","entrypoint":"claude-vscode"}"#.utf8))
        XCTAssertEqual(entry?.kind, "interactive")
        XCTAssertEqual(entry?.entrypoint, "claude-vscode")
        XCTAssertEqual(entry.map(TaskOutcomeRegistryReading.init)?.launch, .interactive)
    }

    func testFailedWaitingAndInterruptedWording() throws {
        let failed = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.failed, ran: 125, error: "rate_limit"),
                                                                  label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(failed.kind, .taskFailed)
        XCTAssertEqual(failed.content.title, "Failed · agentmeter")
        XCTAssertEqual(failed.content.body, "Session ffafe0d9\nRate limit · after 2m")
        let unknown = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.failed, error: "brand_new_kind"),
                                                                   label: nil, discoveredAt: launchedAt))
        XCTAssertTrue(unknown.content.body.hasSuffix("API error · after 10m"))

        let waiting = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.waiting, ran: 60, reason: .input),
                                                                   label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(waiting.kind, .taskWaiting)
        XCTAssertEqual(waiting.content.title, "Needs input · agentmeter")
        XCTAssertEqual(waiting.content.body, "Session ffafe0d9\nWaiting for your answer · 1m")
        XCTAssertEqual(waiting.content.notificationIdentifier,
                       try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.completed), label: nil, discoveredAt: launchedAt))
                        .content.notificationIdentifier,
                       "a wait and the end of the same task replace each other")

        let decision = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.waiting, ran: 60, reason: .dialog),
                                                                    label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(decision.content.body, "Session ffafe0d9\nWaiting for your decision · 1m")

        let uncertain = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.uncertain, ran: 125, shells: 2),
                                                                     label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(uncertain.kind, .taskUnknown)
        XCTAssertEqual(uncertain.content.title, "Status unconfirmed · agentmeter")
        XCTAssertEqual(uncertain.content.body, "Session ffafe0d9\n2 background tasks running at the last check · after 2m")
        // The shell may have ended since with no hook to say so: what was
        // seen, when, never that it still runs.
        XCTAssertFalse((uncertain.content.title + uncertain.content.body).contains("still running"))

        let interrupted = try XCTUnwrap(TaskOutcomeAnnouncement.event(for: outcome(.interrupted, ran: 45),
                                                                       label: nil, discoveredAt: launchedAt))
        XCTAssertEqual(interrupted.kind, .taskInterrupted)
        XCTAssertEqual(interrupted.content.title, "Interrupted · agentmeter")
        XCTAssertEqual(interrupted.content.body, "Session ffafe0d9\nStopped after 45s")
        XCTAssertNil(TaskOutcomeAnnouncement.event(for: outcome(.unresolved), label: nil, discoveredAt: launchedAt))
    }

    // MARK: Naming the session

    /// A wait found first is submitted first, even when naming its session
    /// takes longer than naming the end's: otherwise its "Needs input" would
    /// replace "Finished" under the identifier they share, and stay.
    @MainActor
    func testOutcomesAreSubmittedInTheOrderTheMonitorFoundThem() async throws {
        let suite = "agentmeter.tests.queue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = EventTestClock(launchedAt)
        let center = AuthorizationCenterStub(result: .success(true), status: .authorized)
        let manager = NotificationManager(authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" },
                                          eventStore: .inMemory(clock: clock.function), now: { clock.now })
        let path = "/Users/u/.claude/projects/-Users-u-work-agentmeter/ffafe0d9-1111-2222-3333-444455556666.jsonl"
        var wait = outcome(.waiting, ran: 90)
        wait.transcriptPath = path
        var end = outcome(.completed, ran: 600)
        end.transcriptPath = path
        let reads = TitleReads()
        let slowFirst: @Sendable (String, String) async -> String? = { path, _ in
            if await reads.next(path) == 1 { try? await Task.sleep(for: .milliseconds(300)) }
            return nil
        }
        let queue = TaskOutcomeQueue { outcome in
            await TaskOutcomeAnnouncement.announce(outcome, rows: [], manager: manager, launchedAt: self.launchedAt,
                                                   defaults: defaults, now: { clock.now }, transcriptTitle: slowFirst)
        }
        // Two monitor passes, as the monitor's queue hands them on.
        queue.enqueue([wait])
        queue.enqueue([end])
        for _ in 0..<3_000 where center.posted.count < 2 { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(center.posted.map(\.content.title), ["Needs input · agentmeter", "Finished · agentmeter"])
        XCTAssertEqual(center.delivered.count, 1, "one banner per task")
        XCTAssertEqual(center.delivered.values.first?.content.title, "Finished · agentmeter", "the end stays on screen")
    }

    @MainActor
    func testTheTitleComesFromTheLiveRowThenTheTranscriptThenNowhere() async throws {
        let session = "ffafe0d9-1111-2222-3333-444455556666"
        var withPath = outcome(.completed)
        withPath.transcriptPath = "/Users/u/.claude/projects/-Users-u-work-agentmeter/\(session).jsonl"
        func row(_ id: String, title: String?) -> ActiveAgent {
            ActiveAgent(provider: .claude, pid: 77, parentPID: 1, command: "claude", elapsedSeconds: 60, observedAt: launchedAt,
                        session: ActiveAgentSession(id: id, projectPath: "/Users/u/work/agentmeter", projectName: "AgentMeter",
                                                    branch: "main", lastUpdatedAt: nil, source: "test", title: title))
        }
        let reads = TitleReads()
        let transcript: @Sendable (String, String) async -> String? = { path, id in
            await reads.add(path)
            return "From the transcript\n"
        }

        let live = await TaskSessionLabel.resolve(for: withPath, rows: [row(session, title: "Fix the  quota\ttooltip")],
                                                  transcriptTitle: transcript)
        XCTAssertEqual(live, TaskSessionLabel(project: "AgentMeter", title: "Fix the quota tooltip"),
                       "the row's own text (ActiveAgentSession.displayTitle)")
        let readsAfterLive = await reads.paths
        XCTAssertTrue(readsAfterLive.isEmpty, "the row answers; the transcript is not read")

        let ended = await TaskSessionLabel.resolve(for: withPath, rows: [row("another-session", title: "Someone else's")],
                                                   transcriptTitle: transcript)
        XCTAssertEqual(ended.title, "From the transcript", "another session's row never names it")
        XCTAssertNil(ended.project)
        let readsAfterEnded = await reads.paths
        XCTAssertEqual(readsAfterEnded, [withPath.transcriptPath!])

        let none = await TaskSessionLabel.resolve(for: outcome(.completed), rows: [], transcriptTitle: transcript)
        XCTAssertNil(none.title, "no row, no transcript: no title")
    }

    func testOnlyTheSessionsOwnTranscriptNamesIt() async throws {
        let dir = historyTempDirectory()
        let session = "a1b2c3d4-aaaa-bbbb-cccc-ddddeeeeffff"
        let own = dir.appendingPathComponent("\(session).jsonl")
        let titles = #"{"type":"ai-title","aiTitle":"Generated title","sessionId":"\#(session)"}"# + "\n"
            + #"{"type":"custom-title","customTitle":"Renamed by the user","sessionId":"\#(session)"}"# + "\n"
        try Data(titles.utf8).write(to: own)
        let resolved = await TaskSessionLabel.transcriptTitle(path: own.path, sessionID: session)
        XCTAssertEqual(resolved, "Renamed by the user", "the rows' order: custom, then generated")

        let subagent = dir.appendingPathComponent("agent-a1b2c3.jsonl")
        try Data(titles.utf8).write(to: subagent)
        let fromSubagent = await TaskSessionLabel.transcriptTitle(path: subagent.path, sessionID: session)
        XCTAssertNil(fromSubagent, "a subagent's transcript never names the main session")
        let fromOther = await TaskSessionLabel.transcriptTitle(path: own.path, sessionID: "0000aaaa-other")
        XCTAssertNil(fromOther, "matched by session id only")
        let link = dir.appendingPathComponent("link/\(session).jsonl")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)
        let fromLink = await TaskSessionLabel.transcriptTitle(path: link.path, sessionID: session)
        XCTAssertNil(fromLink, "not through a symbolic link")
        let missing = await TaskSessionLabel.transcriptTitle(path: dir.appendingPathComponent("gone/\(session).jsonl").path,
                                                             sessionID: session)
        XCTAssertNil(missing, "a deleted transcript names nothing")
        let relative = await TaskSessionLabel.transcriptTitle(path: "\(session).jsonl", sessionID: session)
        XCTAssertNil(relative)
    }

    func testDurationFormat() {
        XCTAssertEqual(TaskOutcomeAnnouncement.format(0), "0s")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(59.4), "59s")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(60), "1m")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(3599), "59m")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(7200), "2h")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(7260), "2h 1m")
        XCTAssertEqual(TaskOutcomeAnnouncement.format(-5), "0s")
    }
}

final class TranscriptTailClassifierTests: XCTestCase {
    private func lines(_ records: [String]) -> Data { Data((records.joined(separator: "\n") + "\n").utf8) }

    /// C3 (REPL Esc during a tool, then Claude Code's bookkeeping records).
    func testMarkerFollowedByBookkeepingIsInterrupted() {
        let tail = lines([
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"The user doesn't want to proceed"}]}}"#,
            #"{"type":"attachment"}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
            #"{"type":"last-prompt"}"#, #"{"type":"ai-title"}"#, #"{"type":"cost-state"}"#,
            #"{"type":"file-history-snapshot"}"#, #"{"type":"cost-state"}"#,
        ])
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: tail, startsMidFile: false), .interrupted)
    }

    func testStringMarkerAndOtherEndings() {
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: lines([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"The keeper"}]}}"#,
            #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
            #"{"type":"cost-state"}"#,
        ]), startsMidFile: false), .interrupted)
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: lines([
            #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Sure."}],"stop_reason":"end_turn"}}"#,
        ]), startsMidFile: false), .other, "a later answer wins")
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: lines([
            #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[]}}"#,
        ]), startsMidFile: false), .interrupted, "meta and sidechain records are not the turn's")
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: lines([
            #"{"type":"user","message":{"content":"Please say [Request interrupted by user]"}}"#,
        ]), startsMidFile: false), .other)
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: Data(), startsMidFile: false), .other)
    }

    /// The 64 KB window starts mid-line: that partial line must not count.
    func testPartialFirstLineIsSkipped() {
        let partial = Data(#"interrupted by user]"}}"#.utf8) + lines([#"{"type":"cost-state"}"#])
        XCTAssertEqual(TranscriptTailClassifier.verdict(tail: partial, startsMidFile: true), .other)
    }

    func testReadsOnlyTheTailOfARealFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeter-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        let filler = String(repeating: #"{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}"# + "\n", count: 2_000)
        try Data((filler + #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"# + "\n"
                  + #"{"type":"cost-state"}"# + "\n").utf8).write(to: file)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0,
                             TranscriptTailClassifier.tailBytes)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: file.path), .interrupted)

        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: nil), .unavailable)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: dir.appendingPathComponent("missing.jsonl").path), .unavailable)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: "relative/s.jsonl"), .unavailable)
        let other = dir.appendingPathComponent("s.txt")
        try Data().write(to: other)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: other.path), .unavailable)
        let link = dir.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(TranscriptTailClassifier.verdict(atPath: link.path), .unavailable)
    }
}
