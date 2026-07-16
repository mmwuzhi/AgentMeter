import AppKit

/// Brings the exact terminal tab or editor workspace hosting an agent forward,
/// with whole-app activation as the fallback.
enum AgentAppActivator {
    @MainActor
    @discardableResult
    static func focus(_ agent: ActiveAgent) -> Bool {
        let host = hostApp(forPID: agent.pid)
        if let tty = agent.tty,
           focusTerminalTab(bundleID: host?.bundleIdentifier, tty: tty, cwd: agent.cwd) {
            return true
        }
        if let cwd = agent.cwd,
           focusEditorWindow(bundleID: host?.bundleIdentifier, cwd: cwd) {
            return true
        }
        return host?.activate() ?? false
    }

    @MainActor
    static func focusEditorWindow(bundleID: String?, cwd: String) -> Bool {
        guard let url = editorURL(bundleID: bundleID, cwd: cwd) else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func editorURL(bundleID: String?, cwd: String) -> URL? {
        guard let scheme = editorURLScheme(for: bundleID), cwd.hasPrefix("/") else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = cwd
        return components.url
    }

    static func editorURLScheme(for bundleID: String?) -> String? {
        switch bundleID {
        case "com.microsoft.VSCode": return "vscode"
        case "com.microsoft.VSCodeInsiders": return "vscode-insiders"
        case "com.vscodium.codium", "com.visualstudio.code.oss": return "vscodium"
        case "com.todesktop.230313mzl4w4u92": return "cursor"
        default: return nil
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
