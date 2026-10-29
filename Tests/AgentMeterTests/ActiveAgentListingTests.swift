import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

/// Which live sessions the popover lists (`ActiveAgent.isListed`,
/// `ActiveAgentListing`). Every time is relative to one fixed `observedAt`.
final class ActiveAgentListingTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    private let hour: TimeInterval = 3_600
    private var window: TimeInterval { ActiveAgent.idleListingWindow }

    /// `stateAge` / `transcriptAge`: how long before `observedAt` the state
    /// last changed and the transcript last grew; nil leaves that evidence out.
    private func agent(
        _ pid: Int,
        provider: Provider = .claude,
        status: AgentStatusState? = nil,
        source: ActiveAgentStatusSource? = .registry,
        stateAge: TimeInterval? = nil,
        transcriptAge: TimeInterval? = nil,
        parent: Int? = nil,
        sessionID: String? = nil,
        pending: Int? = nil,
        subagentAge: TimeInterval? = nil
    ) -> ActiveAgent {
        let session = transcriptAge.map {
            ActiveAgentSession(
                id: sessionID ?? "session-\(pid)",
                projectPath: "/work/\(pid)",
                projectName: nil,
                branch: nil,
                lastUpdatedAt: observedAt.addingTimeInterval(-$0),
                source: "test",
                subagents: subagentAge.map { age in
                    [ActiveSubagent(id: "sub", logPath: "/t/agent-sub.jsonl",
                                    lastUpdatedAt: observedAt.addingTimeInterval(-age), observedAt: observedAt)]
                } ?? []
            )
        }
        return ActiveAgent(
            provider: provider,
            pid: pid,
            parentPID: 1,
            command: provider.rawValue,
            elapsedSeconds: 30 * 86_400,
            observedAt: observedAt,
            session: session,
            parentAgentPID: parent,
            status: status,
            pendingBackgroundTasks: pending,
            statusUpdatedAt: stateAge.map { observedAt.addingTimeInterval(-$0) },
            statusSource: status == nil ? nil : source
        )
    }

    private func listed(_ agents: [ActiveAgent]) -> [Int] {
        ActiveAgentListing(agents).agents.map(\.pid)
    }

    // MARK: Idle sessions

    func testAnIdleSessionStaysListedForTheWindowAndThenIsHidden() {
        XCTAssertTrue(agent(1, status: .idle, stateAge: 5 * 60, transcriptAge: 5 * 60).isListed)
        XCTAssertTrue(agent(1, status: .idle, stateAge: 23 * hour, transcriptAge: 23 * hour).isListed)
        XCTAssertFalse(agent(1, status: .idle, stateAge: 25 * hour, transcriptAge: 25 * hour).isListed)
        XCTAssertFalse(agent(1, status: .idle, stateAge: 9 * 86_400, transcriptAge: 9 * 86_400).isListed)
    }

    func testTheWindowEdgeIsInclusive() {
        XCTAssertTrue(agent(1, status: .idle, stateAge: window, transcriptAge: window).isListed)
        XCTAssertFalse(agent(1, status: .idle, stateAge: window + 1, transcriptAge: window + 1).isListed)
    }

    func testTheNewestSignOfLifeDecides() {
        // State untouched for days, but the transcript grew a minute ago: the
        // session did something (a resumed turn, background work writing to it).
        XCTAssertTrue(agent(1, status: .idle, stateAge: 4 * 86_400, transcriptAge: 60).isListed)
        // And the other way round.
        XCTAssertTrue(agent(1, status: .idle, stateAge: 60, transcriptAge: 4 * 86_400).isListed)
        XCTAssertEqual(agent(1, status: .idle, stateAge: 60, transcriptAge: 4 * 86_400).lastActivityAt,
                       observedAt.addingTimeInterval(-60))
    }

    func testTheProcessAgeIsNotWhatDecides() {
        // Every fixture process is 30 days old; only activity counts.
        XCTAssertTrue(agent(1, status: .idle, stateAge: 60, transcriptAge: 60).isListed)
    }

    func testARegistryStateWithoutAStampLeavesTheTranscriptToDecide() {
        XCTAssertTrue(agent(1, status: .idle, stateAge: nil, transcriptAge: hour).isListed)
        XCTAssertFalse(agent(1, status: .idle, stateAge: nil, transcriptAge: 3 * 86_400).isListed)
    }

    func testASubagentStillWritingKeepsTheSession() {
        // The main transcript and the state are days old; a subagent wrote a
        // minute ago, which is the session doing something.
        let row = agent(1, status: .idle, stateAge: 5 * 86_400, transcriptAge: 5 * 86_400, subagentAge: 60)

        XCTAssertEqual(row.lastActivityAt, observedAt.addingTimeInterval(-60))
        XCTAssertTrue(row.isListed)
        XCTAssertFalse(agent(1, status: .idle, stateAge: 5 * 86_400, transcriptAge: 5 * 86_400,
                             subagentAge: 4 * 86_400).isListed)
    }

    func testAnOldCountOfBackgroundTasksDoesNotKeepASession() {
        // "idle · 2 subagents" is the count the last `Stop` reported, not a
        // reading of what runs now; a day later it says nothing.
        XCTAssertFalse(agent(1, status: .idle, stateAge: 5 * 86_400, transcriptAge: 5 * 86_400, pending: 2).isListed)
        XCTAssertTrue(agent(1, status: .idle, stateAge: 600, transcriptAge: 600, pending: 2).isListed)
    }

    func testWithoutADateTheRowStays() {
        XCTAssertNil(agent(1, status: .idle).lastActivityAt)
        XCTAssertTrue(agent(1, status: .idle).isListed)
    }

    func testAClockAheadOfTheObservationDoesNotHideAnything() {
        XCTAssertTrue(agent(1, status: .idle, stateAge: -30, transcriptAge: -30).isListed)
    }

    // MARK: Running sessions

    func testTheRegistryVouchesForABusyOrWaitingProcessWhateverTheDate() {
        // A long run with background agents keeps `busy` and its old stamp
        // while the main transcript stays quiet.
        XCTAssertTrue(agent(1, status: .working, stateAge: 10 * 86_400, transcriptAge: 10 * 86_400).isListed)
        XCTAssertTrue(agent(1, status: .waiting, stateAge: 10 * 86_400, transcriptAge: 10 * 86_400).isListed)
    }

    func testAHookStateVouchesForNothingOnceItIsOld() {
        // An interrupt fires no `Stop`, so a hook-written `working` can be left
        // behind for good in a session that is long idle.
        XCTAssertFalse(agent(1, status: .working, source: .hook, stateAge: 3 * 86_400, transcriptAge: 3 * 86_400).isListed)
        XCTAssertFalse(agent(1, status: .waiting, source: .hook, stateAge: 3 * 86_400).isListed)
    }

    func testAFreshHookStateIsListed() {
        XCTAssertTrue(agent(1, status: .working, source: .hook, stateAge: 30, transcriptAge: 30).isListed)
        XCTAssertTrue(agent(1, status: .waiting, source: .hook, stateAge: 2 * hour).isListed)
    }

    func testAnOldHookStateWithAFreshTranscriptIsListed() {
        XCTAssertTrue(agent(1, status: .working, source: .hook, stateAge: 3 * 86_400, transcriptAge: 20).isListed)
    }

    func testAFailedTurnIsListedWhileItNeedsAttention() {
        XCTAssertTrue(agent(1, status: .error, source: .hook, stateAge: hour, transcriptAge: hour).isListed)
    }

    func testAnOldFailureIsJustAnIdleSession() {
        // Past `errorAttentionWindow` the row reads idle, so the idle rule
        // applies: still listed at 13 h, hidden at 30 h.
        let thirteen = agent(1, status: .error, source: .hook, stateAge: 13 * hour, transcriptAge: 13 * hour)
        XCTAssertEqual(thirteen.displayStatus, .idle)
        XCTAssertTrue(thirteen.isListed)
        XCTAssertFalse(agent(1, status: .error, source: .hook, stateAge: 30 * hour, transcriptAge: 30 * hour).isListed)
    }

    // MARK: Without hooks or a registry (Codex)

    func testACodexRowFollowsTheSameRuleFromItsTranscript() {
        XCTAssertTrue(agent(1, provider: .codex, transcriptAge: 30).isListed)
        XCTAssertTrue(agent(1, provider: .codex, transcriptAge: 2 * hour).isListed)
        XCTAssertFalse(agent(1, provider: .codex, transcriptAge: 3 * 86_400).isListed)
    }

    // MARK: Process trees

    func testAParentStaysWhileAChildProcessIsRunning() {
        let parent = agent(1, status: .idle, stateAge: 5 * 86_400, transcriptAge: 5 * 86_400)
        let child = agent(2, status: .working, stateAge: 30, transcriptAge: 30, parent: 1)

        XCTAssertEqual(listed([parent, child]), [1, 2])
    }

    func testTheWholeChainStaysUnderARunningDescendant() {
        let old = 5 * 86_400.0
        let rows = [
            agent(1, status: .idle, stateAge: old, transcriptAge: old),
            agent(2, status: .idle, stateAge: old, transcriptAge: old, parent: 1),
            agent(3, status: .working, stateAge: 30, transcriptAge: 30, parent: 2),
        ]

        XCTAssertEqual(listed(rows), [1, 2, 3])
    }

    func testAnIdleChildOfAListedParentIsHidden() {
        let old = 5 * 86_400.0
        let rows = [
            agent(1, status: .working, stateAge: 30, transcriptAge: 30),
            agent(2, status: .idle, stateAge: old, transcriptAge: old, parent: 1),
        ]

        XCTAssertEqual(listed(rows), [1])
    }

    func testAnIdleTreeIsHiddenWhole() {
        let old = 5 * 86_400.0
        let rows = [
            agent(1, status: .idle, stateAge: old, transcriptAge: old),
            agent(2, status: .idle, stateAge: old, transcriptAge: old, parent: 1),
        ]

        XCTAssertEqual(listed(rows), [])
        XCTAssertEqual(ActiveAgentListing(rows).hiddenCount, 2)
    }

    func testAParentOfAnotherProviderIsNotPulledIn() {
        let old = 5 * 86_400.0
        let rows = [
            agent(1, provider: .codex, status: nil, transcriptAge: old),
            agent(2, provider: .claude, status: .working, stateAge: 30, transcriptAge: 30, parent: 1),
        ]

        XCTAssertEqual(listed(rows), [2])
    }

    func testAParentCycleEndsAndKeepsBoth() {
        let old = 5 * 86_400.0
        let rows = [
            agent(1, status: .working, stateAge: 30, transcriptAge: 30, parent: 2),
            agent(2, status: .idle, stateAge: old, transcriptAge: old, parent: 1),
        ]

        XCTAssertEqual(listed(rows), [1, 2])
    }

    // MARK: The listing

    func testTheListingKeepsTheOrderAndCountsWhatItLeavesOut() {
        let old = 5 * 86_400.0
        let rows = [
            agent(3, status: .idle, stateAge: 60, transcriptAge: 60),
            agent(1, status: .idle, stateAge: old, transcriptAge: old),
            agent(2, status: .working, stateAge: 30, transcriptAge: 30),
            agent(4, status: .idle, stateAge: old, transcriptAge: old),
        ]

        let listing = ActiveAgentListing(rows)

        XCTAssertEqual(listing.agents.map(\.pid), [3, 2])
        XCTAssertEqual(listing.hiddenCount, 2)
    }

    func testNothingHiddenSaysNothing() {
        let listing = ActiveAgentListing([agent(1, status: .idle, stateAge: 60, transcriptAge: 60)])

        XCTAssertEqual(listing.hiddenCount, 0)
        XCTAssertNil(listing.hiddenNote)
    }

    func testTheNoteCountsAndSingularises() {
        let old = 5 * 86_400.0
        let one = ActiveAgentListing([agent(1, status: .idle, stateAge: old, transcriptAge: old)])
        let many = ActiveAgentListing((1...3).map { agent($0, status: .idle, stateAge: old, transcriptAge: old) })

        XCTAssertEqual(one.hiddenNote, "1 idle session hidden")
        XCTAssertEqual(many.hiddenNote, "3 idle sessions hidden")
    }

    func testAnEmptyListIsAnEmptyListing() {
        XCTAssertEqual(ActiveAgentListing([]), ActiveAgentListing([]))
        XCTAssertEqual(ActiveAgentListing([]).hiddenCount, 0)
    }

    // MARK: Hiding is only about the list

    func testHiddenRowsStayInTheModelForRoutingAndTitles() {
        // The list is filtered where it is drawn, not in `presentable`: a task
        // notification's click and the titles of live sessions read the rows
        // `fetch()` hands the model, hidden ones included.
        let old = 5 * 86_400.0
        let rows = [agent(1, status: .idle, stateAge: old, transcriptAge: old)]

        let model = ActiveAgentService.presentable(rows, payloads: [], registry: [:])

        XCTAssertEqual(model.map(\.pid), [1])
        XCTAssertEqual(ActiveAgentListing(model).agents, [])
    }

    func testAHiddenSessionComesBackThroughTheStatusTick() {
        // The popover's 2 s tick re-reads the registry and re-attaches it to the
        // rows already built (`refreshStatuses`), hidden ones included.
        let old = 5 * 86_400.0
        let row = agent(1, status: .idle, stateAge: old, transcriptAge: old)
        XCTAssertFalse(row.isListed)

        func registry(_ status: ClaudeSessionRegistryEntry.Status) -> [Int: ClaudeSessionRegistryEntry] {
            [1: ClaudeSessionRegistryEntry(
                pid: 1, sessionID: "session-1", cwd: "/work/1",
                startedAt: observedAt.addingTimeInterval(-row.elapsedSeconds + 4),
                status: status, waitingFor: nil, statusUpdatedAt: observedAt)]
        }

        // It starts a turn: busy, vouched for by the registry.
        let busy = ActiveAgentService.refreshStatuses([row], payloads: [], registry: registry(.busy), isAlive: { _ in true })
        XCTAssertEqual(busy.first?.status, .working)
        XCTAssertEqual(busy.first?.isListed, true)

        // The turn ends: idle again, but stamped just now.
        let idle = ActiveAgentService.refreshStatuses([row], payloads: [], registry: registry(.idle), isAlive: { _ in true })
        XCTAssertEqual(idle.first?.status, .idle)
        XCTAssertEqual(idle.first?.isListed, true)

        // The process is gone: the row goes with it.
        XCTAssertEqual(ActiveAgentService.refreshStatuses([row], payloads: [], registry: registry(.busy),
                                                          isAlive: { _ in false }).count, 0)
    }

    func testTheHiddenNoteStatesTheWindowItUses() {
        XCTAssertTrue(ActiveAgentListing.hiddenHelp.contains("\(Int(ActiveAgent.idleListingWindow / 3_600)) hours"))
    }

    func testAResumedSessionIsANewProcessAndIsListedWhileTheOldOneIsNot() {
        let old = 5 * 86_400.0
        let rows = [
            agent(10, status: .idle, stateAge: old, transcriptAge: old, sessionID: "same-session"),
            agent(20, status: .idle, stateAge: 5, transcriptAge: 5, sessionID: "same-session"),
        ]

        XCTAssertEqual(listed(rows), [20])
    }
}
