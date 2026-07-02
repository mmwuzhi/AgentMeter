import Foundation
import UserNotifications

struct QuotaNotificationState: Equatable {
    var criticalNotified: Set<String> = []
    var criticalResetAt: [String: Date] = [:]
}

enum QuotaNotificationEvent: Equatable {
    case critical(provider: Provider, window: QuotaWindow)
    case recovered(provider: Provider, window: QuotaWindow)
}

enum QuotaNotificationPolicy {
    static func evaluate(
        provider: Provider,
        windows: [QuotaWindow],
        now: Date = Date(),
        threshold: Double,
        alertsEnabled: Bool,
        recoveryEnabled: Bool,
        canDeliver: Bool,
        state: inout QuotaNotificationState
    ) -> [QuotaNotificationEvent] {
        guard alertsEnabled else {
            state = QuotaNotificationState()
            return []
        }
        guard canDeliver else { return [] }

        var events: [QuotaNotificationEvent] = []
        for window in windows {
            let key = Self.key(provider: provider, windowID: window.id)
            if window.remainingPercent <= threshold {
                guard !state.criticalNotified.contains(key) else { continue }
                state.criticalNotified.insert(key)
                if let reset = window.resetsAt {
                    state.criticalResetAt[key] = reset
                } else {
                    state.criticalResetAt.removeValue(forKey: key)
                }
                events.append(.critical(provider: provider, window: window))
            } else {
                if state.criticalNotified.contains(key),
                   recoveryEnabled,
                   hasRecoveredAfterReset(window: window, previousReset: state.criticalResetAt[key], now: now) {
                    events.append(.recovered(provider: provider, window: window))
                }
                state.criticalNotified.remove(key)
                state.criticalResetAt.removeValue(forKey: key)
            }
        }
        return events
    }

    private static func key(provider: Provider, windowID: String) -> String {
        "\(provider.rawValue):\(windowID)"
    }

    private static func hasRecoveredAfterReset(
        window: QuotaWindow,
        previousReset: Date?,
        now: Date
    ) -> Bool {
        guard let previousReset else { return false }
        if previousReset <= now { return true }
        guard let currentReset = window.resetsAt else { return false }
        return currentReset.timeIntervalSince(previousReset) > 1
    }
}

/// Posts a system notification when a provider's quota drops to/below the user's
/// critical threshold. Dedups per window so each depletion notifies once and
/// re-arms only after the window climbs back above the threshold (e.g. a reset).
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var authorized = false
    private var requested = false
    private var notificationState = QuotaNotificationState()

    private override init() { super.init() }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true
    }

    private var recoveryEnabled: Bool {
        UserDefaults.standard.object(forKey: "quotaRecoveryNotificationsEnabled") as? Bool ?? true
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
        let events = QuotaNotificationPolicy.evaluate(
            provider: provider,
            windows: windows,
            threshold: threshold,
            alertsEnabled: enabled,
            recoveryEnabled: recoveryEnabled,
            canDeliver: authorized && hasBundle,
            state: &notificationState
        )
        for event in events {
            switch event {
            case let .critical(provider, window):
                postCritical(provider: provider, window: window)
            case let .recovered(provider, window):
                postRecovered(provider: provider, window: window)
            }
        }
    }

    @discardableResult
    private func postCritical(provider: Provider, window: QuotaWindow) -> Bool {
        guard authorized, hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) quota low"
        content.body = Self.criticalBody(for: window)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "agentmeter.\(provider.rawValue).\(window.id).\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    @discardableResult
    private func postRecovered(provider: Provider, window: QuotaWindow) -> Bool {
        guard authorized, hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) quota recovered"
        content.body = Self.recoveredBody(for: window)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "agentmeter.\(provider.rawValue).\(window.id).recovered.\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    nonisolated static func criticalBody(for window: QuotaWindow) -> String {
        let pct = Int(window.remainingPercent.rounded())
        guard let reset = window.resetsAt else {
            return "\(window.label): \(pct)% left"
        }
        let verb = window.isOneTimeCredit == true ? "expires" : "resets"
        return "\(window.label): \(pct)% left · \(verb) \(QuotaRow.relative(reset))"
    }

    nonisolated static func recoveredBody(for window: QuotaWindow) -> String {
        let pct = Int(window.remainingPercent.rounded())
        guard let reset = window.resetsAt else {
            return "\(window.label): \(pct)% left"
        }
        let prefix = window.isOneTimeCredit == true ? "expires" : "next reset"
        return "\(window.label): \(pct)% left · \(prefix) \(QuotaRow.relative(reset))"
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
