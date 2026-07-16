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
        status: AgentStatusState? = nil
    ) -> ActiveAgent {
        ActiveAgent(
            provider: provider,
            pid: pid,
            parentPID: 1,
            command: provider.rawValue,
            elapsedSeconds: elapsed,
            observedAt: Date(timeIntervalSince1970: 0),
            cwd: cwd,
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

    func testInvalidParentCycleDoesNotHideAgents() {
        let groups = ActiveAgentGrouping.group([
            agent(pid: 100, cwd: "/tmp/a", parentAgentPID: 101),
            agent(pid: 101, cwd: "/tmp/a", parentAgentPID: 100),
        ])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.agentCount }, 2)
    }
}
