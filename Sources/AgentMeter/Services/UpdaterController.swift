import Foundation
import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater. The feed URL and public key
/// come from Info.plist (SUFeedURL / SUPublicEDKey). If those aren't configured
/// yet (fresh checkout, no appcast hosted), the updater is not started so the
/// app launches cleanly; "Check for Updates" then explains how to enable it.
@MainActor
final class UpdaterController {
    /// Shared so the menu-bar launch path and the Settings scene drive the same
    /// Sparkle updater. Referencing it at launch starts background update checks.
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary
        let feed = (info?["SUFeedURL"] as? String) ?? ""
        let key = (info?["SUPublicEDKey"] as? String) ?? ""
        let configured = feed.hasPrefix("http") && !key.isEmpty && !key.contains("REPLACE")
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
        } else {
            let alert = NSAlert()
            alert.messageText = "Updates not configured"
            alert.informativeText = "Set SUFeedURL and SUPublicEDKey in Info.plist (generate keys with Sparkle's generate_keys) and host an appcast.xml. See README."
            alert.runModal()
        }
    }
}
