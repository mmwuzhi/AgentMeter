import AppKit

/// Jumps from an active agent process to the GUI app hosting it.
enum AgentAppActivator {
    @MainActor
    @discardableResult
    static func activateHostApp(forPID pid: Int) -> Bool {
        var current = pid_t(pid)
        // Bounded walk: a runaway ppid loop must not hang the UI.
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return app.activate(options: [])
            }
            guard let parent = parentPID(of: current), parent > 1 else { return false }
            current = parent
        }
        return false
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return info.kp_eproc.e_ppid
    }
}
