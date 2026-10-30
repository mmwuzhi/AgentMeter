import AppKit
import Darwin
import Foundation

// Where a click on a task notification (or its row in the menu) takes the
// user. The rule is to bring forward only what already runs the session, and
// never to open or resume one:
//
//  * A terminal tab is selected by its tty (AppleScript in Terminal and
//    iTerm2; Ghostty by working directory). That only selects a tab that
//    exists.
//  * Anything else, editors included, gets its app activated by the click
//    and nothing more. No URL is opened: Claude Code's session URI
//    (`vscode://anthropic.claude-code/open?session=`) can open a second
//    process resuming the session in the wrong window (design 5.9 E), and
//    `vscode://file/<folder>` replaces the last active window's workspace
//    whenever no window holds exactly that single folder, which nothing
//    AgentMeter can read rules out (a one-folder `.code-workspace`, a window
//    closing meanwhile). A session row's click names the window with
//    `EditorWindowLocator`; a tap here does not (docs/agent/ui-state.md).
//  * Anything uncertain (no live process, two processes claiming the
//    session, a failed focus) brings nothing forward: a line under the
//    task's row says why.

/// A live process that reports the session, as found at click time.
struct TaskSessionProcess: Sendable, Equatable {
    var pid: Int
    /// Up to the first 32 ancestors, nearest first.
    var ancestorPIDs: [Int] = []
    var tty: String?
    var cwd: String?
    var host: TaskSessionHost?
}

/// The app that hosts the process: the nearest ancestor with a Dock presence.
struct TaskSessionHost: Sendable, Equatable {
    var pid: Int
    var bundleID: String?
    var name: String
}

enum TaskSessionRoute: Sendable, Equatable {
    /// The terminal tab by its tty (Ghostty: by working directory).
    case terminalTab(TaskSessionProcess)
    /// Alive in an app whose window AgentMeter does not switch to (editors)
    /// or cannot name: a click brings the app forward.
    case appOnly(TaskSessionProcess)
    /// Alive, but in nothing AgentMeter can bring forward (ssh, tmux server).
    case unhosted
    /// No live process reports the session.
    case ended
    /// Unrelated live processes report the same session.
    case ambiguous(Int)
}

enum TaskSessionRouting {
    static let terminalBundleIDs: Set<String> = ["com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty"]

    static func route(for processes: [TaskSessionProcess]) -> TaskSessionRoute {
        var unique: [Int: TaskSessionProcess] = [:]
        for process in processes where unique[process.pid] == nil { unique[process.pid] = process }
        // Claude Code registers helpers it spawns under the session's id;
        // they descend from the session's process and do not count.
        let pids = Set(unique.keys)
        let roots = unique.values.filter { process in
            !process.ancestorPIDs.contains { $0 != process.pid && pids.contains($0) }
        }
        guard let process = roots.first else { return .ended }
        guard roots.count == 1 else { return .ambiguous(roots.count) }
        guard let host = process.host else { return .unhosted }
        if process.tty != nil, let bundleID = host.bundleID, terminalBundleIDs.contains(bundleID) {
            return .terminalTab(process)
        }
        return .appOnly(process)
    }
}

/// Finds the processes behind a session, and focuses what a route names.
/// Closures so a test can stand in for the kernel and the apps.
struct TaskSessionLookup: Sendable {
    var readRegistry: @Sendable () -> [Int: ClaudeSessionRegistryEntry]
    var processStart: @Sendable (Int) -> Date?
    var parentPID: @Sendable (Int) -> Int?
    var tty: @Sendable (Int) -> String?
    var host: @MainActor (Int) -> TaskSessionHost?
    var now: @Sendable () -> Date
    var focusTerminal: @MainActor (TaskSessionProcess) -> Bool
    var activate: @MainActor (TaskSessionHost) -> Bool

    /// A row's process is the one `ps` saw only if it started when the row
    /// says (`observedAt - elapsedSeconds`, whole seconds); a PID reused
    /// since the last refresh is another process.
    static let rowStartTolerance: TimeInterval = 5
    static let maximumAncestors = 32

    /// Live processes reporting `sessionID`: from the latest rows (hook or
    /// registry attribution) and from Claude Code's registry read now (a
    /// session newer than the last full refresh), each checked against
    /// PID reuse.
    @MainActor
    func processes(sessionID: String, rows: [ActiveAgent]) async -> [TaskSessionProcess] {
        let candidates = rows.filter { $0.session?.id == sessionID }
            .map { (pid: $0.pid, tty: $0.tty, cwd: $0.cwd, started: $0.observedAt.addingTimeInterval(-$0.elapsedSeconds)) }
        let lookup = self
        let found: [TaskSessionProcess] = await Task.detached(priority: .userInitiated) {
            var result: [Int: TaskSessionProcess] = [:]
            for row in candidates {
                guard let start = lookup.processStart(row.pid),
                      abs(start.timeIntervalSince(row.started)) <= Self.rowStartTolerance else { continue }
                result[row.pid] = TaskSessionProcess(pid: row.pid, ancestorPIDs: lookup.ancestors(of: row.pid),
                                                     tty: row.tty, cwd: row.cwd)
            }
            let registry = lookup.readRegistry()
            let now = lookup.now()
            for entry in registry.values where entry.sessionID == sessionID && result[entry.pid] == nil {
                guard let start = lookup.processStart(entry.pid),
                      ClaudeSessionRegistry.entry(for: entry.pid, processStartedAt: start, observedAt: now, in: registry) != nil
                else { continue }
                result[entry.pid] = TaskSessionProcess(pid: entry.pid, ancestorPIDs: lookup.ancestors(of: entry.pid),
                                                       tty: lookup.tty(entry.pid), cwd: entry.cwd)
            }
            return result.values.sorted { $0.pid < $1.pid }
        }.value
        return found.map { process in
            var process = process
            process.host = host(process.pid)
            return process
        }
    }

    func ancestors(of pid: Int) -> [Int] {
        var chain: [Int] = []
        var current = pid
        while chain.count < Self.maximumAncestors, let parent = parentPID(current), parent > 1, !chain.contains(parent) {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    static let live = TaskSessionLookup(
        readRegistry: { ClaudeSessionRegistry.readAll() },
        processStart: { TaskOutcomeMonitor.processStartDate($0) },
        parentPID: { pid in
            guard let value = pid_t(exactly: pid) else { return nil }
            return AgentAppActivator.parentPID(of: value).map(Int.init)
        },
        tty: { AgentAppActivator.controllingTTY(of: $0) },
        host: { pid in
            guard let app = AgentAppActivator.hostApp(forPID: pid) else { return nil }
            return TaskSessionHost(pid: Int(app.processIdentifier), bundleID: app.bundleIdentifier,
                                   name: app.localizedName ?? app.bundleIdentifier ?? "the app")
        },
        now: { Date() },
        focusTerminal: { process in
            guard let tty = process.tty else { return false }
            return AgentAppActivator.focusTerminalTab(bundleID: process.host?.bundleID, tty: tty, cwd: process.cwd)
        },
        activate: { host in
            guard let value = pid_t(exactly: host.pid) else { return false }
            return NSRunningApplication(processIdentifier: value)?.activate() ?? false
        }
    )
}
