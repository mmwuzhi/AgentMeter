import Foundation
import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater. The feed URL and public key
/// come from Info.plist (SUFeedURL / SUPublicEDKey). If those aren't configured
/// yet (fresh checkout, no appcast hosted), the updater is not started so the
/// app launches cleanly; "Check for Updates" then explains how to enable it.
/// A release candidate (`UpdatePolicy.offInTestBuild`) never starts it.
@MainActor
final class UpdaterController {
    /// Shared so the menu-bar launch path and the Settings scene drive the same
    /// Sparkle updater. Referencing it at launch starts background update checks.
    static let shared = UpdaterController()

    let policy: UpdatePolicy
    private let controller: SPUStandardUpdaterController?

    init() {
        policy = UpdatePolicy.decide(from: Bundle.main.infoDictionary)
        controller = policy == .sparkle
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        switch policy {
        case .sparkle:
            controller?.checkForUpdates(nil)
        case .offInTestBuild:
            let alert = NSAlert()
            alert.messageText = "Updates are off"
            alert.informativeText = UpdatePolicy.testBuildNotice
            alert.runModal()
        case .notConfigured:
            let alert = NSAlert()
            alert.messageText = "Updates not configured"
            alert.informativeText = "Set SUFeedURL and SUPublicEDKey in Info.plist (generate keys with Sparkle's generate_keys) and host an appcast.xml. See README."
            alert.runModal()
        }
    }
}
