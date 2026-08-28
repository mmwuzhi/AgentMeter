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
        lastUpdatedAt: Date? = nil
    ) -> ActiveAgent {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        return ActiveAgent(
            provider: provider,
            pid: pid,
            parentPID: 1,
            command: provider.rawValue,
            elapsedSeconds: elapsed,
            observedAt: observedAt,
            cwd: cwd,
            session: lastUpdatedAt.map {
                ActiveAgentSession(
                    id: "session-\(pid)",
                    projectPath: cwd,
                    projectName: nil,
                    branch: nil,
                    lastUpdatedAt: $0,
                    source: "test"
                )
            },
            parentAgentPID: parentAgentPID,
            status: status
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

    func testInvalidParentCycleDoesNotHideAgents() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/tmp/a", parentAgentPID: 101),
            agent(pid: 101, cwd: "/tmp/a", parentAgentPID: 100),
        ])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.agentCount }, 2)
    }
}
