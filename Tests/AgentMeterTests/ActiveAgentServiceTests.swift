import Foundation
@testable import AgentMeter
import XCTest

final class ActiveAgentServiceTests: XCTestCase {
    func testParsePSOutputFindsInteractiveAgents() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        60787 13438 06-00:44:15 claude --resume
        61272 76962    05:33:10 claude
        11111 22222       04:03 /Users/me/.local/bin/codex
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 0),
            cwdLookup: { _ in nil },
            sessionLookup: { _, _, _, _ in nil }
        )

        XCTAssertEqual(agents.map(\.provider), [.claude, .claude, .codex])
        XCTAssertEqual(agents.map(\.pid), [60787, 61272, 11111])
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

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 0),
            cwdLookup: { _ in nil },
            sessionLookup: { _, _, _, _ in nil }
        )

        XCTAssertEqual(agents.map(\.pid), [10004])
        XCTAssertEqual(agents.first?.provider, .claude)
    }

    func testParsePSOutputAttachesCurrentSession() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10004 99999       00:10 claude --resume
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 100),
            cwdLookup: { pid in
                pid == 10004 ? "/Users/me/project" : nil
            },
            sessionLookup: { provider, cwd, startedAt, _ in
                XCTAssertEqual(provider, .claude)
                XCTAssertEqual(cwd, "/Users/me/project")
                XCTAssertEqual(startedAt, Date(timeIntervalSince1970: 90))
                return ActiveAgentSession(
                    id: "abcdef12-3456",
                    projectPath: cwd,
                    projectName: "project",
                    branch: "main",
                    lastUpdatedAt: Date(timeIntervalSince1970: 99),
                    source: "test"
                )
            }
        )

        XCTAssertEqual(agents.first?.cwd, "/Users/me/project")
        XCTAssertEqual(agents.first?.session?.shortID, "abcdef12")
        XCTAssertEqual(agents.first?.session?.displayProject, "project")
    }

    func testParsePSOutputDoesNotGuessSessionForDuplicateProviderCWD() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10004 99999       00:10 claude --resume
        10005 99999       00:20 claude --resume
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 100),
            cwdLookup: { _ in "/Users/me/project" },
            sessionLookup: { _, _, _, _ in
                XCTFail("Ambiguous same-provider sessions should not be guessed")
                return ActiveAgentSession(
                    id: "abcdef12-3456",
                    projectPath: "/Users/me/project",
                    projectName: "project",
                    branch: "main",
                    lastUpdatedAt: Date(timeIntervalSince1970: 99),
                    source: "test"
                )
            }
        )

        XCTAssertEqual(agents.count, 2)
        XCTAssertTrue(agents.allSatisfy { $0.session == nil })
    }
}
