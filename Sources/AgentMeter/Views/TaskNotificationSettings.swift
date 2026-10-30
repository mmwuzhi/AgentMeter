import AppKit
import SwiftUI

/// Settings › Alerts: which Claude Code task outcomes become macOS
/// notifications, what they call the session, and what System Settings
/// currently does with them. AgentMeter shows the system's permission and
/// style and says how to change them; it never changes them itself.
struct TaskNotificationSettingsSections: View {
    // Defaults come from the one place that defines them.
    @AppStorage(AgentMeterNotificationPreferences.taskCompletedKey)
    private var completed = AgentMeterNotificationPreferences().taskCompleted
    @AppStorage(AgentMeterNotificationPreferences.taskFailedKey)
    private var failed = AgentMeterNotificationPreferences().taskFailed
    @AppStorage(AgentMeterNotificationPreferences.taskWaitingKey)
    private var waiting = AgentMeterNotificationPreferences().taskWaiting
    @AppStorage(AgentMeterNotificationPreferences.showsSessionTitleKey)
    private var showsSessionTitle = AgentMeterNotificationPreferences().showsSessionTitle
    @AppStorage(AgentMeterNotificationPreferences.notifiesHeadlessRunsKey)
    private var notifiesHeadlessRuns = AgentMeterNotificationPreferences().notifiesHeadlessRuns

    var manager: NotificationManager = .shared
    @State private var system: SystemState = .reading

    enum SystemState: Equatable {
        case reading
        /// No app bundle (a bare development binary): the center would trap.
        case unavailable
        case loaded(AgentMeterNotificationSettings)
    }

    var body: some View {
        Section("Claude Code Tasks") {
            Toggle("Show a banner when a task finishes", isOn: $completed)
            Toggle("Show a banner when a task fails", isOn: $failed)
            Toggle("Show a banner when a session needs input", isOn: $waiting)
            Text("Turning these off stops only the banners; each session's row still shows how its last turn ended.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show session titles in banners", isOn: $showsSessionTitle)
                .help("Off, banners name the project and a short session ID instead.")
            Text("Include session titles in notifications. Titles may appear on the Lock Screen.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Notify about headless runs", isOn: $notifiesHeadlessRuns)
                .help("Doesn't affect your own sessions in a terminal, VS Code or the desktop app. An editor that runs Claude Code through the Agent SDK counts as headless.")
            Text("Also notify for unattended runs, such as claude -p and Agent SDK tasks.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("macOS Notifications") {
            switch system {
            case .reading:
                Text("Reading notification settings…").foregroundStyle(.secondary)
            case .unavailable:
                Text("Not available in a development build without an app bundle.").foregroundStyle(.secondary)
            case let .loaded(settings):
                LabeledContent("Permission", value: settings.authorizationText)
                if settings.canPost {
                    LabeledContent("Alert style", value: settings.alertStyleText)
                        .help(AgentMeterNotificationSettings.styleHelp)
                    Text(AgentMeterNotificationSettings.styleExplanation)
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Lock screen", value: settings.lockScreenText)
                }
                if let guidance = settings.guidance {
                    Text(guidance).font(.caption).foregroundStyle(.secondary)
                }
                if let privacy = settings.privacyNote {
                    Text(privacy).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Notification Settings…") { Self.openSystemSettings() }
                    if settings.authorization == .notDetermined {
                        Button("Ask for Permission…") {
                            Task {
                                await manager.requestAuthorizationIfNeeded()
                                await reload()
                            }
                        }
                    }
                }
            }
        }
        .task { await reload() }
        // Back from System Settings: show what the user just changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        guard let settings = await manager.notificationSettings() else {
            system = .unavailable
            return
        }
        system = .loaded(settings)
    }

    /// Opens AgentMeter's page in System Settings › Notifications. Nothing is
    /// changed; the user decides there.
    static func openSystemSettings(bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let url = systemSettingsURL(bundleID: bundleID) else { return }
        NSWorkspace.shared.open(url)
    }

    static func systemSettingsURL(bundleID: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        if let bundleID { components.queryItems = [URLQueryItem(name: "id", value: bundleID)] }
        return components.url
    }
}
