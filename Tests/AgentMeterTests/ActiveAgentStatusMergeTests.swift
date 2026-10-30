import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

/// How a row's state is decided between Claude Code's session registry and
/// the hook payload (`ActiveAgentService.attachStatus`). Both sources are
/// built as values; nothing here reads or writes the real stores.
final class ActiveAgentStatusMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let processAge: TimeInterval = 600

    private func agent(
        pid: Int = 100, session: Bool = true, transcriptAge: TimeInterval = 30, elapsed: TimeInterval? = nil
    ) -> ActiveAgent {
        ActiveAgent(
            provider: .claude, pid: pid, parentPID: 1, command: "claude",
            elapsedSeconds: elapsed ?? processAge, observedAt: now, cwd: "/tmp/project",
            session: session ? ActiveAgentSession(
                id: "session-\(pid)", projectPath: "/tmp/project", projectName: "project",
                branch: nil, lastUpdatedAt: now.addingTimeInterval(-transcriptAge), source: "test") : nil
        )
    }

    private func payload(
        _ state: AgentStatusState, pid: Int = 100, at updatedAt: Date,
        pending: Int? = nil, subagents: Int? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            state: state, sessionID: "session-\(pid)", cwd: "/tmp/project",
            processAncestry: [pid + 10_000, pid, 1],
            pendingBackgroundTasks: pending, pendingSubagents: subagents, updatedAt: updatedAt)
    }

    private func entry(
        _ status: ClaudeSessionRegistryEntry.Status?, pid: Int = 100, at statusUpdatedAt: Date?,
        waitingFor: String? = nil, startedAt: Date?? = nil
    ) -> ClaudeSessionRegistryEntry {
        ClaudeSessionRegistryEntry(
            pid: pid, sessionID: "session-\(pid)", cwd: "/tmp/project",
            // Registered four seconds after the process started, as observed.
            startedAt: startedAt ?? now.addingTimeInterval(-processAge + 4),
            status: status, waitingFor: waitingFor, statusUpdatedAt: statusUpdatedAt)
    }

    private func attach(
        _ agent: ActiveAgent, payloads: [AgentStatusPayload] = [], registry: [ClaudeSessionRegistryEntry] = []
    ) -> ActiveAgent {
        ActiveAgentService.attachStatus(
            [agent], payloads: payloads,
            registry: Dictionary(registry.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        )[0]
    }

    // MARK: Registry states

    func testRegistryStatusDecidesTheRowState() {
        XCTAssertEqual(attach(agent(), registry: [entry(.busy, at: now)]).status, .working)
        XCTAssertEqual(attach(agent(), registry: [entry(.waiting, at: now)]).status, .waiting)
        XCTAssertEqual(attach(agent(), registry: [entry(.idle, at: now)]).status, .idle)
        // The user's own `!` command runs in an idle session.
        XCTAssertEqual(attach(agent(), registry: [entry(.shell, at: now)]).status, .idle)

        let row = attach(agent(), registry: [entry(.busy, at: now)])
        XCTAssertEqual(row.statusSource, .registry)
        XCTAssertEqual(row.statusUpdatedAt, now)
        XCTAssertEqual(row.activityText, "working now")
    }

    func testARegistryStateWithoutAStampInventsNoTime() {
        // The reader treats the stamp as optional. Without it the row's age is
        // the transcript's, not a fresh "now" that would also list the row and
        // sort it first.
        let row = attach(agent(transcriptAge: 300), registry: [entry(.idle, at: nil)])

        XCTAssertEqual(row.status, .idle)
        XCTAssertEqual(row.statusSource, .registry)
        XCTAssertNil(row.statusUpdatedAt)
        XCTAssertEqual(row.lastActivityAt, now.addingTimeInterval(-300))
        XCTAssertEqual(row.activityText, "idle · 5m ago")
    }

    func testWaitingWordingComesFromKnownRegistryValuesOnly() {
        func row(_ waitingFor: String?) -> ActiveAgent {
            attach(agent(), registry: [entry(.waiting, at: now, waitingFor: waitingFor)])
        }
        XCTAssertEqual(row("permission prompt").waitingReason, .permission)
        XCTAssertEqual(row("permission prompt").activityText, "waiting for permission")
        XCTAssertEqual(row("sandbox request").waitingReason, .permission)
        XCTAssertEqual(row("worker request").waitingReason, .permission)
        XCTAssertEqual(row("input needed").activityText, "waiting for your input")
        XCTAssertEqual(row("dialog open").activityText, "waiting · dialog open")
        // Claude Code's text never reaches the row as is.
        let unknown = row("<b>pay now</b> at http://example.invalid")
        XCTAssertNil(unknown.waitingReason)
        XCTAssertEqual(unknown.status, .waiting)
        XCTAssertEqual(unknown.activityText, "waiting")
        XCTAssertEqual(row(nil).activityText, "waiting")
        XCTAssertEqual(row("").activityText, "waiting")
        XCTAssertTrue(ActiveAgentTooltip.text(for: row("permission prompt"))
            .contains("\nWaiting for permission · Last activity"))
        XCTAssertTrue(ActiveAgentTooltip.text(for: unknown)
            .contains("\nWaiting · Last activity"))
        // The reason belongs to the waiting state alone.
        XCTAssertNil(attach(agent(), registry: [entry(.busy, at: now, waitingFor: "permission prompt")]).waitingReason)
    }

    // MARK: The three investigated gaps

    func testAnInterruptedTurnReadsIdleOnceTheRegistrySaysSo() {
        // Esc fires no hook: the last payload is the `PreToolUse` from three
        // seconds before, and would have kept the row green until the next
        // prompt. The registry flipped to idle on the abort.
        let row = attach(
            agent(),
            payloads: [payload(.working, at: now.addingTimeInterval(-3))],
            registry: [entry(.idle, at: now)])

        XCTAssertEqual(row.status, .idle)
        XCTAssertEqual(row.statusSource, .registry)
        // The interrupt is the last sign of life, newer than the transcript's
        // 30 s: the age the row shows is the one the listing and the order use.
        XCTAssertEqual(row.activityText, "idle · 0s ago")
    }

    func testAnApprovedPromptReadsWorkingWhileTheToolRuns() {
        // Approval fires no hook either; `waiting` stayed until the tool's
        // own `PostToolUse`, however long the tool ran.
        let row = attach(
            agent(),
            payloads: [payload(.waiting, at: now.addingTimeInterval(-10))],
            registry: [entry(.busy, at: now)])

        XCTAssertEqual(row.status, .working)
        XCTAssertNil(row.waitingReason)
    }

    func testASubagentsToolCallsDoNotOverwriteTheParentsWaiting() {
        // The background subagent's `PostToolUse` wrote `working` under the
        // parent's session id after the parent's prompt opened. The registry
        // tracks the dialog, which is still open.
        let row = attach(
            agent(),
            payloads: [payload(.working, at: now)],
            registry: [entry(.waiting, at: now.addingTimeInterval(-5), waitingFor: "permission prompt")])

        XCTAssertEqual(row.status, .waiting)
        XCTAssertEqual(row.activityText, "waiting for permission")
    }

    func testATurnThatEndedWithBackgroundTasksReadsIdleWithTheCount() {
        // The helper's `idle` command recorded `working · 2` for the `Stop`
        // that found tasks in flight; the registry wrote idle 13 ms later.
        let stop = payload(.working, at: now.addingTimeInterval(-1), pending: 2, subagents: 0)
        let row = attach(agent(), payloads: [stop], registry: [entry(.idle, at: now.addingTimeInterval(-0.987))])

        XCTAssertEqual(row.status, .idle)
        XCTAssertEqual(row.pendingBackgroundTasks, 2)
        XCTAssertEqual(row.activityText, "idle · 2 background tasks")
        XCTAssertTrue(ActiveAgentTooltip.text(for: row).contains("The last turn ended with 2 background tasks still in flight"))

        let subagents = attach(
            agent(),
            payloads: [payload(.working, at: now.addingTimeInterval(-1), pending: 1, subagents: 1)],
            registry: [entry(.idle, at: now)])
        XCTAssertEqual(subagents.activityText, "idle · 1 subagent")

        // Without a registry the helper's reading stands, as it did before.
        let fallback = attach(agent(), payloads: [stop])
        XCTAssertEqual(fallback.status, .working)
        XCTAssertEqual(fallback.activityText, "working · 2 background tasks")
    }

    // MARK: Errors

    func testAFailedTurnStaysRedUntilTheNextTurnStarts() {
        let failedAt = now.addingTimeInterval(-300)
        let error = payload(.error, at: failedAt)

        // `StopFailure` ran 13 ms before Claude Code wrote idle for the same
        // turn end: the registry's idle is the error's own.
        let red = attach(agent(), payloads: [error], registry: [entry(.idle, at: failedAt.addingTimeInterval(0.013))])
        XCTAssertEqual(red.status, .error)
        XCTAssertEqual(red.statusSource, .hook)
        XCTAssertEqual(red.statusUpdatedAt, failedAt)
        XCTAssertEqual(red.displayStatus, .error)

        // The payload's time is whole seconds; it may read a second early.
        XCTAssertEqual(attach(agent(), payloads: [error],
                              registry: [entry(.idle, at: failedAt.addingTimeInterval(1.4))]).status, .error)

        // A new prompt: the registry is busy again, the error is over.
        XCTAssertEqual(attach(agent(), payloads: [error],
                              registry: [entry(.busy, at: failedAt.addingTimeInterval(60))]).status, .working)
        XCTAssertEqual(attach(agent(), payloads: [error],
                              registry: [entry(.waiting, at: failedAt.addingTimeInterval(60))]).status, .waiting)
        // That turn ended too; the idle is a later turn's, not the error's.
        XCTAssertEqual(attach(agent(), payloads: [error],
                              registry: [entry(.idle, at: failedAt.addingTimeInterval(120))]).status, .idle)
    }

    func testAnErrorNewerThanTheRegistrysIdleStands() {
        // The registry stopped moving (or was read a beat early); the hook
        // is the only source that knows the turn failed.
        let row = attach(
            agent(),
            payloads: [payload(.error, at: now)],
            registry: [entry(.idle, at: now.addingTimeInterval(-30))])
        XCTAssertEqual(row.status, .error)
    }

    func testAStaleErrorIsPlainIdleBesideTheRegistryToo() {
        // A tab open for two days whose turn failed over an hour ago and that
        // nobody went back to: the registry has said idle since that moment.
        let processAge: TimeInterval = 2 * 86_400
        let failedAt = now.addingTimeInterval(-ActiveAgent.errorAttentionWindow - 60)
        let row = attach(
            agent(elapsed: processAge),
            payloads: [payload(.error, at: failedAt)],
            registry: [entry(.idle, at: failedAt.addingTimeInterval(0.02),
                             startedAt: .some(now.addingTimeInterval(-processAge + 4)))])

        XCTAssertEqual(row.status, .error)
        XCTAssertEqual(row.displayStatus, .idle)
        XCTAssertEqual(row.activityText, "idle · 30s ago", "its transcript's age, as any idle row")
    }

    // MARK: Fallback

    func testTheHookStandsInWhenTheRegistryHasNothingUsable() {
        let hook = payload(.waiting, at: now.addingTimeInterval(-2))

        // No entry for the process.
        let missing = attach(agent(), payloads: [hook])
        XCTAssertEqual(missing.status, .waiting)
        XCTAssertEqual(missing.statusSource, .hook)
        XCTAssertEqual(missing.statusUpdatedAt, hook.updatedAt)

        // An entry whose status is a word AgentMeter does not know.
        XCTAssertEqual(attach(agent(), payloads: [hook], registry: [entry(nil, at: now)]).statusSource, .hook)

        // An entry from the PID's previous holder.
        let stale = entry(.busy, at: now, startedAt: .some(now.addingTimeInterval(-processAge - 3_600)))
        XCTAssertEqual(attach(agent(), payloads: [hook], registry: [stale]).status, .waiting)
        XCTAssertEqual(attach(agent(), payloads: [hook], registry: [stale]).statusSource, .hook)

        // An entry that cannot be placed in time.
        let undated = entry(.busy, at: now, startedAt: .some(nil))
        XCTAssertEqual(attach(agent(), payloads: [hook], registry: [undated]).statusSource, .hook)
    }

    func testARegistryStateAloneDoesNotMakeARow() {
        // Claude Code registers the short-lived helpers it spawns beside a
        // session as well. With neither a transcript nor a hook payload the
        // process stays blank and `presentable` drops it, as before.
        let ghost = agent(pid: 300, session: false)
        let rows = ActiveAgentService.presentable(
            [ghost], payloads: [], registry: [300: entry(.busy, pid: 300, at: now)])

        XCTAssertTrue(rows.isEmpty)
        XCTAssertNil(attach(ghost, registry: [entry(.busy, pid: 300, at: now)]).status)
    }

    func testASessionThatExitedCleanlyLeavesTheTranscriptOnlyReading() {
        // `SessionEnd` removed the hook file and Claude Code its registry
        // entry; until `ps` drops the process the row reads from its
        // transcript, as it always has.
        XCTAssertNil(attach(agent(transcriptAge: 30)).status)
        XCTAssertEqual(attach(agent(transcriptAge: 30)).displayStatus, .working)
        XCTAssertEqual(attach(agent(transcriptAge: 600)).displayStatus, .idle)
    }

    func testTheRegistryDecidesWhicheverSourceWasWrittenLast() {
        // The hook is newer, the registry still wins: it describes the
        // process now, the payload the last event.
        XCTAssertEqual(attach(agent(), payloads: [payload(.waiting, at: now.addingTimeInterval(30))],
                              registry: [entry(.busy, at: now)]).status, .working)
        XCTAssertEqual(attach(agent(), payloads: [payload(.working, at: now.addingTimeInterval(30))],
                              registry: [entry(.idle, at: now)]).status, .idle)
        // The registry is newer: same answer.
        XCTAssertEqual(attach(agent(), payloads: [payload(.working, at: now.addingTimeInterval(-30))],
                              registry: [entry(.waiting, at: now)]).status, .waiting)
    }

    func testTheSameFilesReadTheSameAfterARestart() {
        // Nothing is kept across launches: the state is a function of the two
        // stores, so a relaunch reading the same files shows the same rows.
        let payloads = [payload(.error, at: now.addingTimeInterval(-100)),
                        payload(.working, pid: 200, at: now.addingTimeInterval(-1), pending: 1, subagents: 1)]
        let registry = [entry(.idle, at: now.addingTimeInterval(-99.98)), entry(.busy, pid: 200, at: now)]
        let first = ActiveAgentService.attachStatus(
            [agent(), agent(pid: 200)], payloads: payloads,
            registry: Dictionary(uniqueKeysWithValues: registry.map { ($0.pid, $0) }))
        let second = ActiveAgentService.attachStatus(
            [agent(), agent(pid: 200)], payloads: payloads,
            registry: Dictionary(uniqueKeysWithValues: registry.map { ($0.pid, $0) }))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.status), [.error, .working])
    }

    func testEachSessionReadsItsOwnEntry() {
        let rows = ActiveAgentService.attachStatus(
            [agent(pid: 100), agent(pid: 200), agent(pid: 300)],
            payloads: [payload(.working, pid: 100, at: now), payload(.working, pid: 200, at: now)],
            registry: [
                100: entry(.waiting, pid: 100, at: now, waitingFor: "input needed"),
                200: entry(.idle, pid: 200, at: now),
            ])

        XCTAssertEqual(rows.map(\.status), [.waiting, .idle, nil])
        XCTAssertEqual(rows.map(\.statusSource), [.registry, .registry, nil])
        XCTAssertEqual(rows[0].activityText, "waiting for your input")
    }

    func testCodexRowsAreLeftAlone() {
        let codex = ActiveAgent(provider: .codex, pid: 100, parentPID: 1, command: "codex",
                                elapsedSeconds: processAge, observedAt: now, cwd: "/tmp/project")
        XCTAssertNil(attach(codex, payloads: [payload(.working, at: now)], registry: [entry(.busy, at: now)]).status)
    }

    // MARK: The popover's local tick

    func testTheLocalTickReattachesStateWithoutRebuildingTheRows() {
        let before = ActiveAgentService.attachStatus(
            [agent(pid: 100), agent(pid: 200), agent(pid: 300, session: false)],
            payloads: [payload(.working, pid: 100, at: now.addingTimeInterval(-5)),
                       payload(.waiting, pid: 300, at: now.addingTimeInterval(-5))],
            registry: [100: entry(.busy, pid: 100, at: now.addingTimeInterval(-5))])
        XCTAssertEqual(before.map(\.status), [.working, nil, .waiting])

        // Two seconds later: 100 was interrupted, 200 started a turn, 300's
        // process exited and its hook file went with it.
        let after = ActiveAgentService.refreshStatuses(
            before,
            payloads: [payload(.working, pid: 100, at: now.addingTimeInterval(-5))],
            registry: [100: entry(.idle, pid: 100, at: now.addingTimeInterval(-1)),
                       200: entry(.busy, pid: 200, at: now.addingTimeInterval(-1))],
            isAlive: { $0 != 300 })

        XCTAssertEqual(after.map(\.pid), [100, 200])
        XCTAssertEqual(after.map(\.status), [.idle, .working])
        XCTAssertEqual(after[0].statusUpdatedAt, now.addingTimeInterval(-1))
        // Session, usage and the observation time are the full refresh's.
        XCTAssertEqual(after[0].session, before[0].session)
        XCTAssertEqual(after[0].observedAt, before[0].observedAt)
        XCTAssertEqual(after[1].session, before[1].session)
    }

    func testTheLocalTickDropsARowWhoseOnlyStateWentAway() {
        // A process known only through its hook file, now removed by
        // `SessionEnd`: without the file it is a bare PID again.
        let before = ActiveAgentService.attachStatus(
            [agent(pid: 300, session: false)],
            payloads: [payload(.working, pid: 300, at: now)])
        XCTAssertEqual(before[0].status, .working)

        let after = ActiveAgentService.refreshStatuses(before, payloads: [], registry: [:], isAlive: { _ in true })

        XCTAssertTrue(after.isEmpty)
    }

    // MARK: Transcript pins

    func testTheRegistryPinsTheTranscriptBeforeTheHookDoes() {
        let resolve = ActiveAgentService.sessionResolver(
            payloadsByPID: [100: payload(.working, at: now)],
            registryPins: [100: ActiveAgentService.RegistrySessionPin(sessionID: "registry-session", cwd: "/tmp/project")],
            identified: { sessionID, cwd, _ in
                ActiveAgentSession(id: sessionID, projectPath: cwd, projectName: "project",
                                   branch: nil, lastUpdatedAt: self.now, source: "test")
            },
            heuristic: { _, _ in XCTFail("pinned processes never reach the heuristic"); return nil })

        let session = resolve(ActiveAgentService.SessionQuery(
            provider: .claude, pid: 100, cwd: "/tmp/project", startedAt: now.addingTimeInterval(-processAge),
            observedAt: now, codexRolloutIdentifier: nil, isSoleAgentForCWD: true))

        XCTAssertEqual(session?.id, "registry-session")
    }

    func testTheHookPinIsTriedWhenTheRegistrysTranscriptIsNotOnDisk() {
        var tried: [String] = []
        let resolve = ActiveAgentService.sessionResolver(
            payloadsByPID: [100: payload(.working, at: now)],
            registryPins: [100: ActiveAgentService.RegistrySessionPin(sessionID: "registry-session", cwd: "/tmp/project")],
            identified: { sessionID, cwd, _ in
                tried.append(sessionID + " " + cwd)
                return sessionID == "session-100"
                    ? ActiveAgentSession(id: sessionID, projectPath: cwd, projectName: "project",
                                         branch: nil, lastUpdatedAt: self.now, source: "test")
                    : nil
            },
            heuristic: { _, _ in nil })

        let session = resolve(ActiveAgentService.SessionQuery(
            provider: .claude, pid: 100, cwd: "/tmp/elsewhere", startedAt: now.addingTimeInterval(-processAge),
            observedAt: now, codexRolloutIdentifier: nil, isSoleAgentForCWD: true))

        XCTAssertEqual(session?.id, "session-100")
        XCTAssertEqual(tried, ["registry-session /tmp/project", "registry-session /tmp/elsewhere",
                               "session-100 /tmp/project"],
                       "each pin's own cwd first, then the process cwd, no pair twice")
    }

    func testARegistryPinWithoutATranscriptNeverFallsToTheHeuristic() {
        let resolve = ActiveAgentService.sessionResolver(
            payloadsByPID: [:],
            registryPins: [100: ActiveAgentService.RegistrySessionPin(sessionID: "fresh-session", cwd: "/tmp/project")],
            identified: { _, _, _ in nil },
            heuristic: { _, _ in XCTFail("the newest file in the directory is another session's"); return nil })

        XCTAssertNil(resolve(ActiveAgentService.SessionQuery(
            provider: .claude, pid: 100, cwd: "/tmp/project", startedAt: now.addingTimeInterval(-processAge),
            observedAt: now, codexRolloutIdentifier: nil, isSoleAgentForCWD: true)))
    }

    func testRegistryPinsRequireALivePIDLifetimeAndAUniqueSession() {
        let processStart = now.addingTimeInterval(-processAge)
        let registry: [Int: ClaudeSessionRegistryEntry] = [
            // Two live processes naming one session: a helper spawned with
            // the session's environment. Neither gets the pin.
            100: ClaudeSessionRegistryEntry(pid: 100, sessionID: "shared", cwd: "/tmp/p",
                                            startedAt: processStart.addingTimeInterval(4), status: .busy,
                                            waitingFor: nil, statusUpdatedAt: now),
            200: ClaudeSessionRegistryEntry(pid: 200, sessionID: "shared", cwd: "/tmp/p",
                                            startedAt: processStart.addingTimeInterval(4), status: .idle,
                                            waitingFor: nil, statusUpdatedAt: now),
            // A previous holder's file.
            300: ClaudeSessionRegistryEntry(pid: 300, sessionID: "old", cwd: "/tmp/p",
                                            startedAt: processStart.addingTimeInterval(-3_600), status: .idle,
                                            waitingFor: nil, statusUpdatedAt: now),
            // A session id that is not a filename.
            400: ClaudeSessionRegistryEntry(pid: 400, sessionID: "../escape", cwd: "/tmp/p",
                                            startedAt: processStart.addingTimeInterval(4), status: .idle,
                                            waitingFor: nil, statusUpdatedAt: now),
            500: ClaudeSessionRegistryEntry(pid: 500, sessionID: "unique", cwd: "/tmp/p",
                                            startedAt: processStart.addingTimeInterval(4), status: .idle,
                                            waitingFor: nil, statusUpdatedAt: now),
        ]

        let pins = ActiveAgentService.registrySessionPins(
            registry,
            processes: [100: processStart, 200: processStart, 300: processStart, 400: processStart, 500: processStart],
            observedAt: now)

        XCTAssertEqual(pins, [500: ActiveAgentService.RegistrySessionPin(sessionID: "unique", cwd: "/tmp/p")])
    }

    func testParsePSOutputPinsThroughTheRegistryWithoutAHookPayload() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10004 99999       00:10 claude
        10005 99999       00:10 claude
        """
        let registry: [Int: ClaudeSessionRegistryEntry] = [
            10004: ClaudeSessionRegistryEntry(pid: 10004, sessionID: "registry-session", cwd: "/Users/me/project",
                                              startedAt: now.addingTimeInterval(-8), status: .busy,
                                              waitingFor: nil, statusUpdatedAt: now),
        ]
        let pinned = ActiveAgentSession(
            id: "registry-session", projectPath: "/Users/me/project", projectName: "project",
            branch: nil, lastUpdatedAt: now, source: "test")

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: now,
            cwdLookup: { _ in "/Users/me/project" },
            resolveSession: ActiveAgentService.sessionResolver(
                payloadsByPID: [:],
                registryPins: ActiveAgentService.registrySessionPins(
                    registry, processes: [10004: now.addingTimeInterval(-10), 10005: now.addingTimeInterval(-10)],
                    observedAt: now),
                identified: { sessionID, _, _ in sessionID == "registry-session" ? pinned : nil },
                heuristic: { _, _ in XCTFail("two agents share the directory"); return nil }))

        XCTAssertEqual(agents.first { $0.pid == 10004 }?.session?.id, "registry-session")
        XCTAssertNil(agents.first { $0.pid == 10005 }?.session)
    }
}
