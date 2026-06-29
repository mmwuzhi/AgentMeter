import Foundation
import ServiceManagement

/// Toggle launch-at-login via the modern SMAppService API (macOS 13+).
///
/// Ad-hoc signed builds get a fresh code identity on every update, so macOS may not
/// recognize a refreshed bundle as the same login item: the previous registration can
/// linger as an orphaned/disabled record, after which a plain `register()` either throws
/// or creates a duplicate. Two mitigations here:
///   1. `apply` clears a stale record (`unregister`) before retrying `register()`.
///   2. `reconcile` realigns the actual status with the user's stored intent on launch,
///      quietly re-registering when an update silently dropped the registration.
/// What we deliberately do NOT do is re-register over `.requiresApproval` — that state
/// means the user switched it off in System Settings, and fighting that is hostile.
enum LoginItem {
    /// The user's desired state. Source of truth is the same UserDefaults key SettingsView binds to.
    static var intendedEnabled: Bool {
        UserDefaults.standard.bool(forKey: "launchAtLogin")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Called from the Settings toggle (user actively flipping the switch).
    static func set(enabled: Bool) {
        apply(enabled: enabled)
    }

    /// Called once at launch. Repairs the post-update case where an ad-hoc signature change
    /// dropped the registration, without overriding a choice the user made in System Settings.
    static func reconcile() {
        let status = SMAppService.mainApp.status
        guard intendedEnabled else {
            // Wanted off; clear any stale record that is somehow still enabled.
            if status == .enabled { apply(enabled: false) }
            return
        }
        switch status {
        case .enabled:
            break // already correct
        case .notRegistered:
            apply(enabled: true) // dropped after an update → quietly re-register
        case .requiresApproval:
            NSLog("AgentMeter: launch-at-login needs approval in System Settings → General → Login Items.")
        default:
            // .notFound (e.g. app not in a launchable location / translocated) and future cases.
            NSLog("AgentMeter: launch-at-login unavailable (status=\(status.rawValue)); is AgentMeter in /Applications?")
        }
    }

    private static func apply(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .enabled { return }
                do {
                    try service.register()
                } catch {
                    // A stale/orphaned record from a prior (differently-signed) build can make
                    // register() fail. Drop it and retry once.
                    try? service.unregister()
                    try service.register()
                }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            let action = enabled ? "register" : "unregister"
            NSLog("AgentMeter: login item \(action) failed: \(error.localizedDescription) (status=\(service.status.rawValue)). "
                + "If this persists, remove AgentMeter under System Settings → General → Login Items, then toggle again.")
        }
    }
}
