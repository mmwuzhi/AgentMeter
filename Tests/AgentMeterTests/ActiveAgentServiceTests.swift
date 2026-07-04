import Foundation
@testable import AgentMeter
import XCTest

final class ActiveAgentServiceTests: XCTestCase {
    func testParsePSOutputFindsInteractiveAgents() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        51001 12001 06-01:00:00 claude --resume
        51002 12002    05:30:00 claude
        11111 22222       04:03 /Users/me/.local/bin/codex
        """

        let agents = ActiveAgentService.parsePSOutput(output, observedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(agents.map(\.provider), [.claude, .claude, .codex])
        XCTAssertEqual(agents.map(\.pid), [51001, 51002, 11111])
        XCTAssertEqual(agents[0].elapsedText, "6d")
        XCTAssertEqual(agents[2].elapsedText, "4m")
    }

    func testParsePSOutputExcludesUsageAndAppServerHelpers() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10000 99999       00:10 claude /usage
        10001 99999       00:10 /Applications/Codex.app/Contents/Resources/codex app-server
        10002 99999       00:10 /Applications/Codex.app/Contents/MacOS/Codex
        10003 99999       00:10 /Applications/AgentMeter.app/Contents/MacOS/AgentMeter
        10004 99999       00:10 claude --resume
        """

        let agents = ActiveAgentService.parsePSOutput(output, observedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(agents.map(\.pid), [10004])
        XCTAssertEqual(agents.first?.provider, .claude)
    }
}
