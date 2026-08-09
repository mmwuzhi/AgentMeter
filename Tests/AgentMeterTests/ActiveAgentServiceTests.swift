import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

final class ActiveAgentServiceTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    func testParsePSOutputFindsInteractiveAgents() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        51001 12001 06-01:00:00 claude --resume
        51002 12002    05:30:00 claude
        11111 22222       04:03 /Users/me/.local/bin/codex
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 0),
            cwdLookup: { _ in nil },
            sessionLookup: { _, _, _, _ in nil }
        )

        XCTAssertEqual(agents.map(\.provider), [.claude, .claude, .codex])
        XCTAssertEqual(agents.map(\.pid), [51001, 51002, 11111])
    }

    func testParsePSOutputCapturesTTYAndAgentParent() {
        let output = """
          PID  PPID TT       ELAPSED COMMAND
        10000     1 ttys001     01:00 claude
        10001 10000 ttys001     00:30 /bin/zsh -l
        10002 10001 ttys001     00:10 claude --resume
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 100),
            cwdLookup: { _ in "/Users/me/project" },
            sessionLookup: { _, _, _, _ in nil }
        )

        XCTAssertEqual(agents.map(\.tty), ["ttys001", "ttys001"])
        XCTAssertEqual(agents.first(where: { $0.pid == 10002 })?.parentAgentPID, 10000)
    }

    func testStatusPayloadAncestryDisambiguatesSameDirectorySessions() {
        let now = Date(timeIntervalSince1970: 100)
        let agents = [
            ActiveAgent(provider: .claude, pid: 100, parentPID: 1, command: "claude",
                        elapsedSeconds: 20, observedAt: now, cwd: "/tmp/project"),
            ActiveAgent(provider: .claude, pid: 200, parentPID: 1, command: "claude",
                        elapsedSeconds: 10, observedAt: now, cwd: "/tmp/project"),
        ]
        let payloads = [
            AgentStatusPayload(state: .waiting, sessionID: "a", processAncestry: [501, 100, 1], updatedAt: now),
            AgentStatusPayload(state: .working, sessionID: "b", processAncestry: [502, 200, 1], updatedAt: now),
        ]

        let attached = ActiveAgentService.attachStatus(agents, payloads: payloads)

        XCTAssertEqual(attached.first(where: { $0.pid == 100 })?.status, .waiting)
        XCTAssertEqual(attached.first(where: { $0.pid == 200 })?.status, .working)
    }

    func testStatusPayloadFromOlderPIDLifetimeIsIgnored() {
        let now = Date(timeIntervalSince1970: 10_000)
        let agent = ActiveAgent(
            provider: .claude,
            pid: 100,
            parentPID: 1,
            command: "claude",
            elapsedSeconds: 10,
            observedAt: now
        )
        let stale = AgentStatusPayload(
            state: .error,
            sessionID: "old",
            processAncestry: [100],
            updatedAt: now.addingTimeInterval(-100)
        )

        XCTAssertNil(ActiveAgentService.attachStatus([agent], payloads: [stale]).first?.status)
    }

    func testParsePSOutputExcludesUsageAndAppServerHelpers() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10000 99999       00:10 claude /usage
        10001 99999       00:10 /Applications/Codex.app/Contents/Resources/codex app-server
        10002 99999       00:10 /Applications/Codex.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)
        10003 99999       00:10 /Applications/AgentMeter.app/Contents/MacOS/AgentMeter
        10004 99999       00:10 claude --resume
        10005 99999       00:10 /Users/me/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
        10006 99999       00:10 ./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient mcp
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

    func testParsePSOutputExcludesChatGPTDesktopHelpersAndConfiguredAppServer() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10001      1 12-03:59:18 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150/Helpers/browser_crashpad_handler --handshake-fd=5
        10002  99999       03:52 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/151/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer) --seatbelt-client=165
        10003  99999       03:52 /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
        10004  10003       02:53 /Applications/ChatGPT.app/Contents/Resources/codex sandbox -c shell_environment_policy.inherit=all
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 10_000),
            cwdLookup: { pid in pid == 10004 ? "/Users/me/project" : "/" },
            sessionLookup: { provider, cwd, _, _ in
                guard provider == .codex, cwd == "/Users/me/project" else { return nil }
                return ActiveAgentSession(
                    id: "session-10004",
                    projectPath: cwd,
                    projectName: "project",
                    branch: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 9_990),
                    source: "test"
                )
            }
        )

        XCTAssertEqual(agents.map(\.pid), [10004])
        XCTAssertEqual(agents.first?.session?.projectName, "project")
    }

    func testParsePSOutputIncludesCodexDesktopApp() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10002 99999       00:10 /Applications/Codex.app/Contents/MacOS/Codex
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 0),
            cwdLookup: { _ in nil },
            sessionLookup: { _, _, _, _ in nil }
        )

        XCTAssertEqual(agents.map(\.pid), [10002])
        XCTAssertEqual(agents.first?.provider, .codex)
    }

    func testParsePSOutputIncludesClaudeDesktopExecutableWithSpaces() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10002 99999       00:10 /Users/me/Library/Application Support/Claude/claude-code/claude --resume
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 0),
            cwdLookup: { _ in nil },
            sessionLookup: { _, _, _, _ in nil }
        )

        XCTAssertEqual(agents.map(\.pid), [10002])
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

    func testActiveAgentPresentationUsesProjectSourceAndLastActivity() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = ActiveAgent(
            provider: .codex,
            pid: 100,
            parentPID: 1,
            command: "/Applications/ChatGPT.app/Contents/Resources/codex sandbox",
            elapsedSeconds: 7 * 86_400,
            observedAt: now,
            cwd: "/Users/me/project",
            session: ActiveAgentSession(
                id: "session-100",
                projectPath: "/Users/me/project",
                projectName: "project",
                branch: nil,
                lastUpdatedAt: now.addingTimeInterval(-30),
                source: "test"
            )
        )
        let idle = ActiveAgent(
            provider: .codex,
            pid: 101,
            parentPID: 1,
            command: "/usr/local/bin/codex exec",
            elapsedSeconds: 3_600,
            observedAt: now,
            cwd: "/Users/me/other",
            session: ActiveAgentSession(
                id: "session-101",
                projectPath: "/Users/me/other",
                projectName: "other",
                branch: nil,
                lastUpdatedAt: now.addingTimeInterval(-8 * 60),
                source: "test"
            )
        )
        let unresolved = ActiveAgent(
            provider: .claude,
            pid: 102,
            parentPID: 1,
            command: "claude",
            elapsedSeconds: 10,
            observedAt: now
        )

        XCTAssertEqual(recent.displayTitle, "project")
        XCTAssertEqual(recent.sourceLabel, "Codex Desktop")
        XCTAssertEqual(recent.displayStatus, .working)
        XCTAssertEqual(recent.activityText, "active now")
        XCTAssertEqual(recent.usageDisplayText, "No usage yet")
        XCTAssertEqual(idle.displayStatus, .idle)
        XCTAssertEqual(idle.activityText, "idle · 8m ago")
        XCTAssertEqual(unresolved.activityText, "open now")
        XCTAssertEqual(unresolved.usageDisplayText, "Usage unavailable")
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

    func testCWDMapParsesBatchLsofFieldOutput() {
        let output = """
        p10004
        fcwd
        n/Users/me/project-a
        p10005
        fcwd
        n/Users/me/project-b
        """

        let cwdByPID = ActiveAgentService.cwdMap(fromLsofOutput: output)

        XCTAssertEqual(cwdByPID[10004], "/Users/me/project-a")
        XCTAssertEqual(cwdByPID[10005], "/Users/me/project-b")
    }

    func testRunProcessTimesOut() {
        let start = Date()

        let output = ActiveAgentService.runProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            timeout: 0.05
        )

        XCTAssertEqual(output, "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testRunProcessDrainsLargeOutputBeforeWaitingForExit() {
        let script = """
        i=0
        while [ "$i" -lt 5000 ]; do
          printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\\n'
          i=$((i + 1))
        done
        """

        let output = ActiveAgentService.runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: 2
        )

        XCTAssertGreaterThan(output.count, 300_000)
    }

    func testClaudeSessionUsageSummaryCountsTokensAndCost() async throws {
        let file = try makeTempFile(contents: """
        {"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":25,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":5}}}}
        {"timestamp":"2026-07-05T00:01:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}
        {"timestamp":"2026-07-05T00:02:00Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-4","usage":{"input_tokens":20,"output_tokens":10,"cache_creation_input_tokens":3}}}
        """)

        let summary = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        XCTAssertEqual(summary?.tokenCount, 223)
        XCTAssertGreaterThan(summary?.estimatedCostUSD ?? 0, 0)
    }

    func testCodexSessionUsageSummaryCountsLastTokenUsage() async throws {
        let file = try makeTempFile(contents: """
        {"timestamp":"2026-07-05T00:00:00Z","payload":{"type":"session_meta","cwd":"/tmp/project","session_id":"s1","model":"gpt-5-codex"}}
        {"timestamp":"2026-07-05T00:01:00Z","payload":{"type":"turn_context","model":"gpt-5-codex"}}
        {"timestamp":"2026-07-05T00:02:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}}}
        {"timestamp":"2026-07-05T00:03:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}
        """)

        let summary = await ActiveAgentService.sessionUsageSummary(provider: .codex, url: file)

        XCTAssertEqual(summary?.tokenCount, 135)
        XCTAssertGreaterThan(summary?.estimatedCostUSD ?? 0, 0)
    }

    func testSessionUsageSummaryCacheInvalidatesWhenLogChanges() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let file = try makeTempFile(contents: """
        {"timestamp":"2026-07-05T00:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}
        """)

        let first = await ActiveAgentService.sessionUsageSummary(provider: .codex, url: file)
        try """
        {"timestamp":"2026-07-05T00:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}
        {"timestamp":"2026-07-05T00:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":10}}}}
        """.data(using: .utf8)?.write(to: file)

        let second = await ActiveAgentService.sessionUsageSummary(provider: .codex, url: file)

        XCTAssertEqual(first?.tokenCount, 15)
        XCTAssertEqual(second?.tokenCount, 45)
    }

    private func makeTempFile(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMeterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let file = dir.appendingPathComponent("session.jsonl")
        try contents.data(using: .utf8)?.write(to: file)
        return file
    }
}
