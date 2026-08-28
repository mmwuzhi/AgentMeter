import AgentStatusCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppViewModel()
    private var coordinator: RefreshCoordinator!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Keep status-item gaps tight through AppKit's own per-app spacing keys.
        // Drawing outside the declared length is clipped on non-active displays.
        UserDefaults.standard.register(defaults: [
            "NSStatusItemSpacing": 6,
            "NSStatusItemSelectionPadding": 6,
            // Sparkline/heatmap cells rely on hover tooltips for their numbers;
            // the ~1s system default feels broken there. Milliseconds.
            "NSInitialToolTipDelay": 250,
        ])

        // Repair launch-at-login if an update (ad-hoc signature change) silently dropped it.
        LoginItem.reconcile()

        AgentStatusStore.sweepStale(olderThan: 12 * 3600)
        if UserDefaults.standard.bool(forKey: "statusHooksEnabled") {
            _ = ClaudeHookInstaller.installManagedCLI()
            _ = try? ClaudeHookInstaller.install()
        }

        // Start Sparkle's background update checks (relocated to Settings → manual check).
        _ = UpdaterController.shared
        coordinator = RefreshCoordinator(viewModel: model)
        statusController = StatusItemController(model: model, coordinator: coordinator)
        NotificationManager.shared.activate()
        NotificationManager.shared.onOpenProvider = { [weak self] provider in
            self?.statusController.showPopover(for: provider)
        }
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
