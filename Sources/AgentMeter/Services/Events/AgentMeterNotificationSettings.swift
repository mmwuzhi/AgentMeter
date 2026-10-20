import Foundation
import UserNotifications

/// What System Settings says about AgentMeter's notifications, read through
/// `NotificationAuthorizationCenter.currentSettings()` when Settings is
/// shown and when AgentMeter becomes active again (the user may just have
/// changed them). AgentMeter only reports these: it never changes them, and
/// it never imitates a persistent notification with a window of its own.
struct AgentMeterNotificationSettings: Sendable, Equatable {
    enum Authorization: Sendable, Equatable {
        case notDetermined, denied, authorized, provisional, ephemeral, unknown
    }

    /// How a notification appears. `alert` is the style System Settings
    /// calls Persistent (Alerts before macOS 15): it stays until acted on.
    enum AlertStyle: Sendable, Equatable {
        case none, banner, alert, unknown
    }

    enum Setting: Sendable, Equatable {
        case enabled, disabled, notSupported, unknown
    }

    /// System Settings' Show Previews, for this app.
    enum Previews: Sendable, Equatable {
        case always, whenAuthenticated, never, unknown
    }

    var authorization: Authorization
    var alertStyle: AlertStyle
    var lockScreen: Setting
    var notificationCenter: Setting
    var previews: Previews

    init(authorization: Authorization, alertStyle: AlertStyle = .unknown, lockScreen: Setting = .unknown,
         notificationCenter: Setting = .unknown, previews: Previews = .unknown) {
        self.authorization = authorization
        self.alertStyle = alertStyle
        self.lockScreen = lockScreen
        self.notificationCenter = notificationCenter
        self.previews = previews
    }

    init(_ settings: UNNotificationSettings) {
        self.init(authorization: Self.authorization(settings.authorizationStatus),
                  alertStyle: Self.alertStyle(settings.alertStyle),
                  lockScreen: Self.setting(settings.lockScreenSetting),
                  notificationCenter: Self.setting(settings.notificationCenterSetting),
                  previews: Self.previews(settings.showPreviewsSetting))
    }

    static func authorization(_ status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }

    static func alertStyle(_ style: UNAlertStyle) -> AlertStyle {
        switch style {
        case .none: .none
        case .banner: .banner
        case .alert: .alert
        @unknown default: .unknown
        }
    }

    static func setting(_ setting: UNNotificationSetting) -> Setting {
        switch setting {
        case .enabled: .enabled
        case .disabled: .disabled
        case .notSupported: .notSupported
        @unknown default: .unknown
        }
    }

    static func previews(_ previews: UNShowPreviewsSetting) -> Previews {
        switch previews {
        case .always: .always
        case .whenAuthenticated: .whenAuthenticated
        case .never: .never
        @unknown default: .unknown
        }
    }

    var canPost: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    // MARK: - Wording for Settings

    var authorizationText: String {
        switch authorization {
        case .notDetermined: "Not asked yet"
        case .denied: "Off"
        case .authorized: "Allowed"
        case .provisional: "Allowed quietly (Notification Center only)"
        case .ephemeral: "Allowed for now"
        case .unknown: "Unknown"
        }
    }

    var alertStyleText: String {
        switch alertStyle {
        case .none: "None (Notification Center only)"
        case .banner: "Temporary (banners)"
        case .alert: "Persistent (alerts)"
        case .unknown: "Unknown"
        }
    }

    var lockScreenText: String {
        switch lockScreen {
        case .enabled:
            switch previews {
            case .always: "Shown, with text"
            case .whenAuthenticated: "Shown, text hidden until unlocked"
            case .never: "Shown, text hidden"
            case .unknown: "Shown"
            }
        case .disabled: "Not shown"
        case .notSupported, .unknown: "Unknown"
        }
    }

    /// What to do in System Settings to reach a notification that stays on
    /// screen until acted on. Nil when it already does.
    var guidance: String? {
        switch authorization {
        case .notDetermined:
            return "AgentMeter asks for permission the first time it has something to tell you."
        case .denied:
            return "Notifications are off for AgentMeter. Turn on Allow notifications in System Settings › Notifications › AgentMeter; the menu bar still counts unread tasks meanwhile."
        case .unknown:
            return nil
        case .authorized, .provisional, .ephemeral:
            break
        }
        switch alertStyle {
        case .alert:
            return nil
        case .banner:
            return "Temporary banners leave the screen after a few seconds. To keep them until you act, choose Persistent as AgentMeter's alert style in System Settings › Notifications."
        case .none:
            return "Notifications go to Notification Center without appearing on screen. Choose Persistent as AgentMeter's alert style in System Settings › Notifications to see them as they arrive."
        case .unknown:
            return nil
        }
    }

    /// Only when the lock screen shows a notification's text.
    var privacyNote: String? {
        guard canPost, lockScreen == .enabled, previews == .always else { return nil }
        return "The lock screen shows the project name (and the session title, if turned on). Set Show previews to When unlocked in System Settings › Notifications to hide it there."
    }
}
