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
        10005      1       02:53 /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host
        10006      1       00:10 /usr/bin/rg /Applications/ChatGPT.app/Contents/Resources/codex
        10007      1       00:10 /usr/bin/rg /Users/me/Library/Application Support/Claude/claude-code/claude
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

    func testParsePSOutputExcludesCodexDesktopShellProcess() {
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

        XCTAssertTrue(agents.isEmpty)
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
        let farFuture = ActiveAgent(
            provider: .codex,
            pid: 103,
            parentPID: 1,
            command: "codex",
            elapsedSeconds: 10,
            observedAt: now,
            session: ActiveAgentSession(
                id: "session-103",
                projectPath: "/Users/me/future",
                projectName: "future",
                branch: nil,
                lastUpdatedAt: now.addingTimeInterval(3_600),
                source: "test"
            )
        )

        XCTAssertEqual(recent.displayTitle, "project")
        XCTAssertEqual(recent.sourceLabel, "Codex Desktop")
        XCTAssertEqual(recent.displayStatus, .working)
        XCTAssertEqual(recent.activityText, "active now")
        XCTAssertEqual(recent.usageDisplayText, "No usage yet")
        XCTAssertEqual(idle.displayStatus, .idle)
        XCTAssertEqual(idle.activityText, "idle · 8m ago")
        XCTAssertEqual(unresolved.activityText, "open now")
        XCTAssertNil(unresolved.usageDisplayText, "unattributed processes render no usage text")
        XCTAssertEqual(farFuture.displayStatus, .idle)
        XCTAssertEqual(farFuture.activityText, "idle · 0s ago")
    }

    func testInGroupRowTextPrefersDistinguishingDetails() {
        let now = Date(timeIntervalSince1970: 10_000)
        let withBranch = ActiveAgent(
            provider: .claude, pid: 100, parentPID: 1, command: "claude",
            elapsedSeconds: 10, observedAt: now, tty: "ttys001",
            session: ActiveAgentSession(
                id: "s-100", projectPath: "/p", projectName: "p", branch: "feature/x",
                lastUpdatedAt: now, source: "test"))
        let withTTY = ActiveAgent(
            provider: .claude, pid: 101, parentPID: 1, command: "claude",
            elapsedSeconds: 10, observedAt: now, tty: "ttys002")
        let bare = ActiveAgent(
            provider: .claude, pid: 102, parentPID: 1,
            command: "/Users/me/Library/Application Support/Claude/claude-code/claude",
            elapsedSeconds: 10, observedAt: now)

        XCTAssertEqual(withBranch.inGroupTitle, "feature/x")
        XCTAssertEqual(withTTY.inGroupTitle, "ttys002")
        XCTAssertEqual(bare.inGroupTitle, "PID 102")

        XCTAssertEqual(withTTY.subtitleText, "open now", "provider prefix is implied by the section")
        XCTAssertEqual(bare.subtitleText, "Desktop · open now")
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

    func testIdentifiedClaudeSessionResolvesExactTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-projects-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(root)
        let projectDir = root.appendingPathComponent("-Users-me-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionID = "11111111-2222-3333-4444-555555555555"
        let line = #"{"sessionId":"\#(sessionID)","cwd":"/Users/me/project","gitBranch":"main"}"#
        try line.write(
            to: projectDir.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true, encoding: .utf8
        )

        let session = ActiveAgentService.identifiedClaudeSession(
            sessionID: sessionID,
            cwd: "/Users/me/project",
            observedAt: Date(),
            projectsRoot: root
        )

        XCTAssertEqual(session?.id, sessionID)
        XCTAssertEqual(session?.branch, "main")
        XCTAssertEqual(session?.displayProject, "project")
        XCTAssertEqual(session?.logPath?.hasSuffix("\(sessionID).jsonl"), true)

        XCTAssertNil(ActiveAgentService.identifiedClaudeSession(
            sessionID: "99999999-0000-0000-0000-000000000000",
            cwd: "/Users/me/project",
            observedAt: Date(),
            projectsRoot: root
        ), "a session ID with no transcript on disk must not resolve")
    }

    func testIdentifiedClaudeSessionRejectsPathEscapingSessionID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-projects-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("-Users-me-project", isDirectory: true),
            withIntermediateDirectories: true
        )
        // A real file at the traversal target proves the guard rejects the ID
        // rather than just failing to find a file.
        try #"{"sessionId":"escape"}"#.write(
            to: root.appendingPathComponent("escape.jsonl"),
            atomically: true, encoding: .utf8
        )

        XCTAssertNil(ActiveAgentService.identifiedClaudeSession(
            sessionID: "../escape",
            cwd: "/Users/me/project",
            observedAt: Date(),
            projectsRoot: root
        ))
    }

    func testHookPayloadRequiresCurrentPIDLifetime() {
        let now = Date(timeIntervalSince1970: 10_000)
        let payload = AgentStatusPayload(
            state: .working, sessionID: "s", processAncestry: [100], updatedAt: now)
        let byPID = [100: payload]

        XCTAssertEqual(
            ActiveAgentService.hookPayload(
                for: 100, startedAt: now.addingTimeInterval(-60), payloadsByPID: byPID)?.sessionID,
            "s"
        )
        XCTAssertNil(
            ActiveAgentService.hookPayload(
                for: 100, startedAt: now.addingTimeInterval(60), payloadsByPID: byPID),
            "a payload from before the process started belongs to a recycled PID"
        )
        XCTAssertNil(ActiveAgentService.hookPayload(
            for: 200, startedAt: now, payloadsByPID: byPID))
    }

    func testLatestPayloadsByPIDKeepsNewestPerPID() {
        let now = Date(timeIntervalSince1970: 10_000)
        let payloads = [
            AgentStatusPayload(state: .idle, sessionID: "old",
                               processAncestry: [501, 100], updatedAt: now.addingTimeInterval(-30)),
            AgentStatusPayload(state: .working, sessionID: "new",
                               processAncestry: [502, 100], updatedAt: now),
            AgentStatusPayload(state: .working, sessionID: "unrelated",
                               processAncestry: [900], updatedAt: now),
        ]

        let byPID = ActiveAgentService.latestPayloadsByPID(payloads, agentPIDs: [100])

        XCTAssertEqual(byPID.count, 1)
        XCTAssertEqual(byPID[100]?.sessionID, "new")
    }

    func testParsePSOutputAssociatesIdentifiedCodexSandboxesInSameDirectory() {
        let output = """
          PID  PPID     ELAPSED COMMAND
        10004 99999       00:10 /Applications/ChatGPT.app/Contents/Resources/codex sandbox -c permissions.node_repl={filesystem={"/Users/me/.codex/visualizations/2025/01/01/00000000-0000-7000-8000-000000000001"="write"}}
        10005 99999       00:20 /Applications/ChatGPT.app/Contents/Resources/codex sandbox -c permissions.node_repl={filesystem={"/Users/me/.codex/visualizations/2025/01/01/00000000-0000-7000-8000-000000000002"="write"}}
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 100),
            cwdLookup: { _ in "/Users/me/project" },
            sessionLookup: { _, cwd, startedAt, _ in
                ActiveAgentSession(
                    id: String(Int(startedAt.timeIntervalSince1970)),
                    projectPath: cwd,
                    projectName: "project",
                    branch: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 99),
                    source: "test"
                )
            }
        )

        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(Set(agents.compactMap(\.session?.id)), ["80", "90"])
    }

    func testCodexRolloutIdentifierRequiresOneUniqueVisualizationTask() {
        let identifier = "00000000-0000-7000-8000-000000000001"
        let desktopExecutable = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let visualizationPath = "/Users/me/.codex/visualizations/2025/01/01/\(identifier)"
        let identified = """
        \(desktopExecutable) sandbox -c permissions.node_repl={filesystem={"\(visualizationPath)"="write","\(visualizationPath)/.git"="read"}}
        """
        let ambiguous = identified + " /Users/me/.codex/visualizations/2025/01/01/00000000-0000-7000-8000-000000000002"

        XCTAssertEqual(
            ActiveAgentService.codexRolloutIdentifier(from: identified, executablePath: desktopExecutable),
            identifier
        )
        XCTAssertNil(
            ActiveAgentService.codexRolloutIdentifier(from: ambiguous, executablePath: desktopExecutable)
        )
        XCTAssertNil(
            ActiveAgentService.codexRolloutIdentifier(
                from: "codex sandbox \(identified)",
                executablePath: "/usr/local/bin/codex"
            )
        )
        XCTAssertNil(
            ActiveAgentService.codexRolloutIdentifier(
                from: "\(desktopExecutable) app-server \(visualizationPath)",
                executablePath: desktopExecutable
            )
        )
        XCTAssertNil(
            ActiveAgentService.codexRolloutIdentifier(
                from: "\(desktopExecutable) sandbox --working-dir /Users/me/project",
                executablePath: desktopExecutable
            )
        )
    }

    func testIdentifiedCodexSessionRequiresMatchingRolloutIDAndCWD() throws {
        let identifier = "00000000-0000-7000-8000-000000000001"
        let file = try makeTempFile(
            contents: """
            {"type":"session_meta","payload":{"id":"\(identifier)","cwd":"/Users/me/project"}}
            """,
            filename: "rollout-2026-08-13T00-00-00-\(identifier).jsonl"
        )
        let observedAt = Date().addingTimeInterval(1)

        let session = ActiveAgentService.identifiedCodexSession(
            identifier: identifier,
            cwd: "/Users/me/project",
            observedAt: observedAt,
            rolloutFiles: [file]
        )
        let wrongProject = ActiveAgentService.identifiedCodexSession(
            identifier: identifier,
            cwd: "/Users/me/other",
            observedAt: observedAt,
            rolloutFiles: [file]
        )

        XCTAssertEqual(session?.logPath, file.path)
        XCTAssertEqual(session?.projectName, "project")
        XCTAssertNil(wrongProject)

        try FileManager.default.setAttributes(
            [.modificationDate: observedAt.addingTimeInterval(3_600)],
            ofItemAtPath: file.path
        )
        let refreshedFileURL = URL(fileURLWithPath: file.path)
        XCTAssertNil(
            ActiveAgentService.identifiedCodexSession(
                identifier: identifier,
                cwd: "/Users/me/project",
                observedAt: observedAt,
                rolloutFiles: [refreshedFileURL]
            )
        )
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

    private func makeTempFile(contents: String, filename: String = "session.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMeterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let file = dir.appendingPathComponent(filename)
        try contents.data(using: .utf8)?.write(to: file)
        return file
    }
}
