import SwiftUI

@main
struct AgentMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppDelegate.registerAppKitDefaults()
    }

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}
