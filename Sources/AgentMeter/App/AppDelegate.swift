import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppViewModel()
    private var coordinator: RefreshCoordinator!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Repair launch-at-login if an update (ad-hoc signature change) silently dropped it.
        LoginItem.reconcile()

        // Start Sparkle's background update checks (relocated to Settings → manual check).
        _ = UpdaterController.shared
        coordinator = RefreshCoordinator(viewModel: model)
        statusController = StatusItemController(model: model, coordinator: coordinator)
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
