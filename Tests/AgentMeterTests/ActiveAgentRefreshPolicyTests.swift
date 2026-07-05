import Foundation
@testable import AgentMeter
import XCTest

final class ActiveAgentRefreshPolicyTests: XCTestCase {
    func testForceRefreshAlwaysRefreshesActiveAgents() {
        let now = Date()

        let result = ActiveAgentRefreshPolicy.shouldRefresh(
            forceActiveAgents: true,
            activeAgentsVisible: false,
            lastRefresh: now,
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 300,
            now: now
        )

        XCTAssertTrue(result)
    }

    func testVisibleActiveAgentsRefreshAtForegroundCadence() {
        let now = Date()

        let result = ActiveAgentRefreshPolicy.shouldRefresh(
            forceActiveAgents: false,
            activeAgentsVisible: true,
            lastRefresh: now,
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 300,
            now: now
        )

        XCTAssertTrue(result)
    }

    func testHiddenActiveAgentsWaitForBackgroundMinimum() {
        let now = Date()

        let tooSoon = ActiveAgentRefreshPolicy.shouldRefresh(
            forceActiveAgents: false,
            activeAgentsVisible: false,
            lastRefresh: now.addingTimeInterval(-299),
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 300,
            now: now
        )
        let due = ActiveAgentRefreshPolicy.shouldRefresh(
            forceActiveAgents: false,
            activeAgentsVisible: false,
            lastRefresh: now.addingTimeInterval(-300),
            refreshInterval: 60,
            backgroundMinimumRefreshInterval: 300,
            now: now
        )

        XCTAssertFalse(tooSoon)
        XCTAssertTrue(due)
    }
}
