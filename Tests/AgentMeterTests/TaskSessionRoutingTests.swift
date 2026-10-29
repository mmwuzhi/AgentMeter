@testable import AgentMeter
import Foundation
import XCTest

/// What the stub lookup was asked to do. Nothing here reaches a real app.
@MainActor
final class RoutingRecorder {
    var focused: [Int] = []
    var activated: [Int] = []
    var focusSucceeds = true
    var activateSucceeds = true
    var hostLookups = 0
}

@MainActor
func stubLookup(
    registry: [Int: ClaudeSessionRegistryEntry] = [:], starts: [Int: Date] = [:], parents: [Int: Int] = [:],
    ttys: [Int: String] = [:], hosts: [Int: TaskSessionHost] = [:], now: Date, recorder: RoutingRecorder
) -> TaskSessionLookup {
    TaskSessionLookup(
        readRegistry: { registry },
        processStart: { starts[$0] },
        parentPID: { parents[$0] },
        tty: { ttys[$0] },
        host: { pid in
            recorder.hostLookups += 1
            return hosts[pid]
        },
        now: { now },
        focusTerminal: { process in
            recorder.focused.append(process.pid)
            return recorder.focusSucceeds
        },
        activate: { host in
            recorder.activated.append(host.pid)
            return recorder.activateSucceeds
        })
}

let vscodeHost = TaskSessionHost(pid: 6986, bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")
let itermHost = TaskSessionHost(pid: 500, bundleID: "com.googlecode.iterm2", name: "iTerm2")

final class TaskSessionRoutingTests: XCTestCase {
    private func process(_ pid: Int, tty: String? = nil, cwd: String? = "/Users/u/work/agentmeter",
                         host: TaskSessionHost? = vscodeHost, ancestors: [Int] = [13395, 6986]) -> TaskSessionProcess {
        TaskSessionProcess(pid: pid, ancestorPIDs: ancestors, tty: tty, cwd: cwd, host: host)
    }

    // MARK: - Route

    func testAnEditorSessionOnlyEverGetsItsAppBroughtForward() {
        // The extension's own session (no tty) and one in the editor's
        // integrated terminal alike: no window switching, no URL.
        let extensionSession = process(2114)
        XCTAssertEqual(TaskSessionRouting.route(for: [extensionSession]), .appOnly(extensionSession))
        let integrated = process(42, tty: "ttys004", cwd: "/Users/u/work/agentmeter/Sources")
        XCTAssertEqual(TaskSessionRouting.route(for: [integrated]), .appOnly(integrated))
        let other = process(79, host: TaskSessionHost(pid: 8, bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA"))
        XCTAssertEqual(TaskSessionRouting.route(for: [other]), .appOnly(other))
    }

    func testTerminalsGoToTheirTabByTTY() {
        let tab = process(77, tty: "ttys002", host: itermHost)
        XCTAssertEqual(TaskSessionRouting.route(for: [tab]), .terminalTab(tab))
        let noTTY = process(78, tty: nil, host: itermHost)
        XCTAssertEqual(TaskSessionRouting.route(for: [noTTY]), .appOnly(noTTY), "no tty to find the tab by")
    }

    func testNothingLiveIsEndedNoAppIsUnhostedTwoUnrelatedAreAmbiguous() {
        XCTAssertEqual(TaskSessionRouting.route(for: []), .ended)
        XCTAssertEqual(TaskSessionRouting.route(for: [process(3, host: nil)]), .unhosted)
        // A second process resuming the same session in another window.
        let first = process(10, ancestors: [13395, 6986])
        let second = process(11, ancestors: [12890, 6986])
        XCTAssertEqual(TaskSessionRouting.route(for: [first, second]), .ambiguous(2))
        XCTAssertEqual(TaskSessionRouting.route(for: [first, first]), TaskSessionRouting.route(for: [first]),
                       "one process found twice is one")
    }

    func testHelpersRegisteredUnderTheSessionsIDDoNotCount() {
        // Claude Code registers helpers it spawns under the session's id;
        // they descend from the session's own process.
        let main = process(10)
        let helper = process(20, cwd: "/tmp", ancestors: [10, 13395, 6986])
        XCTAssertEqual(TaskSessionRouting.route(for: [helper, main]), TaskSessionRouting.route(for: [main]))
    }

    // MARK: - Finding the processes

    @MainActor
    func testRowsCountOnlyWhileTheirProcessIsTheOneTheRowSaw() async {
        let observed = Date(timeIntervalSince1970: 1_792_480_000)
        let recorder = RoutingRecorder()
        func row(_ pid: Int, session: String = "s1") -> ActiveAgent {
            ActiveAgent(provider: .claude, pid: pid, parentPID: 13395, command: "claude", elapsedSeconds: 600,
                        observedAt: observed, tty: nil, cwd: "/Users/u/p",
                        session: ActiveAgentSession(id: session, projectPath: "/Users/u/p", projectName: nil, branch: nil,
                                                    lastUpdatedAt: nil, source: "test"))
        }
        let lookup = stubLookup(
            starts: [100: observed.addingTimeInterval(-598), 200: observed.addingTimeInterval(-60)],
            parents: [100: 13395, 13395: 6986, 6986: 1, 200: 13395],
            hosts: [100: vscodeHost, 200: vscodeHost], now: observed.addingTimeInterval(30), recorder: recorder)
        let found = await lookup.processes(sessionID: "s1", rows: [row(100), row(200), row(300), row(400, session: "s2")])
        XCTAssertEqual(found.map(\.pid), [100], "200 is a reused PID; 300 is gone; 400 is another session")
        XCTAssertEqual(found.first?.ancestorPIDs, [13395, 6986])
        XCTAssertEqual(found.first?.host, vscodeHost)
        XCTAssertEqual(found.first?.cwd, "/Users/u/p")
        XCTAssertEqual(TaskSessionRouting.route(for: found), .appOnly(found[0]))
    }

    @MainActor
    func testTheRegistryFindsASessionNewerThanTheRowsAndGuardsPIDReuse() async {
        let now = Date(timeIntervalSince1970: 1_792_480_000)
        let recorder = RoutingRecorder()
        let started = now.addingTimeInterval(-100)
        let registry: [Int: ClaudeSessionRegistryEntry] = [
            100: ClaudeSessionRegistryEntry(pid: 100, sessionID: "s1", cwd: "/Users/u/p", startedAt: started.addingTimeInterval(1),
                                            status: .idle, waitingFor: nil, statusUpdatedAt: now),
            // An earlier holder of PID 300 left this file.
            300: ClaudeSessionRegistryEntry(pid: 300, sessionID: "s1", cwd: "/Users/u/p",
                                            startedAt: started.addingTimeInterval(-3_600), status: .idle,
                                            waitingFor: nil, statusUpdatedAt: now),
            400: ClaudeSessionRegistryEntry(pid: 400, sessionID: "s1", cwd: "/Users/u/p", startedAt: started,
                                            status: .idle, waitingFor: nil, statusUpdatedAt: now),
        ]
        let lookup = stubLookup(registry: registry, starts: [100: started, 300: started],
                                ttys: [100: "ttys009"], hosts: [100: itermHost], now: now, recorder: recorder)
        let found = await lookup.processes(sessionID: "s1", rows: [])
        XCTAssertEqual(found.map(\.pid), [100], "300 failed the PID guard; 400 is not running")
        XCTAssertEqual(found.first?.tty, "ttys009")
        XCTAssertEqual(TaskSessionRouting.route(for: found), .terminalTab(found[0]))
    }

    func testTheControllingTTYOfThisTestAndOfNoProcess() {
        XCTAssertNil(AgentAppActivator.controllingTTY(of: -1))
        XCTAssertNil(AgentAppActivator.controllingTTY(of: 999_999_999))
        // `swift test` may or may not have a terminal; either way it is a
        // plain device name, never "??".
        if let tty = AgentAppActivator.controllingTTY(of: Int(getpid())) {
            XCTAssertTrue(tty.hasPrefix("tty"), tty)
        }
    }
}

/// Routes every live Claude session on this Mac with the real lookup, but
/// with focusing and activation replaced by a recorder: nothing is brought
/// forward. Skipped unless `AGENTMETER_LIVE_ROUTE_DRYRUN=1`.
final class TaskSessionRoutingLiveDryRunTests: XCTestCase {
    @MainActor
    func testRouteEveryLiveSessionWithoutActing() async throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_LIVE_ROUTE_DRYRUN"] == "1" else {
            throw XCTSkip("set AGENTMETER_LIVE_ROUTE_DRYRUN=1 to route live sessions (read-only)")
        }
        let recorder = RoutingRecorder()
        var lookup = TaskSessionLookup.live
        lookup.focusTerminal = { recorder.focused.append($0.pid); return true }
        lookup.activate = { recorder.activated.append($0.pid); return true }
        let sessions = Set(ClaudeSessionRegistry.readAll().values.compactMap(\.sessionID))
        var kinds: [String: Int] = [:]
        for session in sessions.sorted() {
            let processes = await lookup.processes(sessionID: session, rows: [])
            let kind: String
            switch TaskSessionRouting.route(for: processes) {
            case .terminalTab: kind = "terminalTab"
            case let .appOnly(process): kind = "appOnly \(process.host?.name ?? "?")"
            case .unhosted: kind = "unhosted"
            case .ended: kind = "ended"
            case let .ambiguous(count): kind = "ambiguous \(count)"
            }
            kinds[kind, default: 0] += 1
        }
        for (kind, count) in kinds.sorted(by: { $0.key < $1.key }) { print("LIVE-ROUTE \(count) × \(kind)") }
        print("LIVE-ROUTE sessions \(sessions.count), focused \(recorder.focused.count), activated \(recorder.activated.count)")
        XCTAssertTrue(recorder.focused.isEmpty && recorder.activated.isEmpty, "routing alone never acts")
    }
}
