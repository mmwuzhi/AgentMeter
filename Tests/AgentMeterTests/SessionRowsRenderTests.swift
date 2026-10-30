import AgentStatusCore
@testable import AgentMeter
import AppKit
import SwiftUI
import XCTest

/// Renders the Sessions box with latest-turn marks to PNG files for a visual
/// check, since this environment cannot capture the menu bar or a popover.
/// Skipped unless `AGENTMETER_RENDER_DIR` names an output directory:
///
///     AGENTMETER_RENDER_DIR=/path/to/dir swift test --filter SessionRowsRenderTests
///
/// Off-screen windows only; nothing is shown.
@MainActor
final class SessionRowsRenderTests: XCTestCase {
    private var outputDirectory: URL!
    private let now = Date(timeIntervalSince1970: 1_793_275_200)

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTMETER_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("set AGENTMETER_RENDER_DIR to render")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func agent(_ pid: Int, _ status: AgentStatusState?, stateAge: TimeInterval = 300, project: String,
                       session: String, title: String?, model: String? = "claude-opus-5-5", effort: String? = "xhigh",
                       tokens: Int = 2_400_000, cost: Double = 3.4) -> ActiveAgent {
        ActiveAgent(
            provider: .claude, pid: pid, parentPID: 1, command: "claude", elapsedSeconds: 3_600, observedAt: now,
            tty: "ttys00\(pid % 10)", cwd: "/Users/me/\(project)",
            session: ActiveAgentSession(id: session, projectPath: "/Users/me/\(project)", projectName: project,
                                        branch: "main", lastUpdatedAt: now.addingTimeInterval(-stateAge), source: "test",
                                        tokenCount: tokens, estimatedCostUSD: cost, model: model, effort: effort,
                                        title: title),
            status: status, statusUpdatedAt: now.addingTimeInterval(-stateAge), statusSource: status == nil ? nil : .registry)
    }

    private func results() -> [String: SessionTurnResult] {
        [
            "a1": SessionTurnResult(outcome: .finished, endedAt: now.addingTimeInterval(-180), detail: "12m run"),
            "b1": SessionTurnResult(outcome: .finished, endedAt: now.addingTimeInterval(-420), detail: "3m run"),
            "c1": SessionTurnResult(outcome: .failed, endedAt: now.addingTimeInterval(-240), detail: "Rate limit"),
            "d1": SessionTurnResult(outcome: .finished, endedAt: now.addingTimeInterval(-5_000), detail: "expired"),
        ]
    }

    private func agents() -> [ActiveAgent] {
        [
            agent(11, .working, stateAge: 20, project: "AgentMeter", session: "w1", title: "Session list marks"),
            agent(12, .idle, stateAge: 180, project: "AgentMeter", session: "a1", title: "Remove inbox"),
            agent(13, .waiting, stateAge: 90, project: "chronicle", session: "x1", title: "Backfill review"),
            agent(14, .idle, stateAge: 420, project: "blog", session: "b1", title: "Draft post", model: "claude-sonnet-5-5",
                  effort: nil),
            agent(15, .idle, stateAge: 240, project: "scripts", session: "c1", title: "Hub server"),
            agent(16, .error, stateAge: 600, project: "pollen", session: "e1", title: "TUI refactor"),
            agent(17, .idle, stateAge: 5_000, project: "rag", session: "d1", title: "Old idle"),
            agent(18, .idle, stateAge: 200, project: "mfa", session: "m1", title: "Two sessions"),
            agent(19, .idle, stateAge: 190, project: "mfa", session: "m2", title: "Second one"),
        ]
    }

    func testSessionRowsWithMarks() throws {
        for dark in [false, true] {
            let model = AppViewModel(snapshot: nil, storedLifetimeSpend: [])
            var results = results()
            results["m2"] = SessionTurnResult(outcome: .finished, endedAt: now.addingTimeInterval(-190), detail: nil)
            model.sessionTurnResults = results
            // Groups expanded, to see every row; then collapsed headers.
            let listed = agents()
            for group in ActiveAgentGrouping.group(listed) { model.sessionDisclosure[group.id] = true }
            try render(ActiveAgentsSection(agents: listed).environment(model).padding(12).frame(width: 316),
                       name: "sessions-expanded", dark: dark)
            model.sessionDisclosure = [:]
            try render(ActiveAgentsSection(agents: listed).environment(model).padding(12).frame(width: 316),
                       name: "sessions-collapsed", dark: dark)
            model.sessionTurnResults = [:]
            try render(ActiveAgentsSection(agents: listed).environment(model).padding(12).frame(width: 316),
                       name: "sessions-no-results", dark: dark)
        }
    }

    // MARK: - Rendering

    private func render<V: View>(_ view: V, name: String, dark: Bool, settle: TimeInterval = 0.1) throws {
        let backdrop = dark ? Color(white: 0.16) : Color(white: 0.97)
        let host = NSHostingView(rootView: view.background(backdrop).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 460, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try write(host, name: "\(name)-\(dark ? "dark" : "light")")
        window.close()
    }

    private func write(_ view: NSView, name: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
