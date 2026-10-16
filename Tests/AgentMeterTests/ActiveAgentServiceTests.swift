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

    /// Builds the production session-resolution strategy with injectable leaf
    /// lookups, so tests exercise the same hook-beats-heuristic precedence and
    /// sole-agent guard the app ships with.
    private func resolver(
        payloadsByPID: [Int: AgentStatusPayload] = [:],
        identified: @escaping (String, String, Date) -> ActiveAgentSession? = { _, _, _ in nil },
        _ heuristic: @escaping (Provider, String, Date, Date) -> ActiveAgentSession?
    ) -> (ActiveAgentService.SessionQuery) -> ActiveAgentSession? {
        ActiveAgentService.sessionResolver(
            payloadsByPID: payloadsByPID,
            identified: identified,
            heuristic: { query, cwd in heuristic(query.provider, cwd, query.startedAt, query.observedAt) }
        )
    }

    func testSessionResolverPrefersHookPinnedTranscriptOverHeuristic() {
        let now = Date(timeIntervalSince1970: 10_000)
        let output = """
          PID  PPID     ELAPSED COMMAND
        10004 99999       00:10 claude --resume
        10005 99999       00:20 claude --resume
        """
        let payload = AgentStatusPayload(
            state: .working, sessionID: "hook-session", processAncestry: [10004], updatedAt: now)
        let hooked = ActiveAgentSession(
            id: "hook-session", projectPath: "/Users/me/project", projectName: "project",
            branch: nil, lastUpdatedAt: now, source: "test")

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: now,
            cwdLookup: { _ in "/Users/me/project" },
            resolveSession: resolver(
                payloadsByPID: [10004: payload],
                identified: { sessionID, cwd, _ in
                    XCTAssertEqual(sessionID, "hook-session")
                    XCTAssertEqual(cwd, "/Users/me/project")
                    return hooked
                }
            ) { _, _, _, _ in
                XCTFail("hook-pinned or ambiguous processes must not reach the heuristic")
                return nil
            }
        )

        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(agents.first { $0.pid == 10004 }?.session?.id, "hook-session")
        XCTAssertNil(agents.first { $0.pid == 10005 }?.session,
                     "the unhooked twin in the same directory stays unattributed")
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
            resolveSession: resolver { _, _, _, _ in nil }
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
            resolveSession: resolver { _, _, _, _ in nil }
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

    func testAttachStatusCarriesThePendingBackgroundTaskCounts() {
        // A `Stop` that found tasks still running writes `working` plus the
        // counts; the row needs both to explain why a quiet session is green.
        let now = Date(timeIntervalSince1970: 100)
        let agent = ActiveAgent(provider: .claude, pid: 100, parentPID: 1, command: "claude",
                                elapsedSeconds: 20, observedAt: now, cwd: "/tmp/project")
        let paused = AgentStatusPayload(state: .working, sessionID: "a", processAncestry: [501, 100, 1],
                                        pendingBackgroundTasks: 2, pendingSubagents: 1, updatedAt: now)

        let attached = ActiveAgentService.attachStatus([agent], payloads: [paused]).first

        XCTAssertEqual(attached?.status, .working)
        XCTAssertEqual(attached?.pendingBackgroundTasks, 2)
        XCTAssertEqual(attached?.pendingSubagents, 1)
        XCTAssertEqual(attached?.activityText, "working · 2 background tasks")
    }

    func testAttachStatusCarriesWhenTheHookWroteTheState() {
        // The Chronicle case: the main turn hit a 429 four days ago and nobody
        // went back to the tab, which stayed open the whole time.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let agent = ActiveAgent(provider: .claude, pid: 100, parentPID: 1, command: "claude",
                                elapsedSeconds: 5 * 86_400, observedAt: now, cwd: "/tmp/project")
        let failed = AgentStatusPayload(state: .error, sessionID: "a", message: "429 rate_limit_error",
                                        processAncestry: [501, 100, 1],
                                        updatedAt: now.addingTimeInterval(-4 * 86_400))

        let attached = ActiveAgentService.attachStatus([agent], payloads: [failed]).first

        XCTAssertEqual(attached?.status, .error)
        XCTAssertEqual(attached?.statusUpdatedAt, failed.updatedAt)
        XCTAssertEqual(attached?.displayStatus, .idle)
        XCTAssertEqual(attached?.activityText, "last turn failed · 4d ago")
    }

    func testAFailedTurnNeedsAttentionForTwelveHoursThenGoesGray() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func agent(failedAgo age: TimeInterval?) -> ActiveAgent {
            ActiveAgent(provider: .claude, pid: 100, parentPID: 1, command: "claude",
                        elapsedSeconds: 10, observedAt: now, status: .error,
                        statusUpdatedAt: age.map { now.addingTimeInterval(-$0) })
        }

        let fresh = agent(failedAgo: 3_600)
        XCTAssertEqual(fresh.displayStatus, .error)
        XCTAssertEqual(fresh.activityText, "needs attention")
        XCTAssertEqual(agent(failedAgo: ActiveAgent.errorAttentionWindow).displayStatus, .error)

        let stale = agent(failedAgo: ActiveAgent.errorAttentionWindow + 1)
        XCTAssertEqual(stale.displayStatus, .idle)
        XCTAssertEqual(stale.activityText, "last turn failed · 12h ago")
        XCTAssertEqual(ActiveAgentTooltip.text(for: stale).split(separator: "\n").first,
                       "Last turn failed, click to jump to this session")

        // A state built without a write time keeps its color.
        XCTAssertEqual(agent(failedAgo: nil).displayStatus, .error)
        XCTAssertEqual(agent(failedAgo: nil).activityText, "needs attention")
    }

    func testStatusPayloadFromOlderPIDLifetimeIsIgnored() {
        let now = Date(timeIntervalSince1970: 10_000)
        // The process resolved to the very session the stale payload names (a
        // `--resume` of it): the id match must not bring back what the PID
        // guard refused.
        let agent = ActiveAgent(
            provider: .claude,
            pid: 100,
            parentPID: 1,
            command: "claude",
            elapsedSeconds: 10,
            observedAt: now,
            cwd: "/tmp/p",
            session: ActiveAgentSession(
                id: "old", projectPath: "/tmp/p", projectName: "p", branch: nil, lastUpdatedAt: now, source: "test")
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
            resolveSession: resolver { _, _, _, _ in nil }
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
            resolveSession: resolver { provider, cwd, _, _ in
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
            resolveSession: resolver { _, _, _, _ in nil }
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
            resolveSession: resolver { _, _, _, _ in nil }
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
            resolveSession: resolver { provider, cwd, startedAt, _ in
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

    func testActivityTextNamesTheBackgroundWorkAStoppedTurnLeftRunning() {
        // `Stop` fired with subagents still in flight: the hook kept the row
        // `working` and recorded how many tasks it was waiting on. Subagents
        // are named as such only when they are all of it.
        let now = Date(timeIntervalSince1970: 10_000)
        func agent(_ status: AgentStatusState?, pending: Int? = nil, subagents: Int? = nil) -> ActiveAgent {
            ActiveAgent(provider: .claude, pid: 100, parentPID: 1, command: "claude",
                        elapsedSeconds: 10, observedAt: now, status: status,
                        pendingBackgroundTasks: pending, pendingSubagents: subagents)
        }

        XCTAssertEqual(agent(.working, pending: 1, subagents: 1).activityText, "working · 1 subagent")
        XCTAssertEqual(agent(.working, pending: 2, subagents: 2).activityText, "working · 2 subagents")
        XCTAssertEqual(agent(.working, pending: 1, subagents: 0).activityText, "working · 1 background task")
        XCTAssertEqual(agent(.working, pending: 2, subagents: 1).activityText, "working · 2 background tasks")
        XCTAssertEqual(agent(.working, pending: 0, subagents: 0).activityText, "working now")
        XCTAssertEqual(agent(.working).activityText, "working now", "PreToolUse carries no count")
        // The registry reads a turn that ended with subagents in flight as
        // idle; the count from the `Stop` then takes the age's place.
        XCTAssertEqual(agent(.idle, pending: 1, subagents: 1).activityText, "idle · 1 subagent")
        XCTAssertEqual(agent(.idle, pending: 0, subagents: 0).activityText, "idle")
        XCTAssertEqual(agent(.waiting, pending: 1, subagents: 1).activityText, "waiting for input")
    }

    func testBlankRowsCarryNeitherHookStateNorTranscript() {
        let now = Date(timeIntervalSince1970: 10_000)
        let bare = ActiveAgent(
            provider: .claude, pid: 100, parentPID: 1, command: "claude", elapsedSeconds: 10, observedAt: now,
            cwd: "/Users/me/project")
        var stateOnly = bare
        stateOnly.status = .working
        var transcriptOnly = bare
        transcriptOnly.session = ActiveAgentSession(
            id: "s-100", projectPath: "/Users/me/project", projectName: "project", branch: nil,
            lastUpdatedAt: nil, source: "test")

        // A PID with a cwd is still only a PID: nothing to say beyond "open now".
        XCTAssertTrue(bare.isBlank)
        XCTAssertEqual(bare.activityText, "open now")
        // Either signal alone earns the row: live state says what it is doing,
        // a transcript says what it is and what it has spent.
        XCTAssertFalse(stateOnly.isBlank)
        XCTAssertFalse(transcriptOnly.isBlank)
    }

    func testPresentableDropsBarePIDsAfterAttachingHookState() {
        // The tail of `fetch()`: a hook payload turns a bare PID into a row
        // with state; a bare PID without one is dropped; a transcript-only
        // row stays.
        let now = Date(timeIntervalSince1970: 10_000)
        func bare(_ pid: Int) -> ActiveAgent {
            ActiveAgent(provider: .claude, pid: pid, parentPID: 1, command: "claude",
                        elapsedSeconds: 10, observedAt: now, cwd: "/Users/me/project")
        }
        var transcriptOnly = bare(102)
        transcriptOnly.session = ActiveAgentSession(
            id: "s-102", projectPath: "/Users/me/project", projectName: "project", branch: nil,
            lastUpdatedAt: nil, source: "test")
        let hooked = AgentStatusPayload(state: .working, sessionID: "s-101", processAncestry: [601, 101, 1], updatedAt: now)

        let rows = ActiveAgentService.presentable([bare(100), bare(101), transcriptOnly], payloads: [hooked])

        XCTAssertEqual(rows.map(\.pid), [101, 102])
        XCTAssertEqual(rows.first?.status, .working)
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

        var titled = withBranch
        titled.session?.title = "Fix the flaky login test"

        XCTAssertEqual(withBranch.inGroupTitle, "feature/x")
        XCTAssertEqual(withTTY.inGroupTitle, "ttys002")
        XCTAssertEqual(bare.inGroupTitle, "PID 102")
        XCTAssertEqual(titled.inGroupTitle, "Fix the flaky login test", "a title says which conversation this is")

        // Beside a project name the same slot shows the title, else the branch.
        XCTAssertEqual(titled.titleDetail, "Fix the flaky login test")
        XCTAssertEqual(withBranch.titleDetail, "feature/x")
        XCTAssertNil(withTTY.titleDetail)

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
            resolveSession: resolver { _, _, _, _ in
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

    func testIdentifiedClaudeSessionRejectsRelativeOrEscapingCWD() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-base-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(base)
        let root = base.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionID = "11111111-2222-3333-4444-555555555555"
        // A real transcript one level above the projects root proves the guard
        // rejects the cwd rather than just failing to find a file: a cwd of
        // ".." maps to a ".." path component that would resolve to this file.
        try #"{"sessionId":"\#(sessionID)"}"#.write(
            to: base.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true, encoding: .utf8
        )

        for cwd in ["..", ".", "relative/path", ""] {
            XCTAssertNil(ActiveAgentService.identifiedClaudeSession(
                sessionID: sessionID,
                cwd: cwd,
                observedAt: Date(),
                projectsRoot: root
            ), "non-absolute cwd \(cwd.debugDescription) must be refused")
        }
    }

    func testIdentifiedClaudeSessionFollowsASymlinkedProjectStore() throws {
        // Claude Code's SessionStart hook symlinks projects/<key> into a shared
        // store, so the resolved transcript legitimately sits outside
        // projects/. Refusing that (an earlier containment check on the
        // *resolved* path did) loses the pinned transcript for every session on
        // such a machine — and with it the row's model, tokens, cost and
        // branch. Traversal is still blocked, on the constructed path: see
        // testIdentifiedClaudeSessionRejectsPathEscapingSessionID and
        // testIdentifiedClaudeSessionRejectsRelativeOrEscapingCWD.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-base-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(base)
        let root = base.appendingPathComponent("projects", isDirectory: true)
        let store = base.appendingPathComponent("projects-store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let sessionID = "11111111-2222-3333-4444-555555555555"
        try #"{"sessionId":"\#(sessionID)","cwd":"/Users/me/project","gitBranch":"main"}"#.write(
            to: store.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("-Users-me-project", isDirectory: true),
            withDestinationURL: store
        )

        let session = ActiveAgentService.identifiedClaudeSession(
            sessionID: sessionID,
            cwd: "/Users/me/project",
            observedAt: Date(),
            projectsRoot: root
        )

        XCTAssertEqual(session?.id, sessionID)
        XCTAssertEqual(session?.branch, "main")
        XCTAssertEqual(session?.logPath?.hasSuffix("\(sessionID).jsonl"), true)
    }

    func testSessionResolverTriesTheProcessCWDWhenTheHookCWDMissesTheProjectKey() {
        let now = Date(timeIntervalSince1970: 10_000)
        // Claude Code keys the transcript directory by the directory the
        // session was launched from; the hook reports the session's current
        // cwd. After an /add-dir or a cd they differ, and the hook cwd alone
        // derives a project key no directory has.
        let payload = AgentStatusPayload(
            state: .working, sessionID: "hook-session",
            cwd: "/Users/me/project/sub/dir",
            processAncestry: [4_242], updatedAt: now)
        let found = ActiveAgentSession(
            id: "hook-session", projectPath: "/Users/me/project", projectName: "project",
            branch: nil, lastUpdatedAt: now, source: "test")
        var tried: [String] = []
        let resolve = ActiveAgentService.sessionResolver(
            payloadsByPID: [4_242: payload],
            identified: { _, cwd, _ in
                tried.append(cwd)
                return cwd == "/Users/me/project" ? found : nil
            },
            heuristic: { _, _ in nil })

        let session = resolve(ActiveAgentService.SessionQuery(
            provider: .claude, pid: 4_242, cwd: "/Users/me/project",
            startedAt: now.addingTimeInterval(-60), observedAt: now,
            codexRolloutIdentifier: nil, isSoleAgentForCWD: false))

        XCTAssertEqual(session?.id, "hook-session")
        XCTAssertEqual(tried, ["/Users/me/project/sub/dir", "/Users/me/project"],
                       "the hook cwd is the stronger signal and must be tried first")
    }

    func testSessionResolverDoesNotProbeTheSameCWDTwice() {
        let now = Date(timeIntervalSince1970: 10_000)
        let payload = AgentStatusPayload(
            state: .working, sessionID: "hook-session",
            cwd: "/Users/me/project",
            processAncestry: [4_243], updatedAt: now)
        var tried: [String] = []
        let resolve = ActiveAgentService.sessionResolver(
            payloadsByPID: [4_243: payload],
            identified: { _, cwd, _ in tried.append(cwd); return nil },
            heuristic: { _, _ in nil })

        _ = resolve(ActiveAgentService.SessionQuery(
            provider: .claude, pid: 4_243, cwd: "/Users/me/project",
            startedAt: now.addingTimeInterval(-60), observedAt: now,
            codexRolloutIdentifier: nil, isSoleAgentForCWD: false))

        XCTAssertEqual(tried, ["/Users/me/project"])
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
            resolveSession: resolver { _, cwd, startedAt, _ in
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

    func testModelLabelReshapesAnthropicIdsAndLeavesEverythingElseAlone() {
        XCTAssertEqual(ModelLabel.short("claude-opus-4-1-20250805"), "opus 4.1")
        XCTAssertEqual(ModelLabel.short("claude-sonnet-4-5-20250929"), "sonnet 4.5")
        XCTAssertEqual(ModelLabel.short("claude-opus-5"), "opus 5")
        XCTAssertEqual(ModelLabel.short("claude-fable-5-1"), "fable 5.1")
        XCTAssertEqual(ModelLabel.short("  claude-opus-5  "), "opus 5")

        // Ids outside that shape keep their own spelling; only the snapshot
        // date goes, because the row has no room for it.
        XCTAssertEqual(ModelLabel.short("gpt-5-codex"), "gpt-5-codex")
        XCTAssertEqual(ModelLabel.short("o3"), "o3")
        XCTAssertEqual(ModelLabel.short("claude-3-5-haiku-20241022"), "3-5-haiku")
        XCTAssertEqual(ModelLabel.short("some-model-nobody-shipped"), "some-model-nobody-shipped")

        // Placeholders are not model names; a row must not print one as if a
        // provider had reported it.
        XCTAssertNil(ModelLabel.short("default"))
        XCTAssertNil(ModelLabel.short("<synthetic>"))
        XCTAssertNil(ModelLabel.short("claude-"))
        XCTAssertNil(ModelLabel.short("   "))
        XCTAssertNil(ModelLabel.short(nil))
    }

    func testSubtitleNamesTheModelTheSessionIsRunning() {
        let now = Date(timeIntervalSince1970: 10_000)
        func agent(command: String, model: String?) -> ActiveAgent {
            ActiveAgent(
                provider: .claude, pid: 200, parentPID: 1, command: command,
                elapsedSeconds: 10, observedAt: now, tty: "ttys001",
                session: ActiveAgentSession(
                    id: "s-200", projectPath: "/p", projectName: "p", branch: nil,
                    lastUpdatedAt: now, source: "test", model: model))
        }
        let desktop = "/Users/me/Library/Application Support/Claude/claude-code/claude"

        XCTAssertEqual(
            agent(command: "claude", model: "claude-opus-4-1-20250805").subtitleText,
            "opus 4.1 · active now"
        )
        XCTAssertEqual(
            agent(command: desktop, model: "claude-opus-4-1-20250805").subtitleText,
            "Desktop · opus 4.1 · active now"
        )
        // No model parsed yet (a session that has spent nothing): unchanged.
        XCTAssertEqual(agent(command: "claude", model: nil).subtitleText, "active now")
        XCTAssertEqual(agent(command: "claude", model: "default").subtitleText, "active now")
    }

    func testClaudeSessionUsageSummaryReportsTheModelBehindTheNewestTokens() async throws {
        let file = try makeTempFile(contents: """
        {"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":100,"output_tokens":50}}}
        {"timestamp":"2026-07-05T00:01:00Z","requestId":"r2","message":{"id":"m2","model":"claude-opus-4-1-20250805","usage":{"input_tokens":20,"output_tokens":10}}}
        """)

        let summary = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        // A session that switched models mid-run reports the one now spending.
        XCTAssertEqual(summary?.model, "claude-opus-4-1-20250805")
        XCTAssertEqual(ModelLabel.short(summary?.model), "opus 4.1")
    }

    func testSubtitleAppendsTheEffortAfterTheModel() {
        let now = Date(timeIntervalSince1970: 10_000)
        func agent(model: String?, effort: String?) -> ActiveAgent {
            ActiveAgent(
                provider: .claude, pid: 201, parentPID: 1, command: "claude",
                elapsedSeconds: 10, observedAt: now, tty: "ttys001",
                session: ActiveAgentSession(
                    id: "s-201", projectPath: "/p", projectName: "p", branch: nil,
                    lastUpdatedAt: now, source: "test", model: model, effort: effort))
        }

        XCTAssertEqual(agent(model: "claude-fable-5-1", effort: "xhigh").subtitleText, "fable 5.1 · xhigh · active now")
        // No effort recorded (an older transcript, or Codex): unchanged.
        XCTAssertEqual(agent(model: "claude-fable-5-1", effort: nil).subtitleText, "fable 5.1 · active now")
        // Effort without a readable model still shows; the two are independent.
        XCTAssertEqual(agent(model: "default", effort: "max").subtitleText, "max · active now")
        XCTAssertEqual(agent(model: nil, effort: "  ").subtitleText, "active now")
    }

    func testSessionLabelFlattensAndCapsUntrustedText() {
        XCTAssertEqual(SessionLabel.title("  Fix  login\n\tflow  "), "Fix login flow")
        XCTAssertEqual(SessionLabel.title("a\u{7}b\u{1B}[31mc"), "ab[31mc", "control characters are dropped, not rendered")
        XCTAssertEqual(SessionLabel.title(String(repeating: "x", count: 200))?.count, 80)
        XCTAssertNil(SessionLabel.title(""))
        XCTAssertNil(SessionLabel.title("\n \t"))
        XCTAssertNil(SessionLabel.title(nil))

        XCTAssertEqual(SessionLabel.effort("xhigh"), "xhigh")
        XCTAssertEqual(SessionLabel.effort(String(repeating: "m", count: 40))?.count, 16)
        XCTAssertNil(SessionLabel.effort(" "))

        // One base letter under a hundred thousand combining marks is a single
        // Character; a character-only cap would pass all of it to the row.
        let stacked = "a" + String(repeating: "\u{0301}", count: 100_000)
        let bounded = SessionLabel.title(stacked)
        XCTAssertEqual(bounded?.count, 1)
        XCTAssertLessThanOrEqual(bounded?.unicodeScalars.count ?? .max, 80 * 4)
        // Ordinary text is untouched: 80 CJK characters, a plain emoji. (A ZWJ
        // emoji sequence does fall apart into its members: U+200D is a format
        // character, the class the bidi overrides live in, and it is dropped
        // with them rather than special-cased.)
        XCTAssertEqual(SessionLabel.title(String(repeating: "用", count: 80))?.count, 80)
        XCTAssertEqual(SessionLabel.title("🐛 review"), "🐛 review")
    }

    func testDisplayBranchIsSanitizedAndDropsDetachedHead() {
        func session(branch: String?) -> ActiveAgentSession {
            ActiveAgentSession(id: "s", projectPath: "/p", projectName: "p", branch: branch,
                               lastUpdatedAt: nil, source: "test")
        }
        XCTAssertEqual(session(branch: "feature/x").displayBranch, "feature/x")
        XCTAssertNil(session(branch: "HEAD").displayBranch)
        XCTAssertNil(session(branch: "").displayBranch)
        XCTAssertNil(session(branch: nil).displayBranch)
        // `gitBranch` is copied from the transcript, so it is provider text too.
        XCTAssertEqual(session(branch: "fix\u{1B}[31m\nlogin").displayBranch, "fix[31m login")
    }

    func testTitleInTheResumedTailAndAsATrailingRecordReachesTheSummary() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let head = """
        {"type":"ai-title","sessionId":"s","aiTitle":"Generated"}
        {"requestId":"r1","message":{"id":"m1","model":"claude-fable-5-1","usage":{"input_tokens":10,"output_tokens":5}}}

        """
        let file = try makeTempFile(contents: head, filename: "growing.jsonl")
        let generated = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)
        XCTAssertEqual(generated?.title, "Generated")

        // The user renames the session; the record is still being written
        // (no newline yet). It shows now, from the trailing-line fold.
        try append(#"{"type":"custom-title","sessionId":"s","customTitle":"Renamed"}"#, to: file)
        let torn = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)
        XCTAssertEqual(torn?.title, "Renamed")

        // Completed, then a later generated title must not displace it, and
        // the tokens after the resume point are counted exactly once.
        try append("""

        {"type":"ai-title","sessionId":"s","aiTitle":"Generated again"}
        {"requestId":"r2","message":{"id":"m2","model":"claude-fable-5-1","usage":{"input_tokens":20,"output_tokens":10}}}

        """, to: file)
        let resumed = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)
        XCTAssertEqual(resumed?.title, "Renamed")
        XCTAssertEqual(resumed?.tokenCount, 45)
    }

    func testClaudeSessionUsageSummaryCarriesATitleBeforeTheFirstCountedRecord() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        // A session renamed before its first reply has an identity but no spend.
        let file = try makeTempFile(contents: """
        {"type":"custom-title","sessionId":"s","customTitle":"Named first"}
        {"type":"user","sessionId":"s","message":{"role":"user","content":"hi"}}
        """)

        let summary = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        XCTAssertEqual(summary?.title, "Named first")
        XCTAssertNil(summary?.tokenCount, "spend is nil until a record is counted, not zero and not a missing summary")
        XCTAssertNil(summary?.estimatedCostUSD)
        XCTAssertNil(summary?.model)
    }

    func testClaudeSessionUsageSummaryReportsEffortAndTitle() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        // Effort sits at the record's top level, beside `type`, not inside
        // `message`. The generated title lands *after* the custom one here, as
        // Claude Code writes them, and must not displace it.
        let file = try makeTempFile(contents: """
        {"type":"assistant","effort":"high","requestId":"r1","message":{"id":"m1","model":"claude-fable-5-1","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"custom-title","sessionId":"s","customTitle":"bu g"}
        {"type":"ai-title","sessionId":"s","aiTitle":"Agentmeter 用量速度指标"}
        {"type":"assistant","effort":"xhigh","perTurnEffort":"xhigh","requestId":"r2","message":{"id":"m2","model":"claude-fable-5-1","usage":{"input_tokens":20,"output_tokens":10}}}
        """)

        let summary = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        XCTAssertEqual(summary?.effort, "xhigh", "effort follows the newest counted record")
        XCTAssertEqual(summary?.title, "bu g", "a user-set title outranks a generated one whatever the order")
    }

    func testClaudeSessionUsageSummaryFallsBackToTheGeneratedTitleWhenTheCustomOneIsCleared() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let file = try makeTempFile(contents: """
        {"type":"ai-title","sessionId":"s","aiTitle":"First title"}
        {"type":"custom-title","sessionId":"s","customTitle":"Mine"}
        {"type":"custom-title","sessionId":"s","customTitle":""}
        {"type":"ai-title","sessionId":"s","aiTitle":"Second title"}
        {"type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-fable-5-1","usage":{"input_tokens":1,"output_tokens":1}}}
        """)

        let summary = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        XCTAssertEqual(summary?.title, "Second title")
        XCTAssertNil(summary?.effort, "a record without the key reports none rather than a stale value")
    }

    func testCodexSessionUsageSummaryCarriesNeitherEffortNorTitle() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        // A rollout's only effort field is `reasoning_effort`, nested under
        // turn_context and null in practice; titles live outside the rollout.
        let file = try makeTempFile(contents: """
        {"type":"turn_context","payload":{"type":"turn_context","model":"gpt-5","collaboration_mode":{"settings":{"reasoning_effort":null}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}
        """)

        let summary = await ActiveAgentService.sessionUsageSummary(provider: .codex, url: file)

        XCTAssertEqual(summary?.model, "gpt-5")
        XCTAssertNil(summary?.effort)
        XCTAssertNil(summary?.title)
    }

    func testCodexSessionUsageSummaryIgnoresATurnContextThatSpentNothing() async throws {
        let file = try makeTempFile(contents: """
        {"timestamp":"2026-07-05T00:00:00Z","payload":{"type":"turn_context","model":"gpt-5-codex"}}
        {"timestamp":"2026-07-05T00:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20}}}}
        {"timestamp":"2026-07-05T00:02:00Z","payload":{"type":"turn_context","model":"gpt-5"}}
        {"timestamp":"2026-07-05T00:03:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}
        {"timestamp":"2026-07-05T00:04:00Z","payload":{"type":"turn_context","model":"o3"}}
        """)

        let summary = await ActiveAgentService.sessionUsageSummary(provider: .codex, url: file)

        // The trailing turn_context named o3 but spent nothing under it, so the
        // row must not claim the session is running o3.
        XCTAssertEqual(summary?.model, "gpt-5")
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

    /// An actively-appended transcript resumes at the last line boundary rather
    /// than being re-read whole, so the resumed parse has to land on exactly what
    /// a cold parse of the final file gives: same dedup across the resume point,
    /// same carried-over model.
    func testClaudeIncrementalParseMatchesColdParseAndKeepsDedup() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let head = """
        {"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"ai-title","sessionId":"s","aiTitle":"Titled before the resume"}
        {"timestamp":"2026-07-05T00:01:00Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-4","usage":{"input_tokens":20,"output_tokens":10}}}

        """
        // Replays m1 (already counted before the resume) plus one new message.
        let tail = """
        {"timestamp":"2026-07-05T00:02:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":999,"output_tokens":999}}}
        {"timestamp":"2026-07-05T00:03:00Z","requestId":"r3","message":{"id":"m3","model":"claude-sonnet-4","usage":{"input_tokens":7,"output_tokens":3}}}

        """
        let growing = try makeTempFile(contents: head, filename: "growing.jsonl")
        _ = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: growing)
        try append(tail, to: growing)
        let resumed = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: growing)

        let cold = try makeTempFile(contents: head + tail, filename: "cold.jsonl")
        let expected = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: cold)

        XCTAssertEqual(resumed?.tokenCount, 190, "the replayed m1 must not be counted twice")
        XCTAssertEqual(resumed?.tokenCount, expected?.tokenCount)
        XCTAssertEqual(resumed?.estimatedCostUSD ?? 0, expected?.estimatedCostUSD ?? -1, accuracy: 0.000_001)
        XCTAssertEqual(resumed?.title, "Titled before the resume", "the title is part of the cached partial state")
        XCTAssertEqual(resumed?.title, expected?.title)
    }

    /// Codex names the model once in a turn_context line and then emits bare
    /// token_count events. A resume that starts after that line has to remember
    /// it, or the tail gets priced as the default model.
    func testCodexIncrementalParseCarriesTheModelAcrossTheResume() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let head = """
        {"timestamp":"2026-07-05T00:00:00Z","payload":{"type":"turn_context","model":"gpt-5"}}
        {"timestamp":"2026-07-05T00:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}}}

        """
        let tail = """
        {"timestamp":"2026-07-05T00:02:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}

        """
        let growing = try makeTempFile(contents: head, filename: "codex-growing.jsonl")
        _ = await ActiveAgentService.sessionUsageSummary(provider: .codex, url: growing)
        try append(tail, to: growing)
        let resumed = await ActiveAgentService.sessionUsageSummary(provider: .codex, url: growing)

        let cold = try makeTempFile(contents: head + tail, filename: "codex-cold.jsonl")
        let expected = await ActiveAgentService.sessionUsageSummary(provider: .codex, url: cold)

        XCTAssertEqual(resumed?.tokenCount, 135)
        XCTAssertEqual(resumed?.estimatedCostUSD ?? 0, expected?.estimatedCostUSD ?? -1, accuracy: 0.000_001,
                       "the tail must still be priced as gpt-5, not the default model")
    }

    /// A refresh can land mid-write. The unterminated record is shown now but
    /// must not be cached, or completing it on the next pass counts it twice.
    func testTrailingPartialRecordIsShownOnceAndNotDoubleCountedWhenCompleted() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let complete = #"{"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}"#
        let partial = #"{"timestamp":"2026-07-05T00:01:00Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-4","usage":{"input_tokens":20,"output_tokens":10}}}"#
        let file = try makeTempFile(contents: complete + "\n" + partial, filename: "torn.jsonl")

        let torn = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)
        try append("\n", to: file)
        let completed = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        XCTAssertEqual(torn?.tokenCount, 180, "the unterminated record still shows in the live total")
        XCTAssertEqual(completed?.tokenCount, 180, "and must not be counted again once terminated")
    }

    /// A rotated or rewritten transcript keeps its path but is a different file,
    /// so resuming from the old offset would read someone else's bytes.
    func testTruncatedLogIsReparsedFromTheTop() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let long = """
        {"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}
        {"timestamp":"2026-07-05T00:01:00Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-4","usage":{"input_tokens":200,"output_tokens":100}}}

        """
        let file = try makeTempFile(contents: long, filename: "rotated.jsonl")
        let before = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        try """
        {"timestamp":"2026-07-06T00:00:00Z","requestId":"r9","message":{"id":"m9","model":"claude-sonnet-4","usage":{"input_tokens":5,"output_tokens":5}}}

        """.data(using: .utf8)?.write(to: file)
        let after = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        XCTAssertEqual(before?.tokenCount, 450)
        XCTAssertEqual(after?.tokenCount, 10, "a shrunk file must be re-read from the top")
    }

    /// Proves the prefix is genuinely not re-read: after the first parse, the
    /// already-consumed bytes are overwritten in place with a record carrying no
    /// usage at all. A resume still reports the original tokens; a re-read from
    /// the top would lose them.
    func testGrownLogDoesNotRereadTheAlreadyConsumedPrefix() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let first = #"{"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}"#
        let file = try makeTempFile(contents: first + "\n", filename: "prefix.jsonl")

        let before = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)
        XCTAssertEqual(before?.tokenCount, 150)

        // Same byte length, no usage block — only a re-read would ever see this.
        let blank = #"{"note":"overwritten"}"#
        let scrubbed = blank + String(repeating: " ", count: first.utf8.count - blank.utf8.count)
        XCTAssertEqual(scrubbed.utf8.count, first.utf8.count)
        let handle = try FileHandle(forUpdating: file)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(scrubbed.utf8))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"timestamp":"2026-07-05T00:01:00Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-4","usage":{"input_tokens":20,"output_tokens":10}}}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        let after = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: file)

        XCTAssertEqual(after?.tokenCount, 180,
                       "150 carried from the cached prefix + 30 newly appended")
    }

    // MARK: - Subagent transcripts

    func testSessionUsageAddsSubagentTranscriptsAndKeepsIdentityFromTheMainOne() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let main = try makeTempFile(contents: """
        {"type":"ai-title","sessionId":"s1","aiTitle":"Parent work"}
        {"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","effort":"high","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}
        """, filename: "s1.jsonl")
        let subagent = try writeSubagent(
            id: "a1", beside: main,
            meta: #"{"agentType":"Explore","description":"Find the leak","toolUseId":"toolu_1","spawnDepth":1}"#,
            transcript: """
            {"type":"user","isSidechain":true,"agentId":"a1","sessionId":"s1","message":{"role":"user","content":"Find the leak in the parser, read-only."}}
            {"timestamp":"2026-07-05T00:01:00Z","requestId":"r9","effort":"low","isSidechain":true,"agentId":"a1","message":{"id":"m9","model":"claude-haiku-4","usage":{"input_tokens":20,"output_tokens":10}}}
            """
        )
        // Neighbours that are not subagent transcripts.
        let directory = subagent.deletingLastPathComponent()
        try "{}".data(using: .utf8)?.write(to: directory.appendingPathComponent("notes.jsonl"))
        try "{}".data(using: .utf8)?.write(to: directory.appendingPathComponent("agent-b2.meta.json"))

        let enriched = await ActiveAgentService.enrichSessionUsage([claudeAgent(logPath: main.path)])
        let session = try XCTUnwrap(enriched.first?.session)

        // Identity is the main transcript's; spend is both.
        XCTAssertEqual(session.title, "Parent work")
        XCTAssertEqual(session.model, "claude-sonnet-4")
        XCTAssertEqual(session.effort, "high")
        XCTAssertEqual(session.tokenCount, 180)
        let mainAlone = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: main)
        let subagentAlone = await ActiveAgentService.sessionUsageSummary(provider: .claude, url: subagent)
        XCTAssertEqual(
            session.estimatedCostUSD ?? 0,
            (mainAlone?.estimatedCostUSD ?? 0) + (subagentAlone?.estimatedCostUSD ?? 0),
            accuracy: 1e-9
        )

        XCTAssertEqual(session.subagents.map(\.id), ["a1"])
        let child = try XCTUnwrap(session.subagents.first)
        XCTAssertEqual(child.description, "Find the leak")
        XCTAssertEqual(child.agentType, "Explore")
        XCTAssertEqual(child.model, "claude-haiku-4")
        XCTAssertEqual(child.effort, "low")
        XCTAssertEqual(child.tokenCount, 30)
        XCTAssertEqual(child.logPath, subagent.path)
        XCTAssertTrue(child.isWorking, "a transcript written moments ago is in flight")
        XCTAssertEqual(child.subtitleText, "haiku 4 · low · working now")
    }

    func testGrowingSubagentTranscriptResumesAndKeepsItsOwnDedup() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let main = try makeTempFile(contents: """
        {"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}

        """, filename: "s2.jsonl")
        let subagent = try writeSubagent(id: "a1", beside: main, meta: nil, transcript: """
        {"timestamp":"2026-07-05T00:01:00Z","requestId":"r9","message":{"id":"m9","model":"claude-haiku-4","usage":{"input_tokens":20,"output_tokens":10}}}

        """)
        let agent = claudeAgent(logPath: main.path)

        let first = await ActiveAgentService.enrichSessionUsage([agent])
        XCTAssertEqual(first.first?.session?.tokenCount, 180)

        // The subagent replays m9 (already counted) and adds one message; the
        // main transcript is untouched.
        try append("""
        {"timestamp":"2026-07-05T00:02:00Z","requestId":"r9","message":{"id":"m9","model":"claude-haiku-4","usage":{"input_tokens":999,"output_tokens":999}}}
        {"timestamp":"2026-07-05T00:03:00Z","requestId":"r10","message":{"id":"m10","model":"claude-haiku-4","usage":{"input_tokens":10,"output_tokens":5}}}

        """, to: subagent)
        let second = await ActiveAgentService.enrichSessionUsage([agent])

        XCTAssertEqual(second.first?.session?.tokenCount, 195)
        XCTAssertEqual(second.first?.session?.subagents.first?.tokenCount, 45)
    }

    func testSubagentTranscriptsAcceptOnlyAgentFilesBesideTheMainTranscript() throws {
        let main = try makeTempFile(contents: "", filename: "s3.jsonl")
        XCTAssertEqual(ActiveAgentService.subagentTranscripts(for: main.path, provider: .claude), [],
                       "a session that spawned nothing has no directory")

        _ = try writeSubagent(id: "b2", beside: main, meta: nil, transcript: "")
        _ = try writeSubagent(id: "a1_x-y", beside: main, meta: #"{"description":"x"}"#, transcript: "")
        let directory = main.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        try "{}".data(using: .utf8)?.write(to: directory.appendingPathComponent("notes.jsonl"))
        try "{}".data(using: .utf8)?.write(to: directory.appendingPathComponent("agent-.jsonl"))
        try "{}".data(using: .utf8)?.write(to: directory.appendingPathComponent("agent-a b.jsonl"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("agent-dir.jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            ActiveAgentService.subagentTranscripts(for: main.path, provider: .claude).map(\.lastPathComponent),
            ["agent-a1_x-y.jsonl", "agent-b2.jsonl"]
        )
        XCTAssertEqual(ActiveAgentService.subagentTranscripts(for: main.path, provider: .codex), [],
                       "Codex rollouts have no subagent directory to look in")

        XCTAssertEqual(ActiveAgentService.subagentID(fromTranscriptName: "agent-a0000000000000003.jsonl"), "a0000000000000003")
        XCTAssertNil(ActiveAgentService.subagentID(fromTranscriptName: "agent-a1.meta.json"))
        XCTAssertNil(ActiveAgentService.subagentID(fromTranscriptName: "agent-.jsonl"))
        XCTAssertNil(ActiveAgentService.subagentID(fromTranscriptName: "agent-a.b.jsonl"))
        XCTAssertNil(ActiveAgentService.subagentID(fromTranscriptName: "session.jsonl"))
    }

    func testTranscriptURLsForThePruneKeepTheSubagentFiles() throws {
        let main = try makeTempFile(contents: "", filename: "s4.jsonl")
        let subagent = try writeSubagent(id: "a1", beside: main, meta: nil, transcript: "")
        let codex = try makeTempFile(contents: "", filename: "rollout.jsonl")
        let codexAgent = ActiveAgent(
            provider: .codex, pid: 2, parentPID: 1, command: "codex", elapsedSeconds: 1,
            observedAt: Date(), session: claudeAgent(logPath: codex.path).session
        )

        let urls = ActiveAgentService.transcriptURLs(for: [claudeAgent(logPath: main.path), codexAgent])

        XCTAssertEqual(Set(urls.map(\.path)), [main.path, subagent.path, codex.path])
    }

    func testSubagentDescriptionFallsBackToTheFirstPromptAndIsRenderedThroughSessionLabel() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let main = try makeTempFile(contents: "", filename: "s5.jsonl")
        // No meta file: the opening words of the prompt name the row.
        _ = try writeSubagent(id: "a1", beside: main, meta: nil, transcript: """
        {"type":"user","message":{"role":"user","content":"Investigate\\n\\tthe   thing\\u0007 carefully"}}
        """)
        // Block-shaped prompt content.
        _ = try writeSubagent(id: "a2", beside: main, meta: nil, transcript: """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Block prompt"}]}}
        """)
        // A meta file past the size cap is not one Claude Code wrote: ignored.
        let oversized = "{\"description\":\"Huge\"," + String(repeating: " ", count: 70_000) + "\"agentType\":\"x\"}"
        _ = try writeSubagent(id: "a3", beside: main, meta: oversized, transcript: """
        {"type":"user","message":{"role":"user","content":"Fallback prompt"}}
        """)
        // Description text is provider text: flattened and capped on display.
        _ = try writeSubagent(id: "a4", beside: main, meta: #"{"description":"Review\n\u001b[31mchanges"}"#, transcript: "")
        // Nothing to name it by: the id stands in.
        _ = try writeSubagent(id: "a5f00dbeef", beside: main, meta: "not json", transcript: "")

        let enriched = await ActiveAgentService.enrichSessionUsage([claudeAgent(logPath: main.path)])
        let byID = Dictionary(uniqueKeysWithValues: (enriched.first?.session?.subagents ?? []).map { ($0.id, $0) })

        XCTAssertEqual(byID["a1"]?.displayTitle, "Investigate the thing carefully")
        XCTAssertEqual(byID["a2"]?.displayTitle, "Block prompt")
        XCTAssertEqual(byID["a3"]?.displayTitle, "Fallback prompt")
        XCTAssertNil(byID["a3"]?.agentType)
        XCTAssertEqual(byID["a4"]?.displayTitle, "Review [31mchanges")
        XCTAssertEqual(byID["a5f00dbeef"]?.displayTitle, "agent a5f00dbe")
        XCTAssertEqual(byID["a1"]?.usageText, "No usage yet")
        XCTAssertNil(enriched.first?.session?.tokenCount, "prompts alone spend nothing")
    }

    private func claudeAgent(logPath: String) -> ActiveAgent {
        let observedAt = Date()
        return ActiveAgent(
            provider: .claude, pid: 1, parentPID: 1, command: "claude", elapsedSeconds: 60,
            observedAt: observedAt,
            session: ActiveAgentSession(
                id: "s1", projectPath: "/p", projectName: "p", branch: nil,
                lastUpdatedAt: observedAt, source: "test", logPath: logPath
            )
        )
    }

    /// `<main dir>/<main name>/subagents/agent-<id>.jsonl` (+ `.meta.json`),
    /// the layout Claude Code writes beside a session transcript.
    func testSubagentTranscriptsIncludeWorkflowRunsOneLevelDown() throws {
        let main = try makeTempFile(contents: "", filename: "s4.jsonl")
        _ = try writeSubagent(id: "direct", beside: main, meta: nil, transcript: "")
        let run = try writeWorkflowAgent(id: "w2", run: "wf_33060b5a-94e", beside: main, meta: nil, transcript: "")
            .deletingLastPathComponent()
        _ = try writeWorkflowAgent(id: "w1", run: "wf_33060b5a-94e", beside: main, meta: nil, transcript: "")
        _ = try writeWorkflowAgent(id: "v1", run: "wf_0000aaaa-000", beside: main, meta: nil, transcript: "")
        // The run's journal is not a transcript; a run named outside the
        // session-id charset, a symlinked run, and anything deeper are ignored.
        try "{}".data(using: .utf8)?.write(to: run.appendingPathComponent("journal.jsonl"))
        _ = try writeWorkflowAgent(id: "bad", run: "wf bad", beside: main, meta: nil, transcript: "")
        let workflows = run.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(
            at: workflows.appendingPathComponent("wf_link", isDirectory: true),
            withDestinationURL: run
        )
        let deeper = run.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)?.write(to: deeper.appendingPathComponent("agent-deep.jsonl"))

        let found = ActiveAgentService.subagentTranscripts(for: main.path, provider: .claude)
        let base = main.deletingPathExtension().path + "/"
        XCTAssertEqual(
            found.map { $0.path.replacingOccurrences(of: base, with: "") },
            [
                "subagents/agent-direct.jsonl",
                "subagents/workflows/wf_0000aaaa-000/agent-v1.jsonl",
                "subagents/workflows/wf_33060b5a-94e/agent-w1.jsonl",
                "subagents/workflows/wf_33060b5a-94e/agent-w2.jsonl",
            ]
        )
    }

    func testWorkflowAgentsCountIntoTheSessionAndListUnderIt() async throws {
        await ActiveAgentService.clearSessionUsageCacheForTests()
        let main = try makeTempFile(contents: """
        {"timestamp":"2026-07-05T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}

        """, filename: "s5.jsonl")
        let transcript = """
        {"timestamp":"2026-07-05T00:01:00Z","requestId":"r9","message":{"id":"m9","model":"claude-haiku-4","usage":{"input_tokens":20,"output_tokens":10}}}

        """
        _ = try writeWorkflowAgent(
            id: "w1", run: "wf_33060b5a-94e", beside: main,
            meta: #"{"agentType":"workflow-subagent","description":"verify:impact:16","workflowPhase":"Verify"}"#,
            transcript: transcript
        )
        let agent = claudeAgent(logPath: main.path)

        let enriched = await ActiveAgentService.enrichSessionUsage([agent])

        let session = enriched.first?.session
        XCTAssertEqual(session?.tokenCount, 180, "the workflow agent's tokens join the row total")
        let child = session?.subagents.first
        XCTAssertEqual(child?.id, "w1")
        XCTAssertEqual(child?.description, "verify:impact:16")
        XCTAssertEqual(child?.agentType, "workflow-subagent")
        XCTAssertEqual(child?.tokenCount, 30)
    }

    private func writeWorkflowAgent(id: String, run: String, beside main: URL, meta: String?, transcript: String) throws -> URL {
        let directory = main.deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent(run, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("agent-\(id).jsonl")
        try transcript.data(using: .utf8)?.write(to: file)
        if let meta {
            try meta.data(using: .utf8)?.write(to: directory.appendingPathComponent("agent-\(id).meta.json"))
        }
        return file
    }

    private func writeSubagent(id: String, beside main: URL, meta: String?, transcript: String) throws -> URL {
        let directory = main.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("agent-\(id).jsonl")
        try transcript.data(using: .utf8)?.write(to: file)
        if let meta {
            try meta.data(using: .utf8)?.write(to: directory.appendingPathComponent("agent-\(id).meta.json"))
        }
        return file
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
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

    // MARK: - Review fixes: attribution guards, transcript lookup, process listing

    func testAPayloadFromBeforeTheProcessStartedDoesNotAttachThroughItsSession() {
        // A crash or a window reload leaves the predecessor's payload behind,
        // and the next `claude` in that directory resolves to the same
        // transcript (`--resume`, or the heuristic picking the newest file). A
        // session-id match used to hand it that payload, so a fresh process
        // read "waiting for input" until its first hook event.
        let now = Date(timeIntervalSince1970: 10_000)
        var agent = ActiveAgent(provider: .claude, pid: 200, parentPID: 1, command: "claude --resume",
                                elapsedSeconds: 10, observedAt: now, cwd: "/tmp/p")
        agent.session = ActiveAgentSession(id: "s", projectPath: "/tmp/p", projectName: "p", branch: nil,
                                           lastUpdatedAt: now.addingTimeInterval(-300), source: "test")
        let dead = AgentStatusPayload(state: .waiting, sessionID: "s", processAncestry: [100, 1],
                                      updatedAt: now.addingTimeInterval(-300))

        let row = ActiveAgentService.attachStatus([agent], payloads: [dead]).first

        XCTAssertNil(row?.status)
        XCTAssertNil(row?.statusUpdatedAt)
        XCTAssertEqual(row?.activityText, "idle · 5m ago")
    }

    func testAnotherProcessesPayloadDoesNotAttachThroughASharedSessionID() {
        let now = Date(timeIntervalSince1970: 10_000)
        func agent(pid: Int, elapsed: TimeInterval) -> ActiveAgent {
            var agent = ActiveAgent(provider: .claude, pid: pid, parentPID: 1, command: "claude",
                                    elapsedSeconds: elapsed, observedAt: now, cwd: "/tmp/p")
            agent.session = ActiveAgentSession(id: "s", projectPath: "/tmp/p", projectName: "p", branch: nil,
                                               lastUpdatedAt: now, source: "test")
            return agent
        }
        let owner = AgentStatusPayload(state: .working, sessionID: "s", processAncestry: [300], updatedAt: now)

        let rows = ActiveAgentService.attachStatus(
            [agent(pid: 300, elapsed: 20), agent(pid: 200, elapsed: 10)], payloads: [owner])

        XCTAssertEqual(rows.first { $0.pid == 300 }?.status, .working)
        XCTAssertNil(rows.first { $0.pid == 200 }?.status)
    }

    func testAPinnedSessionMissingOnDiskNeverFallsToTheHeuristic() {
        let now = Date(timeIntervalSince1970: 10_000)
        let payload = AgentStatusPayload(state: .working, sessionID: "hooked", processAncestry: [7], updatedAt: now)
        var identifiedWith: [String] = []
        let resolve = ActiveAgentService.sessionResolver(
            payloadsByPID: [7: payload],
            identified: { sessionID, cwd, _ in
                XCTAssertEqual(sessionID, "hooked")
                identifiedWith.append(cwd)
                return nil
            },
            heuristic: { _, _ in
                XCTFail("a hook-pinned PID must not reach the heuristic: it lists the same directory and can only return another session")
                return nil
            }
        )

        let session = resolve(.init(provider: .claude, pid: 7, cwd: "/p", startedAt: now.addingTimeInterval(-60),
                                    observedAt: now, codexRolloutIdentifier: nil, isSoleAgentForCWD: true))

        XCTAssertNil(session)
        XCTAssertEqual(identifiedWith, ["/p"])
    }

    func testLatestClaudeSessionSkipsAnotherCheckoutsTranscriptInASharedStore() throws {
        // Claude Code's SessionStart hook symlinks every checkout of a repo
        // into one store. The newest file there was the other checkout's live
        // session, so a fresh process in this one showed that session's title
        // and spend — twice in the group — until its first hook event.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-base-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(base)
        let root = base.appendingPathComponent("projects", isDirectory: true)
        let store = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        for key in ["-x-a", "-x-b"] {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(key, isDirectory: true), withDestinationURL: store)
        }
        let now = Date()
        func write(_ id: String, cwd: String, modifiedAt: Date) throws {
            let url = store.appendingPathComponent("\(id).jsonl")
            try #"{"sessionId":"\#(id)","cwd":"\#(cwd)"}"#.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        try write("A", cwd: "/x/b", modifiedAt: now)
        try write("B", cwd: "/x/a", modifiedAt: now.addingTimeInterval(-60))

        let session = ActiveAgentService.latestClaudeSession(
            cwd: "/x/a", startedAt: now.addingTimeInterval(-600), observedAt: now, projectsRoot: root)

        XCTAssertEqual(session?.id, "B")
        XCTAssertEqual(session?.projectPath, "/x/a")

        // Only the other checkout's file left: no guess, the row stays unattributed.
        try FileManager.default.removeItem(at: store.appendingPathComponent("B.jsonl"))
        XCTAssertNil(ActiveAgentService.latestClaudeSession(
            cwd: "/x/a", startedAt: now.addingTimeInterval(-600), observedAt: now, projectsRoot: root))
    }

    func testClaudeProjectKeyMatchesClaudeCodesMangling() {
        // Claude Code: `cwd.replace(/[^a-zA-Z0-9]/g, "-")`, per UTF-16 unit.
        XCTAssertEqual(ActiveAgentService.claudeProjectKey(for: "/Users/me/repo/.claude/worktrees/sample_12345"),
                       "-Users-me-repo--claude-worktrees-sample-12345")
        XCTAssertEqual(ActiveAgentService.claudeProjectKey(for: "/Users/me/my project"), "-Users-me-my-project")
        XCTAssertEqual(ActiveAgentService.claudeProjectKey(for: "/Users/me/日本/x"), "-Users-me----x")
        XCTAssertEqual(ActiveAgentService.claudeProjectKey(for: "/Users/me/😀"), "-Users-me---",
                       "an astral character is two UTF-16 units, so two dashes")
    }

    func testIdentifiedClaudeSessionFindsAWorktreeTranscriptUnderClaudeCodesKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-projects-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(root)
        let cwd = "/Users/me/repo/.claude/worktrees/sample_12345"
        let dir = root.appendingPathComponent("-Users-me-repo--claude-worktrees-sample-12345", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "11111111-2222-3333-4444-555555555555"
        try #"{"sessionId":"\#(id)","cwd":"\#(cwd)","gitBranch":"plan"}"#.write(
            to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)

        let session = ActiveAgentService.identifiedClaudeSession(
            sessionID: id, cwd: cwd, observedAt: Date(), projectsRoot: root)

        XCTAssertEqual(session?.id, id)
        XCTAssertEqual(session?.branch, "plan")
    }

    func testTranscriptHeadCutInsideAMultiByteCharacterStillYieldsMetadata() throws {
        // firstLines reads a fixed 256 KB; a cut inside a CJK character made
        // the strict decode nil and lost the branch and launch cwd every tick.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-projects-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(root)
        let dir = root.appendingPathComponent("-Users-me-project-sub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "11111111-2222-3333-4444-555555555555"
        var prefix = #"{"sessionId":"\#(id)","cwd":"/Users/me/project","gitBranch":"feature-x"}"# + "\n" + #"{"t":""#
        // Make the 262,144th byte fall inside a 3-byte character.
        if (262_144 - prefix.utf8.count) % 3 == 0 { prefix += "x" }
        let contents = prefix + String(repeating: "这", count: 100_000) + "\"}\n"
        let head = Data(contents.utf8.prefix(262_144))
        XCTAssertNil(String(data: head, encoding: .utf8), "the fixture must reproduce the cut")
        try contents.write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)

        let session = ActiveAgentService.identifiedClaudeSession(
            sessionID: id, cwd: "/Users/me/project/sub", observedAt: Date(), projectsRoot: root)

        XCTAssertEqual(session?.branch, "feature-x")
        XCTAssertEqual(session?.projectPath, "/Users/me/project")
    }

    func testCWDMapKeepsLivePIDsWhenAnotherRequestedPIDIsGone() throws {
        // lsof exits 1 for the missing PID but prints the rest; the tick used
        // to throw the whole listing away on that status.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let me = Int(ProcessInfo.processInfo.processIdentifier)

        let map = ActiveAgentService.cwdMap(for: [me, Int(gone.processIdentifier)])

        XCTAssertNotNil(map[me])
        XCTAssertNil(map[Int(gone.processIdentifier)])
    }

    func testProcessListingWithANonUTF8ArgumentStillParses() {
        // ps prints argv bytes raw; one such process used to make the whole
        // listing undecodable and empty the session list.
        let output = ActiveAgentService.runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "printf '10000 1 ?? 01:00 claude --flag \\xff\\n'"],
            timeout: 2
        )

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 0),
            cwdLookup: { _ in nil },
            resolveSession: resolver { _, _, _, _ in nil }
        )

        XCTAssertEqual(agents.map(\.pid), [10000])
    }

    func testClaudeDesktopAppMainProcessIsNotAnAgent() {
        let output = """
          PID  PPID TT       ELAPSED COMMAND
          700     1 ??          01:00 /Applications/Claude.app/Contents/MacOS/Claude
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 100),
            cwdLookup: { _ in "/" },
            resolveSession: resolver { _, _, _, _ in nil },
            executableLookup: { _ in "/Applications/Claude.app/Contents/MacOS/Claude" }
        )

        XCTAssertTrue(agents.isEmpty)
    }

    func testClaudeDesktopsBundledClaudeCodeStillCountsAsAnAgent() {
        let path = "/Users/me/Library/Application Support/Claude/claude-code/2.1.295/9d6405864fdc/claude.app/Contents/MacOS/claude"
        let output = """
          PID  PPID TT       ELAPSED COMMAND
          701   700 ??          00:30 \(path) --resume
        """

        let agents = ActiveAgentService.parsePSOutput(
            output,
            observedAt: Date(timeIntervalSince1970: 100),
            cwdLookup: { _ in "/Users/me/project" },
            resolveSession: resolver { _, _, _, _ in nil },
            executableLookup: { _ in path }
        )

        XCTAssertEqual(agents.map(\.pid), [701])
        XCTAssertEqual(agents.first?.provider, .claude)
    }

    func testAPinnedIDThatIsNotASessionIDStillAllowsTheHeuristic() {
        // A payload written without a session id carries the cwd in its
        // place (manual helper use); that pins nothing, so a sole agent keeps
        // its newest-file lookup.
        let now = Date(timeIntervalSince1970: 10_000)
        let payload = AgentStatusPayload(state: .working, sessionID: "/Users/me/p", processAncestry: [7], updatedAt: now)
        let guessed = ActiveAgentSession(id: "guessed", projectPath: "/p", projectName: "p", branch: nil,
                                         lastUpdatedAt: now, source: "test")
        let resolve = ActiveAgentService.sessionResolver(
            payloadsByPID: [7: payload],
            identified: { _, _, _ in nil },
            heuristic: { _, _ in guessed }
        )

        let session = resolve(.init(provider: .claude, pid: 7, cwd: "/p", startedAt: now.addingTimeInterval(-60),
                                    observedAt: now, codexRolloutIdentifier: nil, isSoleAgentForCWD: true))

        XCTAssertEqual(session?.id, "guessed")
    }

    func testCWDMapReturnsANonASCIIDirectoryVerbatim() throws {
        // Without a locale lsof prints `\xe6\x97\xa5…` for this directory; the
        // app is launched by launchd with none, so the helper states its own.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-日本 \(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        sleeper.currentDirectoryURL = dir
        try sleeper.run()
        defer { sleeper.terminate() }

        let map = ActiveAgentService.cwdMap(for: [Int(sleeper.processIdentifier)])

        // lsof reports the real path (`/private/var/…` for a temp dir); the
        // name is what must come back unescaped.
        XCTAssertEqual(map[Int(sleeper.processIdentifier)].map { URL(fileURLWithPath: $0).lastPathComponent },
                       dir.lastPathComponent)
    }
}
