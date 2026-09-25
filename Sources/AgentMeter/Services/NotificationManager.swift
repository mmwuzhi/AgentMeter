import Foundation
import UserNotifications

@MainActor
protocol NotificationAuthorizationCenter: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    /// Delivery goes through the same seam as the permission request, so a
    /// test can see what would have been posted without touching the real
    /// center.
    func post(_ request: UNNotificationRequest)
}

extension UNUserNotificationCenter: NotificationAuthorizationCenter {
    func post(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }
}

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
                   hasRecoveredAfterReset(previousReset: state.criticalResetAt[key], now: now) {
                    if recoveryEnabled {
                        events.append(.recovered(provider: provider, window: window))
                    }
                    state.criticalNotified.remove(key)
                    state.criticalResetAt.removeValue(forKey: key)
                }
            }
        }
        return events
    }

    private static func key(provider: Provider, windowID: String) -> String {
        "\(provider.rawValue):\(windowID)"
    }

    private static func hasRecoveredAfterReset(previousReset: Date?, now: Date) -> Bool {
        guard let previousReset else { return false }
        return previousReset <= now
    }
}

/// Posts a system notification when a provider's quota drops to/below the user's
/// critical threshold. Dedups per window so each depletion notifies once and
/// re-arms only after the window climbs back above the threshold (e.g. a reset).
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let authorizationCenter: any NotificationAuthorizationCenter
    private let bundleIdentifier: () -> String?
    private(set) var authorized = false
    private(set) var requested = false
    private var notificationState = QuotaNotificationState()

    /// Invoked on the main actor when the user taps a quota notification.
    var onOpenProvider: ((Provider) -> Void)?

    private override init() {
        authorizationCenter = UNUserNotificationCenter.current()
        bundleIdentifier = { Bundle.main.bundleIdentifier }
        super.init()
    }

    init(
        authorizationCenter: any NotificationAuthorizationCenter,
        bundleIdentifier: @escaping () -> String?
    ) {
        self.authorizationCenter = authorizationCenter
        self.bundleIdentifier = bundleIdentifier
        super.init()
    }

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
    private var hasBundle: Bool { bundleIdentifier() != nil }

    /// Become the notification-center delegate without asking for permission,
    /// so taps on already-delivered notifications route back even before (or
    /// without) an authorization request.
    func activate() {
        guard hasBundle else { return }
        authorizationCenter.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        guard !requested, hasBundle else { return }
        requested = true
        authorizationCenter.delegate = self   // so banners show even while the app is active
        authorized = (try? await authorizationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// The windows each provider last handed to `evaluate`. The permission
    /// prompt below can stay open for hours, and the reading captured before
    /// it may have reset or recovered by the time it resolves; the deferred
    /// pass evaluates these instead, so it never notifies on a stale window
    /// or stores its old `resetsAt` (which would post a false recovery next).
    private var latestWindows: [Provider: [QuotaWindow]] = [:]

    /// Evaluate one provider's windows and notify on downward threshold crossings.
    func evaluate(provider: Provider, windows: [QuotaWindow]) {
        latestWindows[provider] = windows
        // Ask for permission at the moment the first alert would actually fire,
        // instead of ambushing the user at launch. Denial sets `requested`, so
        // this runs at most once.
        if !requested, hasBundle, wouldNotify(provider: provider, windows: windows) {
            Task { @MainActor in
                await requestAuthorizationIfNeeded()
                self.evaluate(provider: provider, windows: self.latestWindows[provider] ?? windows)
            }
            return
        }
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

    /// Dry-runs the policy on a copy of the dedup state: would this evaluation
    /// deliver anything if permission were already granted?
    private func wouldNotify(provider: Provider, windows: [QuotaWindow]) -> Bool {
        var stateCopy = notificationState
        return !QuotaNotificationPolicy.evaluate(
            provider: provider,
            windows: windows,
            threshold: threshold,
            alertsEnabled: enabled,
            recoveryEnabled: recoveryEnabled,
            canDeliver: true,
            state: &stateCopy
        ).isEmpty
    }

    @discardableResult
    private func postCritical(provider: Provider, window: QuotaWindow) -> Bool {
        guard authorized, hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) quota low"
        content.body = Self.criticalBody(for: window)
        content.sound = .default
        content.userInfo = ["provider": provider.rawValue]
        let request = UNNotificationRequest(
            identifier: "agentmeter.\(provider.rawValue).\(window.id).\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        authorizationCenter.post(request)
        return true
    }

    @discardableResult
    private func postRecovered(provider: Provider, window: QuotaWindow) -> Bool {
        guard authorized, hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) quota recovered"
        content.body = Self.recoveredBody(for: window)
        content.sound = .default
        content.userInfo = ["provider": provider.rawValue]
        let request = UNNotificationRequest(
            identifier: "agentmeter.\(provider.rawValue).\(window.id).recovered.\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        authorizationCenter.post(request)
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

    // Tapping a quota notification opens that provider's popover instead of
    // doing nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? response.notification.request.content.userInfo["provider"] as? String
            : nil
        completionHandler()
        guard let raw else { return }
        Task { @MainActor in
            if let provider = Provider(rawValue: raw) {
                self.onOpenProvider?(provider)
            }
        }
    }
}
