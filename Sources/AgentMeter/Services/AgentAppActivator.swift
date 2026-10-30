import AppKit

/// What a session row's click says when it brought nothing forward. Shown
/// under the row until the popover closes, with a button for the app when
/// there is one.
struct SessionRowNotice: Sendable, Equatable {
    let pid: Int
    let text: String
    var appPID: Int? = nil
    var appName: String? = nil

    init(pid: Int, text: String, appPID: Int? = nil, appName: String? = nil) {
        self.pid = pid
        self.text = Self.oneLine(text, limit: 300)
        self.appPID = appPID
        self.appName = appName.map { Self.oneLine($0, limit: 40) }
    }

    /// App names and system errors are shown as given, so as one bounded line.
    static func oneLine(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        return String(String(scalars).split(separator: " ").joined(separator: " ").prefix(limit))
    }
}

/// Brings forward what hosts an agent: the exact terminal tab, else the
/// editor window of a session the Claude Code extension runs
/// (`EditorWindowLocator`), else the whole app. The one URL opened is that
/// window's folder with `windowId=_blank` (`EditorApp.folderURL`): without
/// it, `vscode://file/<folder>` replaces the last active window's workspace
/// when no window holds exactly that single folder, ending the sessions in
/// it (docs/agent/ui-state.md, "Task outcomes: banners and session rows").
enum AgentAppActivator {

    /// A session row's click. Nil when something came forward; otherwise what
    /// the row should say, and nothing was activated.
    @MainActor
    static func focus(_ agent: ActiveAgent, locator: EditorWindowLocator = .live) async -> SessionRowNotice? {
        // The row is from the last refresh: a PID reused since is another process.
        let started = agent.observedAt.addingTimeInterval(-agent.elapsedSeconds)
        guard let start = TaskOutcomeMonitor.processStartDate(agent.pid),
              abs(start.timeIntervalSince(started)) <= TaskSessionLookup.rowStartTolerance else {
            return SessionRowNotice(pid: agent.pid, text: "This session has ended.")
        }
        let host = hostApp(forPID: agent.pid)
        if let tty = agent.tty,
           focusTerminalTab(bundleID: host?.bundleIdentifier, tty: tty, cwd: agent.cwd) {
            return nil
        }
        guard let host else {
            return SessionRowNotice(pid: agent.pid, text: "It runs in nothing AgentMeter can bring forward.")
        }
        let editor = EditorApp.named(bundleID: host.bundleIdentifier)
        // VS Code calls itself "Code"; the notice's text says "VS Code".
        let name = editor?.name ?? host.localizedName ?? host.bundleIdentifier ?? "Its app"
        let notice = { (text: String) in
            SessionRowNotice(pid: agent.pid, text: text, appPID: Int(host.processIdentifier), appName: name)
        }
        guard let editor else {
            return host.activate() ? nil : notice("\(name) did not come forward.")
        }
        // The folder would go to one copy, maybe not the one running the session.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: editor.bundleID).count == 1 else {
            return notice("More than one copy of \(editor.name) is running, so AgentMeter can't tell which window runs it.")
        }
        let pid = agent.pid
        let editorPID = Int(host.processIdentifier)
        let target = await Task.detached(priority: .userInitiated) {
            locator.target(sessionPID: pid, editorPID: editorPID, editor: editor)
        }.value
        switch target {
        case let .unnamed(miss):
            return notice(miss.explanation(editor: editor.name))
        case let .folder(path):
            // To this copy of the editor, whichever app handles the scheme.
            guard let appURL = host.bundleURL, let url = editor.folderURL(path) else {
                return notice(EditorWindowMiss.unusualFolder(folder: path).explanation(editor: editor.name))
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
                return nil
            } catch {
                return notice("\(editor.name) did not take \(EditorWindowMiss.folderName(path)): \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    @discardableResult
    static func activateHostApp(forPID pid: Int) -> Bool {
        hostApp(forPID: pid)?.activate() ?? false
    }

    @MainActor
    static func hostApp(forPID pid: Int) -> NSRunningApplication? {
        var current = pid_t(pid)
        var visited = Set<pid_t>()
        while current > 1, visited.insert(current).inserted, visited.count <= 32 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    @MainActor
    static func focusTerminalTab(bundleID: String?, tty: String, cwd: String?) -> Bool {
        guard isSafeTTY(tty) else { return false }
        let devTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        switch bundleID {
        case "com.googlecode.iterm2":
            return runAppleScript(iTermFocusScript(tty: devTTY))
        case "com.apple.Terminal":
            return runAppleScript(terminalFocusScript(tty: devTTY))
        case "com.mitchellh.ghostty":
            guard let cwd,
                  !cwd.isEmpty,
                  !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  runAppleScript(ghosttyFocusScript(workingDirectory: cwd)) else { return false }
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
                .first?
                .activate()
            return true
        default:
            return false
        }
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The process's controlling terminal as `ps` names it ("ttys003"), or nil
    /// for none (`??`): a session the editor's extension started has none.
    static func controllingTTY(of pid: Int) -> String? {
        guard pid > 0, let value = pid_t(exactly: pid) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, value]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.isEmpty || tty == "??" ? nil : tty
    }

    private static func isSafeTTY(_ tty: String) -> Bool {
        !tty.isEmpty && tty.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "/_-".unicodeScalars.contains($0)
        }
    }

    @MainActor
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    static func iTermFocusScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if tty of aSession is "\(appleScriptEscaped(tty))" then
                            select aSession
                            set current tab of aWindow to aTab
                            set index of aWindow to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    static func terminalFocusScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if tty of aTab is "\(appleScriptEscaped(tty))" then
                        set selected tab of aWindow to aTab
                        set index of aWindow to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    static func ghosttyFocusScript(workingDirectory: String) -> String {
        """
        tell application "Ghostty"
            repeat with aTerminal in terminals
                if working directory of aTerminal is "\(appleScriptEscaped(workingDirectory))" then
                    focus aTerminal
                    return true
                end if
            end repeat
        end tell
        return false
        """
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
