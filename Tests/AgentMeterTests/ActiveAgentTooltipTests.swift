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
