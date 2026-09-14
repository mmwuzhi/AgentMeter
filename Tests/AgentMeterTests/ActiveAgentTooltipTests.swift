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
