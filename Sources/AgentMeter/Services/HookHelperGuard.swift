import AppKit
import Dispatch
import os

/// Which running AgentMeter keeps the shared hook helper
/// (`ClaudeHookInstaller.managedCLIURL`): the newest build, so a stale copy
/// started next to it never puts an older helper back, and a build left
/// running alone (a rollback) installs its own.
///
/// Known limit: every running copy with this bundle id counts, also a
/// sandboxed test instance whose helper lives under another home; while a
/// newer one runs, the real helper is not guarded.
enum HookHelperOwnership {
    struct Instance: Sendable, Equatable {
        var pid: pid_t
        /// `CFBundleShortVersionString` and `CFBundleVersion` as its bundle
        /// on disk has them; nil when it cannot be read.
        var version: String?
        var build: String?
        var launchedAt: Date?
    }

    /// The newest version, then the newest build of the same numbering, then
    /// the one launched last (what launching did before: the last copy
    /// started installed its helper), then the higher pid. Every running
    /// copy reaches the same answer from the same data.
    static func owner(of instances: [Instance]) -> Instance? {
        instances.max(by: ranksBelow)
    }

    static func ranksBelow(_ a: Instance, _ b: Instance) -> Bool {
        for order in [(a.version ?? "").compare(b.version ?? "", options: .numeric), compareBuilds(a.build, b.build)]
        where order != .orderedSame {
            return order == .orderedAscending
        }
        let aLaunched = a.launchedAt ?? .distantPast
        let bLaunched = b.launchedAt ?? .distantPast
        return aLaunched != bLaunched ? aLaunched < bLaunched : a.pid < b.pid
    }

    /// Builds are numbered by their time (`Scripts/build-number.sh`, 12
    /// digits) since 0.9.0, local and CI alike; a release before it was
    /// numbered by its CI run (`github.run_number`, v0.8.2 is 19): a number
    /// from one says nothing about one from the other.
    static func compareBuilds(_ a: String?, _ b: String?) -> ComparisonResult {
        if let a, let b, isTimeNumbered(a) != isTimeNumbered(b) { return .orderedSame }
        return (a ?? "").compare(b ?? "", options: .numeric)
    }

    private static func isTimeNumbered(_ build: String) -> Bool {
        build.count >= 12 && build.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// This process, unless another running copy of the app outranks it.
    /// Its own version is read from disk too, like the others': the helper
    /// it would write is the one on disk, and a bundle replaced under a
    /// running copy must not make two copies each think they rank first.
    static func thisInstanceOwnsHelper() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        var instances = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
            .map { instance(pid: $0.processIdentifier, bundleURL: $0.bundleURL, launchedAt: $0.launchDate) }
        instances.append(instance(pid: me, bundleURL: Bundle.main.bundleURL,
                                  launchedAt: NSRunningApplication.current.launchDate))
        return owner(of: instances)?.pid == me
    }

    /// Read from disk each time: `Bundle` caches what a path held first.
    private static func instance(pid: pid_t, bundleURL: URL?, launchedAt: Date?) -> Instance {
        let info = bundleURL.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
        return Instance(pid: pid, version: info?["CFBundleShortVersionString"] as? String,
                        build: info?["CFBundleVersion"] as? String, launchedAt: launchedAt)
    }
}

/// Keeps the shared hook helper this build's while the app runs, not only at
/// launch. Every copy of the app installs its helper when it starts, and
/// every Claude Code hook runs that one file. On 2026-10-30 a click on a
/// banner made macOS open a stale copy kept in a backup folder
/// (LaunchServices resolved the bundle id to it); it put back its 10-16
/// helper, which writes no turn ledgers, and the installed app, still
/// running, saw no task end from then on and posted nothing.
///
/// Looks again when the helper's directory changes and every
/// `recheckInterval`, which also re-arms the watch when the directory came
/// later and takes the helper back after a newer copy quit. (NSWorkspace
/// posts no launch or quit notification for an LSUIElement app like this
/// one.) Only with the hooks on; `ClaudeHookInstaller.refreshManagedCLI`
/// does nothing when the helper is already this build's or a newer copy
/// owns it.
@MainActor
final class HookHelperGuard {
    static let recheckInterval: TimeInterval = 60
    /// An install is a temporary file renamed into place: one burst.
    static let watchDebounce: TimeInterval = 0.5
    /// Two copies that each took themselves for the owner would rewrite the
    /// helper in turn, every write firing the other's watch. A restore the
    /// watch asks for this soon after the last one waits for the timer.
    static let minimumRestoreInterval: TimeInterval = 10

    private let directory: URL
    private let enabled: () -> Bool
    private let refresh: () -> ClaudeHookInstaller.ManagedCLIRefresh
    private var lastRestore: Date?
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var checkPending = false
    private static let logger = Logger(subsystem: "com.shu.agentmeter", category: "hooks")

    init(
        directory: URL = ClaudeHookInstaller.managedCLIURL.deletingLastPathComponent(),
        enabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "statusHooksEnabled") },
        refresh: @escaping () -> ClaudeHookInstaller.ManagedCLIRefresh = { ClaudeHookInstaller.refreshManagedCLI() }
    ) {
        self.directory = directory
        self.enabled = enabled
        self.refresh = refresh
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.cancel()
        watcher = nil
    }

    func check() {
        check(fromWatch: false)
    }

    private func check(fromWatch: Bool) {
        checkPending = false
        guard enabled() else { return }
        defer { ensureWatcher() }
        if fromWatch, let lastRestore, Date().timeIntervalSince(lastRestore) < Self.minimumRestoreInterval { return }
        if case .installed(replacedOther: true) = refresh() {
            lastRestore = Date()
            Self.logger.notice("AgentMeter: hook helper restored: another build's copy had replaced it")
        }
    }

    private func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchDebounce) { [weak self] in
            MainActor.assumeIsolated { self?.check(fromWatch: true) }
        }
    }

    /// The watch on the helper's directory; reopened after the directory
    /// was replaced, and not created by the watch itself.
    private func ensureWatcher() {
        if let watcher, !watcher.isCancelled { return }
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) { source.cancel() }
                self?.scheduleCheck()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}
