import AppKit

/// Brings the exact terminal tab hosting an agent forward, with whole-app
/// activation as the fallback. Editor windows are never switched with a URL:
/// `vscode://file/<folder>` replaces the last active window's workspace when
/// no window holds exactly that single folder, ending the sessions in it
/// (docs/agent/ui-state.md, "Task notifications in the menu").
enum AgentAppActivator {
    @MainActor
    @discardableResult
    static func focus(_ agent: ActiveAgent) -> Bool {
        let host = hostApp(forPID: agent.pid)
        if let tty = agent.tty,
           focusTerminalTab(bundleID: host?.bundleIdentifier, tty: tty, cwd: agent.cwd) {
            return true
        }
        return host?.activate() ?? false
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
