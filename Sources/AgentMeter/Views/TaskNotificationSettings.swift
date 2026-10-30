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
        Section("Claude Code tasks: macOS banners") {
            Toggle("Show a banner when a task finishes", isOn: $completed)
            Toggle("Show a banner when a task fails", isOn: $failed)
            Toggle("Show a banner when a session needs input", isOn: $waiting)
            Text("These switches only turn macOS notification banners on or off. Either way AgentMeter keeps the outcome in its history, and while the session is open its row in the Sessions list shows how its last turn ended. A task whose background work was still running at the last check is never sent as a banner.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show session titles in banners", isOn: $showsSessionTitle)
            Text("Banners name the session as the Sessions list does. Unless you renamed the session, its title is Claude's summary of your first prompt, and banners can appear on the lock screen; off, they show the project and a short session id instead. AgentMeter keeps each task's session title in its history on this Mac either way. Applies to banners sent from now on.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Claude Code tasks: headless runs") {
            Toggle("Notify about headless runs", isOn: $notifiesHeadlessRuns)
            Text("Runs Claude Code itself marks as unattended: claude -p, the Agent SDK, and Claude Code started from inside another session, such as a batch job's helpers. Off, they get no banner: what becomes of them is kept in AgentMeter's history (and a run still open shows it on its row like any session). On, they are announced like your own sessions. Your sessions in a terminal, VS Code or the desktop app, and background sessions you start (claude --bg), are announced either way. An editor that runs Claude Code through the Agent SDK counts as unattended too: turn this on if you use one. Applies from the next finished, failed or waiting task.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("macOS notifications") {
            switch system {
            case .reading:
                Text("Reading notification settings…").foregroundStyle(.secondary)
            case .unavailable:
                Text("Not available in a development build without an app bundle.").foregroundStyle(.secondary)
            case let .loaded(settings):
                LabeledContent("Permission", value: settings.authorizationText)
                if settings.canPost {
                    LabeledContent("Alert style", value: settings.alertStyleText)
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
