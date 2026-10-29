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
    // Not rendered here, but `MenuBarContentView.apply` reads it, so it has to
    // reach the preview zones' rebuild signature or the chips keep the old fill
    // direction until some other display state changes.
    @AppStorage(QuotaDisplay.defaultsKey) private var quotaShowsUsed = false
    // Same for the caption mode and the countdown colours: the chips are drawn
    // from them, so they go into the signature as well.
    @AppStorage(ResetCaptionMode.defaultsKey) private var resetCaptionMode = ResetCaptionMode.window
    @AppStorage(ResetCaptionColors.defaultsKey) private var resetColors = ""
    @State private var selectedSlot: MenuBarSlot = .codex

    init(model: AppViewModel) {
        self.model = model
    }

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Show captions", isOn: $showCaptions)
                Picker("Claude quota caption", selection: $resetCaptionMode) {
                    ForEach(ResetCaptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Window shows 5h or 7d. Countdown shows the time left until that quota resets. Both shows the two together.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Each visible provider becomes its own menu-bar icon with its own popover and fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider Fields") {
                Picker("Provider", selection: $selectedSlot) {
                    ForEach(MenuBarSlot.alphabetical) { slot in
                        Text(slot.displayName).tag(slot)
                    }
                }
                .pickerStyle(.segmented)
                SlotItemSettings(
                    model: model,
                    slot: selectedSlot,
                    displaySignature: MenuBarPreviewSignature.make(
                        showCaptions: showCaptions, quotaShowsUsed: quotaShowsUsed,
                        resetCaptionMode: resetCaptionMode, resetColors: resetColors)
                )
                .id(selectedSlot.rawValue)
            }
        }
        .formStyle(.grouped)
    }
}

/// Every display default a preview chip's rendering depends on, in one string:
/// a new preference is a new segment here, not a new parameter downstream.
enum MenuBarPreviewSignature {
    static func make(showCaptions: Bool, quotaShowsUsed: Bool,
                     resetCaptionMode: ResetCaptionMode, resetColors: String) -> String {
        "\(showCaptions)-\(quotaShowsUsed)-\(resetCaptionMode.rawValue)-\(resetColors)"
    }
}

private struct SlotItemSettings: View {
    let model: AppViewModel
    let slot: MenuBarSlot
    /// Every display default a chip's rendering depends on, joined. Chips are
    /// rebuilt only when this changes, so a preference missing from it renders
    /// stale previews.
    let displaySignature: String
    @AppStorage(ResetCaptionMode.defaultsKey) private var resetCaptionMode = ResetCaptionMode.window
    @AppStorage(ResetCaptionColors.defaultsKey) private var resetColors = ""
    @StateObject private var coordinator: LayoutEditorCoordinator

    init(model: AppViewModel, slot: MenuBarSlot, displaySignature: String) {
        self.model = model
        self.slot = slot
        self.displaySignature = displaySignature
        _coordinator = StateObject(wrappedValue: LayoutEditorCoordinator(model: model, slot: slot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(slot.displayName) fields")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            LayoutZoneView(zone: .visible, backing: coordinator, signature: displaySignature)
                .frame(height: 46)
            Text("Drag fields to reorder. Empty visible fields hides that provider icon.")
                .font(.caption).foregroundStyle(.secondary)
            LayoutZoneView(zone: .hidden, backing: coordinator, signature: displaySignature)
                .frame(height: 46)
            if slot == .claude, resetCaptionMode != .window {
                countdownColors
            }
        }
    }

    /// One colour per quota window, so two weeklies can differ. The window's
    /// identity keys it, so reordering the fields above never moves a colour.
    @ViewBuilder
    private var countdownColors: some View {
        let windows = model.claude.quota.windows.filter { $0.isOneTimeCredit != true }
        if !windows.isEmpty {
            Divider()
            Text("Countdown colors")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(windows) { window in
                let key = ResetCaptionColors.key(provider: .claude, windowID: window.id)
                LabeledContent(window.label) {
                    HStack(spacing: 8) {
                        ColorPicker("", selection: colorBinding(for: key), supportsOpacity: false)
                            .labelsHidden()
                        Button("Default") { setColor(nil, for: key) }
                            .disabled(ResetCaptionColors.tint(forKey: key, in: resetColors) == nil)
                    }
                }
            }
            Text("Default follows the system text color.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func colorBinding(for key: String) -> Binding<Color> {
        Binding(
            get: {
                guard let tint = ResetCaptionColors.tint(forKey: key, in: resetColors) else {
                    return Color(nsColor: .labelColor)
                }
                return Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue)
            },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                setColor(ResetCaptionColors.hex(red: rgb.redComponent, green: rgb.greenComponent,
                                                blue: rgb.blueComponent), for: key)
            }
        )
    }

    private func setColor(_ hex: String?, for key: String) {
        var colors = ResetCaptionColors.decode(resetColors)
        colors[key] = hex
        resetColors = colors.isEmpty ? "" : ResetCaptionColors.encode(colors)
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
            TaskNotificationSettingsSections()
        }
        .formStyle(.grouped)
        // Warn must stay at or above critical. Adjust the *other* field so the
        // one being edited keeps the typed value instead of snapping back.
        .onChange(of: warnThresholdPercent) { _, warn in
            if alertThresholdPercent > warn { alertThresholdPercent = warn }
        }
        .onChange(of: alertThresholdPercent) { _, critical in
            if warnThresholdPercent < critical { warnThresholdPercent = critical }
        }
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
    @AppStorage("statusHooksEnabled") private var statusHooksEnabled = false
    @AppStorage(QuotaDisplay.defaultsKey) private var quotaShowsUsed = false
    @State private var hookMessage: String?

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
            // Lives here, not under Menu Bar: it turns the popover rows over too,
            // and the two surfaces deliberately share one switch.
            Section("Quota Display") {
                Picker("Show quota as", selection: $quotaShowsUsed) {
                    Text("Remaining").tag(false)
                    Text("Used").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Remaining counts down to the limit (\"15 % left\"); used fills toward it (\"85 % used\"). Applies to the popover rows and the menu bar together. Colors and alerts always follow what is left.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code Status") {
                Toggle(
                    "Show live session status",
                    isOn: Binding(
                        get: { statusHooksEnabled },
                        set: { applyHooks($0) }
                    )
                )
                Text("Installs reversible hooks in ~/.claude/settings.json so sessions can report working, waiting, idle, or error state.")
                    .font(.caption).foregroundStyle(.secondary)
                if let hookMessage {
                    Text(hookMessage).font(.caption).foregroundStyle(.secondary)
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

    private func applyHooks(_ enabled: Bool) {
        do {
            if enabled {
                guard ClaudeHookInstaller.installManagedCLI() != nil else {
                    throw ClaudeHookInstaller.InstallError.helperUnavailable
                }
                _ = try ClaudeHookInstaller.install()
                hookMessage = "Installed. Restart running Claude Code sessions so they load the hooks."
            } else {
                _ = try ClaudeHookInstaller.remove()
                hookMessage = "Removed AgentMeter hooks from settings.json."
            }
            statusHooksEnabled = enabled
        } catch {
            hookMessage = "Couldn't update settings.json: \(error.localizedDescription)"
        }
    }

    /// e.g. "1.4.2 (37)" from the bundle, falling back gracefully for dev builds.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
