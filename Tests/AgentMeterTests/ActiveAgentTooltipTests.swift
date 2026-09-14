import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

final class ActiveAgentTooltipTests: XCTestCase {
    func testTooltipKeepsUsefulIdentityWithoutExposingCommand() {
        let command = "/Applications/ChatGPT.app/Contents/Resources/codex sandbox --permissions private"
        let agent = ActiveAgent(
            provider: .codex,
            pid: 69_224,
            parentPID: 1,
            command: command,
            elapsedSeconds: 60,
            observedAt: Date(timeIntervalSince1970: 1_000),
            session: ActiveAgentSession(
                id: "019fe5b6-6554-7661-8c45-cc6611229c37",
                projectPath: "/Users/me/project",
                projectName: "AgentMeter",
                branch: nil,
                lastUpdatedAt: Date(timeIntervalSince1970: 0),
                source: "test"
            ),
            status: .idle
        )

        let tooltip = ActiveAgentTooltip.text(for: agent)

        XCTAssertEqual(
            tooltip,
            "Idle, click to jump to this session\nPID #69224 · Session 019fe5b6"
        )
        XCTAssertFalse(tooltip.contains(command))
    }

    func testTooltipCarriesTheFullModelIdWhenTheSessionHasOne() {
        let agent = ActiveAgent(
            provider: .claude,
            pid: 501,
            parentPID: 1,
            command: "claude",
            elapsedSeconds: 60,
            observedAt: Date(timeIntervalSince1970: 1_000),
            session: ActiveAgentSession(
                id: "019fe5b6-6554-7661-8c45-cc6611229c37",
                projectPath: "/Users/me/project",
                projectName: "AgentMeter",
                branch: nil,
                lastUpdatedAt: Date(timeIntervalSince1970: 0),
                source: "test",
                model: "claude-opus-4-1-20250805"
            ),
            status: .working
        )

        // The row shows "opus 4.1"; hovering is how you check the snapshot.
        XCTAssertEqual(
            ActiveAgentTooltip.text(for: agent),
            "Active, click to jump to this session\nPID #501 · Session 019fe5b6 · claude-opus-4-1-20250805"
        )
    }

    func testTooltipGivesTheTitleItsOwnLineAndKeepsBranchAndEffort() {
        let agent = ActiveAgent(
            provider: .claude,
            pid: 503,
            parentPID: 1,
            command: "claude",
            elapsedSeconds: 60,
            observedAt: Date(timeIntervalSince1970: 1_000),
            session: ActiveAgentSession(
                id: "019fe5b6-6554-7661-8c45-cc6611229c37",
                projectPath: "/Users/me/project",
                projectName: "AgentMeter",
                branch: "feature/x",
                lastUpdatedAt: Date(timeIntervalSince1970: 0),
                source: "test",
                model: "claude-fable-5-1",
                effort: "xhigh",
                title: "Fix the\nflaky   login test"
            ),
            status: .working
        )

        // The row shows the title where the branch used to be, truncated in
        // the middle; here it is whole (flattened to one line) and the branch
        // is still reachable.
        XCTAssertEqual(
            ActiveAgentTooltip.text(for: agent),
            "Active, click to jump to this session\nFix the flaky login test\nPID #503 · Session 019fe5b6 · feature/x · claude-fable-5-1 · xhigh"
        )
    }

    func testTooltipOmitsAPlaceholderModel() {
        let agent = ActiveAgent(
            provider: .claude,
            pid: 502,
            parentPID: 1,
            command: "claude",
            elapsedSeconds: 60,
            observedAt: Date(timeIntervalSince1970: 1_000),
            session: ActiveAgentSession(
                id: "abcdef1234567890",
                projectPath: nil,
                projectName: nil,
                branch: nil,
                lastUpdatedAt: nil,
                source: "test",
                model: "default"
            ),
            status: .idle
        )

        XCTAssertEqual(
            ActiveAgentTooltip.text(for: agent),
            "Idle, click to jump to this session\nPID #502 · Session abcdef12"
        )
    }

    func testTooltipAppendsTheSubagentShareToTheIdentityLine() {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        func subagent(_ id: String, tokens: Int?, cost: Double?) -> ActiveSubagent {
            ActiveSubagent(id: id, logPath: "/t/agent-\(id).jsonl", lastUpdatedAt: observedAt,
                           observedAt: observedAt, tokenCount: tokens, estimatedCostUSD: cost)
        }
        func agent(_ subagents: [ActiveSubagent]) -> ActiveAgent {
            ActiveAgent(
                provider: .claude, pid: 504, parentPID: 1, command: "claude", elapsedSeconds: 60,
                observedAt: observedAt,
                session: ActiveAgentSession(
                    id: "b26e035f-2488-4f75-9fc2-7f4d6a50595c", projectPath: "/Users/me/scripts",
                    projectName: "scripts", branch: nil, lastUpdatedAt: observedAt, source: "test",
                    tokenCount: 48_800_000, estimatedCostUSD: 70.71, model: "claude-fable-5-1",
                    effort: "xhigh", subagents: subagents
                ),
                status: .working
            )
        }

        // Every subagent the session ran, listed or not; the row's total
        // already contains this share.
        XCTAssertEqual(
            ActiveAgentTooltip.text(for: agent([
                subagent("a", tokens: 1_000_000, cost: 2.00),
                subagent("b", tokens: 500_000, cost: 0.50),
                subagent("c", tokens: nil, cost: nil),
            ])),
            "Active, click to jump to this session\nPID #504 · Session b26e035f · claude-fable-5-1 · xhigh · incl. 3 subagents · 1.5M · $2.50"
        )
        XCTAssertEqual(
            ActiveAgentTooltip.text(for: agent([subagent("a", tokens: nil, cost: nil)])),
            "Active, click to jump to this session\nPID #504 · Session b26e035f · claude-fable-5-1 · xhigh · incl. 1 subagent"
        )
        XCTAssertFalse(ActiveAgentTooltip.text(for: agent([])).contains("incl."))
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

    func testTooltipWithoutSessionUsesTwoCompactLines() {
        let agent = ActiveAgent(
            provider: .claude,
            pid: 42,
            parentPID: 1,
            command: "claude",
            elapsedSeconds: 10,
            observedAt: Date(timeIntervalSince1970: 1_000),
            status: .working
        )

        XCTAssertEqual(
            ActiveAgentTooltip.text(for: agent),
            "Active, click to jump to this session\nPID #42"
        )
    }
}
