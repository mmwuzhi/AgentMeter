import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

final class ActiveAgentTooltipTests: XCTestCase {
    /// 2026-10-29 12:00 UTC: every session fixture is observed then.
    private let observedAt = Date(timeIntervalSince1970: 1_793_275_200)
    private let utc = TimeZone(identifier: "UTC")!
    private let american = Locale(identifier: "en_US")

    private func agent(
        pid: Int = 501,
        status: AgentStatusState? = .idle,
        source: ActiveAgentStatusSource? = .registry,
        stateAge: TimeInterval? = nil,
        waitingReason: ActiveAgentWaitingReason? = nil,
        pending: Int? = nil,
        session: ActiveAgentSession? = nil
    ) -> ActiveAgent {
        ActiveAgent(
            provider: .claude, pid: pid, parentPID: 1, command: "claude", elapsedSeconds: 60,
            observedAt: observedAt, cwd: "/Users/me/project", session: session, status: status,
            pendingBackgroundTasks: pending,
            statusUpdatedAt: stateAge.map { observedAt.addingTimeInterval(-$0) },
            statusSource: status == nil ? nil : source,
            waitingReason: waitingReason
        )
    }

    private func session(
        id: String = "019fe5b6-6554-7661-8c45-cc6611229c37",
        project: String? = "AgentMeter",
        branch: String? = nil,
        transcriptAge: TimeInterval? = 60,
        model: String? = nil,
        effort: String? = nil,
        title: String? = nil,
        subagents: [ActiveSubagent] = []
    ) -> ActiveAgentSession {
        ActiveAgentSession(
            id: id, projectPath: project.map { "/Users/me/\($0)" }, projectName: project, branch: branch,
            lastUpdatedAt: transcriptAge.map { observedAt.addingTimeInterval(-$0) }, source: "test",
            model: model, effort: effort, title: title, subagents: subagents
        )
    }

    /// The tooltip with what the system's locale data varies between macOS
    /// versions read one way: the narrow no-break space before "AM"/"PM", and
    /// "Oct 28 at 11:00 PM" against "Oct 28, 11:00 PM".
    private func tooltip(_ agent: ActiveAgent) -> String {
        ActiveAgentTooltip.text(for: agent, locale: american, timeZone: utc)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: " at ", with: ", ")
    }

    // MARK: Structure

    func testTooltipReadsInThreeBlocksFromWhatItIsToWhatClickingDoes() {
        let row = agent(
            status: .idle, stateAge: 8 * 86_400 + 300,
            session: session(branch: "feature/x", transcriptAge: 8 * 86_400 + 300,
                             model: "claude-fable-5-1", effort: "xhigh", title: "Fix the\nflaky   login test")
        )

        XCTAssertEqual(tooltip(row), """
        Fix the flaky login test
        Idle · Last activity: 8d ago (Oct 21, 11:55 AM)

        Project AgentMeter · Branch feature/x
        Model fable 5.1 (claude-fable-5-1) · Effort xhigh

        PID #501 · Session 019fe5b6-6554-7661-8c45-cc6611229c37
        Click to bring forward its tab in iTerm2, Terminal or Ghostty, its window in VS Code or Cursor, else its app
        """)
    }

    func testWithoutATitleTheProjectNamesTheSessionAndOnlyTheBranchFollows() {
        let row = agent(session: session(branch: "main", transcriptAge: 300))

        XCTAssertEqual(tooltip(row), """
        AgentMeter
        Idle · Last activity: 5m ago

        Branch main

        PID #501 · Session 019fe5b6-6554-7661-8c45-cc6611229c37
        Click to bring forward its tab in iTerm2, Terminal or Ghostty, its window in VS Code or Cursor, else its app
        """)
    }

    func testTheSessionIdIsShownWhole() {
        let id = "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"

        XCTAssertTrue(tooltip(agent(session: session(id: id))).contains("Session \(id)"))
    }

    func testAnIdThatIsNotFitToBeAFileNameIsLeftOut() {
        // The id is provider text read from the transcript; a newline in it
        // would add lines of its own to the tooltip.
        for id in ["abc\ninjected line", String(repeating: "a", count: 200), "with space", ""] {
            let text = tooltip(agent(session: session(id: id)))

            XCTAssertFalse(text.contains("injected"), id)
            XCTAssertTrue(text.contains("PID #501\nClick"), "the id drops, the PID stays: \(text)")
        }
    }

    func testTheModelUsesTheRowsNameAndKeepsTheIdItCameFrom() {
        func model(_ id: String) -> String? {
            tooltip(agent(session: session(model: id))).components(separatedBy: "\n").first { $0.hasPrefix("Model") }
        }

        // The row's own formatter, the snapshot date still reachable.
        XCTAssertEqual(model("claude-opus-4-1-20250805"), "Model opus 4.1 (claude-opus-4-1-20250805)")
        XCTAssertEqual(model("claude-fable-5-1"), "Model fable 5.1 (claude-fable-5-1)")
        // An id the row shows as it is has nothing to bracket.
        XCTAssertEqual(model("gpt-5-codex"), "Model gpt-5-codex")
    }

    func testTheModelIsOneBoundedLine() {
        let text = tooltip(agent(session: session(model: "claude-x\nINJECTED LINE\u{1B}[31m")))

        XCTAssertFalse(text.components(separatedBy: "\n").contains { $0.hasPrefix("INJECTED") })
        XCTAssertTrue(text.contains("Model xINJECTED LINE[31m (claude-xINJECTED LINE[31m)"))
        XCTAssertLessThanOrEqual(
            tooltip(agent(session: session(model: String(repeating: "m", count: 300))))
                .components(separatedBy: "\n").first { $0.hasPrefix("Model") }?.count ?? 0, "Model ".count + 40)
    }

    func testALongTitleReadsBeyondTheRowsCapButStaysBounded() {
        let long = String(repeating: "x", count: 150)
        let longer = String(repeating: "y", count: 400)

        XCTAssertEqual(SessionLabel.title(long)?.count, 80, "the row's cap")
        XCTAssertEqual(tooltip(agent(session: session(title: long))).components(separatedBy: "\n")[0], long)
        XCTAssertEqual(tooltip(agent(session: session(title: longer))).components(separatedBy: "\n")[0].count, 240)
    }

    func testAPlaceholderModelIsOmitted() {
        let row = agent(session: session(model: "default"))

        XCTAssertFalse(tooltip(row).contains("Model"))
    }

    func testSubagentShareGetsItsOwnLineAndSaysItIsInTheTotal() {
        func subagent(_ id: String, tokens: Int?, cost: Double?) -> ActiveSubagent {
            ActiveSubagent(id: id, logPath: "/t/agent-\(id).jsonl", lastUpdatedAt: observedAt,
                           observedAt: observedAt, tokenCount: tokens, estimatedCostUSD: cost)
        }
        func lines(_ subagents: [ActiveSubagent]) -> [String] {
            tooltip(agent(status: .working, session: session(model: "claude-fable-5-1", effort: "xhigh",
                                                              subagents: subagents)))
                .components(separatedBy: "\n")
        }

        // Every subagent the session ran, listed or not; the row's total
        // already contains this share.
        XCTAssertTrue(lines([
            subagent("a", tokens: 1_000_000, cost: 2.00),
            subagent("b", tokens: 500_000, cost: 0.50),
            subagent("c", tokens: nil, cost: nil),
        ]).contains("Includes 3 subagents (1.5M · $2.50 of the total)"))
        XCTAssertTrue(lines([subagent("a", tokens: nil, cost: nil)]).contains("Includes 1 subagent"))
        XCTAssertFalse(lines([]).contains { $0.hasPrefix("Includes") })
    }

    func testAnIdleSessionWithBackgroundWorkSaysWhatTheCountCounts() {
        let row = agent(status: .idle, stateAge: 120, pending: 2, session: session(transcriptAge: 120))

        XCTAssertTrue(tooltip(row).contains(
            "Idle · Last activity: 2m ago\nThe last turn ended with 2 background tasks still in flight"))
    }

    func testWithoutASessionOnlyWhatIsKnownIsShown() {
        let row = agent(pid: 42, status: .working, stateAge: nil)

        XCTAssertEqual(tooltip(row), "project\nWorking\n\nPID #42\nClick to bring forward its tab in iTerm2, Terminal or Ghostty, its window in VS Code or Cursor, else its app")
    }

    // MARK: States

    func testEachStateReadsInItsOwnWords() {
        func state(_ row: ActiveAgent) -> String { tooltip(row).components(separatedBy: "\n")[1] }

        XCTAssertEqual(state(agent(status: .working, stateAge: 5)), "Working · Last activity: 5s ago")
        XCTAssertEqual(state(agent(status: .waiting, stateAge: 90, waitingReason: .permission)),
                       "Waiting for permission · Last activity: 1m ago")
        XCTAssertEqual(state(agent(status: .waiting, stateAge: 90, waitingReason: .input)),
                       "Waiting for your input · Last activity: 1m ago")
        XCTAssertEqual(state(agent(status: .waiting, source: .registry, stateAge: 90)),
                       "Waiting · Last activity: 1m ago")
        XCTAssertEqual(state(agent(status: .waiting, source: .hook, stateAge: 90)),
                       "Waiting for your input · Last activity: 1m ago")
        XCTAssertEqual(state(agent(status: .error, source: .hook, stateAge: 3_000)),
                       "Failed · Last activity: 50m ago")
        XCTAssertEqual(state(agent(status: nil)), "Open")
    }

    func testAFailureOlderThanAnHourReadsAsIdle() {
        let stale = agent(status: .error, source: .hook, stateAge: ActiveAgent.errorAttentionWindow + 3_600)

        XCTAssertEqual(tooltip(stale).components(separatedBy: "\n")[1],
                       "Idle · Last activity: 2h ago (10:00 AM)")
    }

    // MARK: Last activity

    func testTheExactMomentJoinsOnlyOnceTheRelativeAgeIsAnHourOrMore() {
        func line(_ age: TimeInterval) -> String {
            tooltip(agent(stateAge: age, session: session(transcriptAge: age))).components(separatedBy: "\n")[1]
        }

        XCTAssertEqual(line(59 * 60), "Idle · Last activity: 59m ago")
        XCTAssertEqual(line(3_600), "Idle · Last activity: 1h ago (11:00 AM)")
        XCTAssertEqual(line(3 * 3_600 + 1_800), "Idle · Last activity: 3h ago (8:30 AM)")
        XCTAssertEqual(line(30 * 3_600), "Idle · Last activity: 1d ago (Oct 28, 6:00 AM)")
    }

    func testTheYearAppearsAcrossAYearBoundary() {
        let age = observedAt.timeIntervalSince(Date(timeIntervalSince1970: 1_767_086_100))

        XCTAssertEqual(tooltip(agent(stateAge: age, session: session(transcriptAge: age))).components(separatedBy: "\n")[1],
                       "Idle · Last activity: 303d ago (Dec 30, 2025, 9:15 AM)")
    }

    func testAnUnknownTimeIsNotInventedAndNothingElseDrops() {
        let row = agent(status: .idle, stateAge: nil, session: session(transcriptAge: nil))

        let text = tooltip(row)

        XCTAssertEqual(text.components(separatedBy: "\n")[1], "Idle")
        XCTAssertFalse(text.contains("Last activity"))
        XCTAssertTrue(text.contains("PID #501"))
    }

    func testTheTooltipRowListingAndOrderShareOneLastActivity() {
        // The state last changed 10 minutes ago, the transcript 3 days ago:
        // the row, the tooltip and the filter all use the newer one.
        let row = agent(status: .idle, stateAge: 600, session: session(transcriptAge: 3 * 86_400))

        XCTAssertEqual(row.lastActivityAt, observedAt.addingTimeInterval(-600))
        XCTAssertEqual(row.activityText, "idle · 10m ago")
        XCTAssertTrue(tooltip(row).contains("Idle · Last activity: 10m ago"))
        XCTAssertTrue(row.isListed)

        // And the other way round, with the state three days old.
        let other = agent(status: .idle, stateAge: 3 * 86_400, session: session(transcriptAge: 600))
        XCTAssertEqual(other.activityText, "idle · 10m ago")
        XCTAssertTrue(tooltip(other).contains("Idle · Last activity: 10m ago"))
    }

    func testSubagentRowReadsItsOwnModelEffortStateAndUsage() {
        let observedAt = Date(timeIntervalSince1970: 10_000)
        func subagent(age: TimeInterval, description: String? = "Investigate weekly run-out bound",
                      tokens: Int? = 2_100_000, cost: Double? = 5.40,
                      model: String? = "claude-fable-5-1", effort: String? = "xhigh") -> ActiveSubagent {
            ActiveSubagent(
                id: "a0000000000000003", logPath: "/t/agent-a0000000000000003.jsonl",
                lastUpdatedAt: observedAt.addingTimeInterval(-age), observedAt: observedAt,
                description: description, agentType: "general-purpose",
                tokenCount: tokens, estimatedCostUSD: cost, model: model, effort: effort
            )
        }

        let running = subagent(age: 30)
        XCTAssertEqual(running.displayTitle, "Investigate weekly run-out bound")
        XCTAssertEqual(running.subtitleText, "fable 5.1 · xhigh · working now")
        XCTAssertEqual(running.usageText, "2.1M · $5.40")
        XCTAssertTrue(running.isListed)

        let finished = subagent(age: 200, model: "claude-haiku-4", effort: nil)
        XCTAssertEqual(finished.subtitleText, "haiku 4 · done · 3m ago")
        XCTAssertFalse(finished.isWorking)
        XCTAssertTrue(finished.isListed)
        XCTAssertFalse(subagent(age: ActiveSubagent.lingerWindow + 1).isListed)

        // Description and effort are provider text; the id fills in for none.
        XCTAssertEqual(subagent(age: 1, description: "Review\n\u{1B}[31m  changes").displayTitle, "Review [31m changes")
        XCTAssertEqual(subagent(age: 1, description: nil).displayTitle, "agent a0000000")
        XCTAssertEqual(subagent(age: 1, tokens: nil, cost: nil).usageText, "No usage yet")
        XCTAssertEqual(subagent(age: 1, cost: 0.001).usageText, "2.1M")
        XCTAssertEqual(subagent(age: 1, model: "<synthetic>", effort: String(repeating: "m", count: 40)).subtitleText,
                       String(repeating: "m", count: 16) + " · working now")
    }

    func testSubagentTooltipGivesTheDescriptionItsOwnLine() {
        let observedAt = Date(timeIntervalSince1970: 10_000)
        let subagent = ActiveSubagent(
            id: "a0000000000000003", logPath: "/t/agent-a0000000000000003.jsonl",
            lastUpdatedAt: observedAt.addingTimeInterval(-30), observedAt: observedAt,
            description: "Investigate weekly\nrun-out bound", agentType: "general-purpose",
            tokenCount: 2_100_000, estimatedCostUSD: 5.40, model: "claude-fable-5-1", effort: "xhigh"
        )

        XCTAssertEqual(
            ActiveAgentTooltip.text(for: subagent),
            "Subagent running\nInvestigate weekly run-out bound\ngeneral-purpose · Agent a0000000 · claude-fable-5-1 · xhigh"
        )
    }
}
