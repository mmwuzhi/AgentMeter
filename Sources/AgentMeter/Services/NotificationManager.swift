import Foundation
import UserNotifications

/// Posts a system notification when a provider's quota drops to/below the user's
/// critical threshold. Dedups per window so each depletion notifies once and
/// re-arms only after the window climbs back above the threshold (e.g. a reset).
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var authorized = false
    private var requested = false
    private var notified: Set<String> = []   // "provider:windowId" already alerted

    private override init() { super.init() }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true
    }

    /// Clamped to a sane 1…99 so a bad default can't silence or spam alerts.
    private var threshold: Double {
        let v = UserDefaults.standard.object(forKey: "alertThresholdPercent") as? Double ?? 10
        return max(1, min(99, v))
    }

    /// UNUserNotificationCenter traps when there is no app bundle (bare `make debug`
    /// binary), so every entry point guards on a bundle identifier.
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorizationIfNeeded() {
        guard !requested, hasBundle else { return }
        requested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self   // so banners show even while the app is active
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Evaluate one provider's windows and notify on downward threshold crossings.
    func evaluate(provider: Provider, windows: [QuotaWindow]) {
        guard enabled else { return }
        let t = threshold
        for w in windows {
            let key = "\(provider.rawValue):\(w.id)"
            if w.remainingPercent <= t {
                guard !notified.contains(key) else { continue }
                // Only mark as notified once we've actually managed to post —
                // otherwise an alert that fires before authorization lands would
                // be suppressed forever.
                if post(provider: provider, window: w) { notified.insert(key) }
            } else {
                notified.remove(key)   // re-arm for the next depletion
            }
        }
    }

    @discardableResult
    private func post(provider: Provider, window: QuotaWindow) -> Bool {
        guard authorized, hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) quota low"
        let pct = Int(window.remainingPercent.rounded())
        if let reset = window.resetsAt {
            content.body = "\(window.label): \(pct)% left · resets \(QuotaRow.relative(reset))"
        } else {
            content.body = "\(window.label): \(pct)% left"
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "agentmeter.\(provider.rawValue).\(window.id).\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    // Show the banner + play sound even when AgentMeter is the active app
    // (popover or Settings open), instead of silently swallowing it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
