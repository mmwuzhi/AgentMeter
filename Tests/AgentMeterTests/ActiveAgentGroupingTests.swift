import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

final class ActiveAgentGroupingTests: XCTestCase {
    private func agent(
        provider: Provider = .claude,
        pid: Int,
        cwd: String?,
        elapsed: TimeInterval = 60,
        parentAgentPID: Int? = nil,
        status: AgentStatusState? = nil,
        lastUpdatedAt: Date? = nil,
        subagents: [ActiveSubagent] = []
    ) -> ActiveAgent {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        var session: ActiveAgentSession?
        if lastUpdatedAt != nil || !subagents.isEmpty {
            session = ActiveAgentSession(
                id: "session-\(pid)",
                projectPath: cwd,
                projectName: nil,
                branch: nil,
                lastUpdatedAt: lastUpdatedAt,
                source: "test",
                subagents: subagents
            )
        }
        return ActiveAgent(
            provider: provider,
            pid: pid,
            parentPID: 1,
            command: provider.rawValue,
            elapsedSeconds: elapsed,
            observedAt: observedAt,
            cwd: cwd,
            session: session,
            parentAgentPID: parentAgentPID,
            status: status
        )
    }

    /// A transcript-derived subagent whose file changed `age` seconds before
    /// the fixtures' shared `observedAt`.
    private func subagent(_ id: String, age: TimeInterval, tokens: Int? = nil, cost: Double? = nil) -> ActiveSubagent {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        return ActiveSubagent(
            id: id,
            logPath: "/t/subagents/agent-\(id).jsonl",
            lastUpdatedAt: observedAt.addingTimeInterval(-age),
            observedAt: observedAt,
            tokenCount: tokens,
            estimatedCostUSD: cost
        )
    }

    func testSingleSessionIsFlatGroup() {
        let groups = ActiveAgentGrouping.group([agent(pid: 1, cwd: "/Users/me/alpha")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isFlat)
        XCTAssertEqual(groups[0].projectName, "alpha")
    }

    func testSiblingSessionsInSameProjectMerge() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 1, cwd: "/Users/me/alpha", elapsed: 30),
            agent(pid: 2, cwd: "/Users/me/alpha", elapsed: 90),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].nodes.map(\.agent.pid), [2, 1])
        XCTAssertEqual(groups[0].agentCount, 2)
    }

    func testChildAgentNestsUnderTopAncestor() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha", elapsed: 200),
            agent(pid: 101, cwd: "/Users/me/alpha", parentAgentPID: 100),
            agent(pid: 102, cwd: "/Users/me/alpha", parentAgentPID: 101),
        ])
        XCTAssertEqual(groups[0].nodes.count, 1)
        XCTAssertEqual(Set(groups[0].nodes[0].children.map(\.pid)), [101, 102])
    }

    func testChildAttentionStatePromotesWholeGroup() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha", status: .working),
            agent(pid: 101, cwd: "/Users/me/alpha", parentAgentPID: 100, status: .error),
        ])
        XCTAssertEqual(groups[0].topStatus, .error)
    }

    func testCollapsedSummaryCountsStatusAndAggregatesUsage() {
        let updated = Date(timeIntervalSince1970: 990)
        var busy = agent(pid: 1, cwd: "/Users/me/alpha", status: .working, lastUpdatedAt: updated)
        busy.session?.tokenCount = 2_000_000
        busy.session?.estimatedCostUSD = 1.10
        var second = agent(pid: 2, cwd: "/Users/me/alpha", status: .working, lastUpdatedAt: updated)
        second.session?.tokenCount = 500_000
        second.session?.estimatedCostUSD = 0.10
        let idle = agent(pid: 3, cwd: "/Users/me/alpha", status: .idle)

        let group = ActiveAgentGrouping.group([busy, second, idle])[0]

        XCTAssertEqual(group.collapsedSummary, "3 · 2 working · 2.5M · $1.20")
    }

    func testCollapsedSummaryOmitsIdleStatusAndUnknownUsage() {
        let group = ActiveAgentGrouping.group([
            agent(pid: 1, cwd: "/Users/me/alpha", status: .idle),
            agent(pid: 2, cwd: "/Users/me/alpha"),
        ])[0]

        XCTAssertEqual(group.collapsedSummary, "2")
    }

    func testGroupNeedsAttentionOnlyForWaitingOrError() {
        func group(_ status: AgentStatusState?) -> ActiveAgentGroup {
            ActiveAgentGrouping.group([agent(pid: 1, cwd: "/Users/me/alpha", status: status)])[0]
        }
        XCTAssertFalse(group(nil).needsAttention)
        XCTAssertFalse(group(.idle).needsAttention)
        XCTAssertFalse(group(.working).needsAttention)
        XCTAssertTrue(group(.waiting).needsAttention)
        XCTAssertTrue(group(.error).needsAttention)
    }

    func testStaleErrorNeitherRedsNorExpandsTheGroup() {
        var failed = agent(pid: 1, cwd: "/Users/me/alpha", status: .error)
        failed.statusUpdatedAt = failed.observedAt.addingTimeInterval(-ActiveAgent.errorAttentionWindow - 1)
        let group = ActiveAgentGrouping.group([failed, agent(pid: 2, cwd: "/Users/me/alpha", status: .idle)])[0]

        XCTAssertEqual(group.topStatus, .idle)
        XCTAssertFalse(group.needsAttention)
        XCTAssertEqual(group.collapsedSummary, "2")
    }

    func testChildrenNeedAttentionFlagsWaitingSubagent() {
        let calm = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha", status: .working),
            agent(pid: 101, cwd: "/Users/me/alpha", parentAgentPID: 100, status: .working),
        ])[0].nodes[0]
        let urgent = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha", status: .working),
            agent(pid: 101, cwd: "/Users/me/alpha", parentAgentPID: 100, status: .waiting),
        ])[0].nodes[0]

        XCTAssertFalse(calm.childrenNeedAttention)
        XCTAssertTrue(urgent.childrenNeedAttention)
    }

    func testRecentActivityPromotesGroupAndSessionOrder() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha", elapsed: 500),
            agent(pid: 200, cwd: "/Users/me/beta", elapsed: 10, lastUpdatedAt: Date(timeIntervalSince1970: 990)),
            agent(pid: 201, cwd: "/Users/me/beta", elapsed: 600),
        ])

        XCTAssertEqual(groups.map(\.projectName), ["beta", "alpha"])
        XCTAssertEqual(groups[0].topStatus, .working)
        XCTAssertEqual(groups[0].nodes.map(\.agent.pid), [200, 201])
    }

    func testDifferentProviderCannotBecomeParent() {
        let groups = ActiveAgentGrouping.group([
            agent(provider: .codex, pid: 100, cwd: "/Users/me/alpha"),
            agent(provider: .claude, pid: 101, cwd: "/Users/me/alpha", parentAgentPID: 100),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy(\.isFlat))
    }

    func testPathlessSessionsDoNotMerge() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 1, cwd: nil),
            agent(pid: 2, cwd: nil),
        ])
        XCTAssertEqual(groups.count, 2)
    }

    func testDisclosureKeysCoverGroupsAndOnlyParentsWithChildren() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha"),
            agent(pid: 101, cwd: "/Users/me/alpha", parentAgentPID: 100),
            agent(pid: 200, cwd: "/Users/me/beta"),
        ])

        let keys = ActiveAgentGrouping.disclosureKeys(for: groups)

        XCTAssertTrue(keys.contains("claude:/Users/me/alpha"))
        XCTAssertTrue(keys.contains("claude:/Users/me/beta"))
        let parent = groups.first { $0.projectName == "alpha" }!.nodes[0]
        XCTAssertTrue(keys.contains(parent.disclosureKey))
        XCTAssertEqual(keys.count, 3, "childless nodes get no subagent key")
    }

    func testListedSubagentsAttachToTheirSessionNodeWithoutCountingAsAgents() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha", status: .idle, subagents: [
                subagent("running", age: 30),
                subagent("fresh", age: ActiveSubagent.lingerWindow - 1),
                subagent("stale", age: ActiveSubagent.lingerWindow + 1),
                subagent("morning", age: 3_600),
            ]),
            agent(pid: 200, cwd: "/Users/me/alpha"),
        ])
        let group = groups[0]
        let node = group.nodes.first { $0.agent.pid == 100 }!

        XCTAssertEqual(node.subagents.map(\.id), ["running", "fresh"], "finished past the linger window: hidden")
        XCTAssertEqual(node.childRowCount, 2)
        XCTAssertTrue(node.hasChildRows)
        XCTAssertTrue(node.children.isEmpty, "subagents are not processes")
        XCTAssertEqual(group.agentCount, 2, "the header counts processes only")
        XCTAssertEqual(node.topStatus, .idle, "a working subagent does not colour the parent; the hook does")
        XCTAssertTrue(node.subagents[0].isWorking)
        XCTAssertFalse(node.subagents[1].isWorking)
    }

    func testDisclosureKeysIncludeNodesWhoseOnlyChildrenAreListedSubagents() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha", subagents: [subagent("a", age: 10)]),
            agent(pid: 101, cwd: "/Users/me/alpha", subagents: [subagent("old", age: 7_200)]),
        ])

        let keys = ActiveAgentGrouping.disclosureKeys(for: groups)

        XCTAssertTrue(keys.contains("subagents:claude:100"))
        XCTAssertFalse(keys.contains("subagents:claude:101"), "nothing listed, nothing to disclose")
        XCTAssertEqual(keys.count, 2)
    }

    func testCollapsedSummaryUsesTheSessionTotalWhichAlreadyIncludesEverySubagent() {
        var parent = agent(pid: 1, cwd: "/Users/me/alpha", status: .working, lastUpdatedAt: Date(timeIntervalSince1970: 990), subagents: [
            subagent("listed", age: 10, tokens: 400_000, cost: 0.20),
            subagent("hidden", age: 7_200, tokens: 600_000, cost: 0.30),
        ])
        // What the service wrote: main 1.5M/$0.70 plus both subagents.
        parent.session?.tokenCount = 2_500_000
        parent.session?.estimatedCostUSD = 1.20

        let group = ActiveAgentGrouping.group([parent, agent(pid: 2, cwd: "/Users/me/alpha", status: .idle)])[0]

        XCTAssertEqual(group.collapsedSummary, "2 · 1 working · 2.5M · $1.20")
        XCTAssertEqual(parent.session?.subagentUsageText, "Includes 2 subagents (1M · $0.50 of the total)")
    }

    func testChildRowLabelCountsTheRowsAndHowManyStillRun() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/Users/me/alpha", subagents: [
                subagent("a", age: 10),
                subagent("b", age: 30),
                subagent("settled", age: 400),
            ]),
            agent(pid: 200, cwd: "/Users/me/alpha", subagents: [subagent("only", age: 400)]),
            agent(pid: 300, cwd: "/Users/me/beta", subagents: [subagent("lone", age: 5)]),
        ])
        let alpha = groups.first { $0.projectName == "alpha" }!
        let beta = groups.first { $0.projectName == "beta" }!

        XCTAssertEqual(alpha.nodes.first { $0.agent.pid == 100 }?.childRowLabel, "3 subagents · 2 working")
        XCTAssertEqual(alpha.nodes.first { $0.agent.pid == 200 }?.childRowLabel, "1 subagent",
                       "finished within the linger window: listed, not running")
        XCTAssertTrue(beta.isFlat, "one session, no child processes")
        XCTAssertTrue(beta.nodes[0].hasChildRows, "a flat group still has subagent rows to disclose")
        XCTAssertEqual(beta.nodes[0].childRowLabel, "1 subagent · 1 working")
    }

    func testInvalidParentCycleDoesNotHideAgents() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/tmp/a", parentAgentPID: 101),
            agent(pid: 101, cwd: "/tmp/a", parentAgentPID: 100),
        ])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.agentCount }, 2)
    }
}
