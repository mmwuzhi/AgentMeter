import SwiftUI
import AppKit

struct SettingsView: View {
    let model: AppViewModel

    var body: some View {
        TabView {
            MenuBarSettings(model: model)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 540)
        .onAppear {
            // Accessory apps open Settings inactive, which desaturates control
            // accents so on/off look identical. Activate so the window becomes key.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApp.windows.first { $0.title == "AgentMeter Settings" }?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// iStat-style menu-bar customizer: drag chips between the Visible and Hidden zones
/// (native AppKit drag with animated reordering, like Ice), plus the captions toggle.
private struct MenuBarSettings: View {
    let model: AppViewModel

    @AppStorage("menuBarShowCaptions") private var showCaptions = true
    @State private var selectedSlot: MenuBarSlot = .codex

    init(model: AppViewModel) {
        self.model = model
    }

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Show captions", isOn: $showCaptions)
                Text("Each visible provider becomes its own menu-bar icon with its own popover and fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider Fields") {
                Picker("Provider", selection: $selectedSlot) {
                    ForEach(MenuBarSlot.allCases) { slot in
                        Text(slot.displayName).tag(slot)
                    }
                }
                .pickerStyle(.segmented)
                SlotItemSettings(model: model, slot: selectedSlot, showCaptions: showCaptions)
                    .id(selectedSlot.rawValue)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SlotItemSettings: View {
    let model: AppViewModel
    let slot: MenuBarSlot
    let showCaptions: Bool
    @StateObject private var coordinator: LayoutEditorCoordinator

    init(model: AppViewModel, slot: MenuBarSlot, showCaptions: Bool) {
        self.model = model
        self.slot = slot
        self.showCaptions = showCaptions
        _coordinator = StateObject(wrappedValue: LayoutEditorCoordinator(model: model, slot: slot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(slot.displayName) fields")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            LayoutZoneView(zone: .visible, backing: coordinator, signature: "\(showCaptions)")
                .frame(height: 46)
            Text("Drag fields to reorder. Empty visible fields hides that provider icon.")
                .font(.caption).foregroundStyle(.secondary)
            LayoutZoneView(zone: .hidden, backing: coordinator, signature: "\(showCaptions)")
                .frame(height: 46)
        }
    }
}

private struct AlertSettings: View {
    @AppStorage("alertsEnabled") private var alertsEnabled = true
    @AppStorage("quotaRecoveryNotificationsEnabled") private var quotaRecoveryNotificationsEnabled = true
    @AppStorage("warnThresholdPercent") private var warnThresholdPercent = 25.0
    @AppStorage("alertThresholdPercent") private var alertThresholdPercent = 10.0

    var body: some View {
        Form {
            Section("Alerts") {
                thresholdField("Warn (yellow dot) at", $warnThresholdPercent)
                thresholdField("Critical (red dot) at", $alertThresholdPercent)
                Toggle("Notify when critical", isOn: $alertsEnabled)
                Toggle("Notify when quota recovers after critical", isOn: $quotaRecoveryNotificationsEnabled)
                    .disabled(!alertsEnabled)
                Text("A yellow then red dot appears as quota runs low. Critical notifications fire once, and recovery notifications fire only after a critical window resets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A typed whole-number percent (1…99).
    private func thresholdField(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: value.wrappedValue) { _, new in
                        let clamped = min(99, max(1, new.rounded()))
                        if clamped != new { value.wrappedValue = clamped }
                    }
                Text("%").foregroundStyle(.secondary)
            }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("refreshIntervalSeconds") private var refreshIntervalSeconds = 60.0

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(enabled: on) }
                Picker("Refresh every", selection: $refreshIntervalSeconds) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
            }
            Section("Software Update") {
                LabeledContent("Version", value: Self.appVersion)
                LabeledContent("Check for updates") {
                    Button("Check Now…") { UpdaterController.shared.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// e.g. "1.4.2 (37)" from the bundle, falling back gracefully for dev builds.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
