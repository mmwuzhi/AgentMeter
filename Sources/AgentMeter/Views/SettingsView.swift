import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showPercentInMenuBar") private var showPercentInMenuBar = true
    @AppStorage("codexFirst") private var codexFirst = true
    @AppStorage("menuBarProvider") private var menuBarProvider = "codex"

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show remaining % in menu bar", isOn: $showPercentInMenuBar)
                Picker("Menu bar shows", selection: $menuBarProvider) {
                    Text("Codex").tag("codex")
                    Text("Claude").tag("claude")
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        LoginItem.set(enabled: on)
                    }
                Picker("Order", selection: $codexFirst) {
                    Text("Codex first").tag(true)
                    Text("Claude first").tag(false)
                }
            }
            Section("Software Update") {
                LabeledContent("Check for updates") {
                    Button("Check Now…") { UpdaterController.shared.checkForUpdates() }
                }
            }
            Section("About") {
                LabeledContent("Codex quota", value: "local (app-server / session log)")
                LabeledContent("Claude quota", value: "OAuth usage API → CLI fallback")
                LabeledContent("Spend", value: "computed from local logs + LiteLLM pricing")
                Text("AgentMeter reads usage locally and reuses your existing Codex / Claude Code logins. No API keys are stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
        .onAppear {
            // Accessory apps open Settings inactive, which desaturates the toggle
            // accent so on/off look identical. Activate so the window becomes key.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApp.windows.first { $0.title == "AgentMeter Settings" }?.makeKeyAndOrderFront(nil)
            }
        }
    }
}
