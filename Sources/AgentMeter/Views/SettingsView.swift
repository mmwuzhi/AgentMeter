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
        // Activation and bringing the window forward live in `SettingsOpener`,
        // which every way in goes through. Not here in `onAppear`: that runs
        // when SwiftUI builds this view at launch, where it activated the app
        // and made the unasked launch window key, and never again for a
        // window that is already open.
    }
}

/// iStat-style menu-bar customizer: drag chips between the Visible and Hidden zones
/// (native AppKit drag with animated reordering, like Ice), plus the captions toggle.
struct MenuBarSettings: View {
    let model: AppViewModel

    @AppStorage("menuBarShowCaptions") private var showCaptions = true
    // Not rendered here, but `MenuBarContentView.apply` reads it, so it has to
    // reach the preview zones' rebuild signature or the chips keep the old fill
    // direction until some other display state changes.
    @AppStorage(QuotaDisplay.defaultsKey) private var quotaShowsUsed = false
    // Edited in the Claude Quota Labels section, and the chips are drawn from
    // them, so they go into the signature as well.
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
                Text("Each visible provider becomes its own menu-bar icon with its own popover and fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ClaudeQuotaLabelSettings(windows: model.claude.quota.windows,
                                     mode: $resetCaptionMode, colors: $resetColors)
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

/// What a Claude quota column's caption says, and the colour of each quota's
/// countdown, together: the colours mean nothing without a countdown, so they
/// sit right under the mode and are hidden in Period mode, the default, where
/// they would only be clutter. Hiding them stores nothing: a colour chosen
/// earlier is kept and applies again with Countdown or Both.
struct ClaudeQuotaLabelSettings: View {
    /// Claude's quota windows; one colour row each.
    let windows: [QuotaWindow]
    @Binding var mode: ResetCaptionMode
    /// `ResetCaptionColors` JSON, as stored.
    @Binding var colors: String
    var panel: CountdownColorPanel = .shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section("Claude Quota Labels") {
            Picker("Show", selection: $mode) {
                ForEach(ResetCaptionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("Period shows \(ResetCaptionMode.window.example), Countdown the time left until that quota resets (\(ResetCaptionMode.countdown.example)), Both the two together (\(ResetCaptionMode.both.example)).")
                .font(.caption).foregroundStyle(.secondary)
            countdownColors
        }
        // The panel stops writing when the mode stops showing countdowns or
        // the Settings window closes (`CountdownColorPanel.edit`), not on
        // `onDisappear`, which a grouped Form also sends for rows scrolled away.
        .onChange(of: mode) { _, mode in
            if mode == .window { panel.stop() }
        }
    }

    /// One colour per quota window, so two weeklies can differ. The window's
    /// identity keys it, so reordering the fields never moves a colour.
    @ViewBuilder
    private var countdownColors: some View {
        let windows = windows.filter { $0.isOneTimeCredit != true }
        if mode != .window, !windows.isEmpty {
            ForEach(windows) { window in
                let key = ResetCaptionColors.key(provider: .claude, windowID: window.id)
                LabeledContent("\(window.label) countdown color") {
                    colorControl(key: key, name: window.label)
                }
            }
            Text("Automatic follows the menu bar's own text color, light or dark. A custom color tints only that quota's countdown, never its percentage.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Automatic until a colour is stored: no swatch then, since a swatch of
    /// the text colour read as black having been chosen. A stored colour shows
    /// as a swatch that reopens the panel, with a way back to Automatic.
    @ViewBuilder
    private func colorControl(key: String, name: String) -> some View {
        HStack(spacing: 8) {
            if let tint = ResetCaptionColors.tint(forKey: key, in: colors) {
                Button {
                    open(key: key, name: name, from: NSColor(srgbRed: tint.red, green: tint.green,
                                                            blue: tint.blue, alpha: 1))
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                        .frame(width: 34, height: 18)
                }
                .buttonStyle(.plain)
                .help("Change the color of the \(name) countdown")
                Button("Use Automatic") {
                    panel.stop(editing: key)
                    colors = ResetCaptionColors.setting(nil, forKey: key, in: colors)
                }
            } else {
                Text("Automatic").foregroundStyle(.secondary)
                Button("Custom…") {
                    // Starts from what Automatic draws in the preview below;
                    // nothing is stored until a colour is picked in the panel.
                    open(key: key, name: name, from: colorScheme == .dark ? .white : .textColor)
                }
            }
        }
    }

    private func open(key: String, name: String, from color: NSColor) {
        panel.edit(key: key, title: "\(name) Countdown", startingAt: color,
                   until: SettingsOpener.settingsWindow(in: NSApp.windows))
    }
}

/// The shared colour panel, pointed at one quota window's countdown at a time.
/// Only a colour picked in the panel is stored. The panel reports every change
/// of its colour, its own included, so it is attached only once its starting
/// colour is set and it is on screen, and a report of the starting colour
/// itself is not taken as a pick until the user has moved off it: opening the
/// panel for a window that is Automatic leaves it Automatic. (Picking exactly
/// the starting colour therefore stores nothing, which from Automatic looks
/// the same anyway.)
@MainActor
final class CountdownColorPanel: NSObject {
    static let shared = CountdownColorPanel()

    /// The colour key (`claude:seven_day`) the panel writes to, nil when detached.
    private(set) var editingKey: String?
    private let defaults: UserDefaults
    private let colorPanel: () -> NSColorPanel
    private let show: (NSColorPanel) -> Void
    private var originalTitle: String?
    /// What the panel was opened at, until the user picks something else.
    private var startingTint: ResetTint?
    private weak var owner: NSWindow?

    init(defaults: UserDefaults = .standard,
         panel: @escaping () -> NSColorPanel = { NSColorPanel.shared },
         show: @escaping (NSColorPanel) -> Void = { $0.orderFront(nil) }) {
        self.defaults = defaults
        self.colorPanel = panel
        self.show = show
    }

    /// Opens the panel for `key`, writing to it until the mode no longer
    /// shows countdowns or `owner` (the Settings window) closes. Not on a view
    /// disappearing: a Form drops rows that scroll out of sight, and the
    /// quota windows can be briefly empty during a refresh.
    func edit(key: String, title: String, startingAt color: NSColor, until owner: NSWindow?) {
        let panel = colorPanel()
        detach(panel)
        panel.showsAlpha = false
        panel.color = color
        if originalTitle == nil { originalTitle = panel.title }
        // One panel serves every row, so it says which countdown it is for.
        panel.title = title
        show(panel)
        startingTint = Self.tint(of: color)
        editingKey = key
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        if let owner {
            self.owner = owner
            NotificationCenter.default.addObserver(self, selector: #selector(ownerWillClose(_:)),
                                                   name: NSWindow.willCloseNotification, object: owner)
        }
    }

    /// Stops writing, for any window or only for `key`; the panel stays where
    /// it is.
    func stop(editing key: String? = nil) {
        guard let editingKey, key == nil || key == editingKey else { return }
        detach(colorPanel())
    }

    @objc private func colorChanged(_ sender: Any?) {
        guard let color = (sender as? NSColorPanel)?.color else { return }
        choose(color)
    }

    /// The Settings window is going away; so does the panel it opened.
    @objc private func ownerWillClose(_ note: Notification) {
        guard editingKey != nil else { return }
        let panel = colorPanel()
        detach(panel)
        panel.orderOut(nil)
    }

    /// Stores `color` for the window being edited, as the panel does when the
    /// user picks one.
    func choose(_ color: NSColor) {
        guard let editingKey, let tint = Self.tint(of: color) else { return }
        if let startingTint {
            // The panel settling on, or converting, the colour it was given.
            if Self.isSame(tint, startingTint) { return }
            self.startingTint = nil
        }
        ResetCaptionColors.store(ResetCaptionColors.hex(red: tint.red, green: tint.green, blue: tint.blue),
                                 forKey: editingKey, in: defaults)
    }

    private func detach(_ panel: NSColorPanel) {
        panel.setTarget(nil)
        panel.setAction(nil)
        if let originalTitle { panel.title = originalTitle }
        if let owner {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: owner)
        }
        owner = nil
        startingTint = nil
        editingKey = nil
    }

    private static func tint(of color: NSColor) -> ResetTint? {
        color.usingColorSpace(.sRGB).map {
            ResetTint(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent)
        }
    }

    /// Equal once stored: within the rounding of one step in 255, which a
    /// colour-space round trip can introduce.
    private static func isSame(_ a: ResetTint, _ b: ResetTint) -> Bool {
        let step = 1.5 / 255
        return abs(a.red - b.red) <= step && abs(a.green - b.green) <= step && abs(a.blue - b.blue) <= step
    }
}

private struct SlotItemSettings: View {
    let model: AppViewModel
    let slot: MenuBarSlot
    /// Every display default a chip's rendering depends on, joined. Chips are
    /// rebuilt only when this changes, so a preference missing from it renders
    /// stale previews.
    let displaySignature: String
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
            Section("Quota") {
                thresholdField("Warn (yellow dot) at", $warnThresholdPercent)
                thresholdField("Critical (red dot) at", $alertThresholdPercent)
                Toggle("Notify when critical", isOn: $alertsEnabled)
                Toggle("Notify when quota recovers after critical", isOn: $quotaRecoveryNotificationsEnabled)
                    .disabled(!alertsEnabled)
                Text("You get one critical notification per quota window, and a recovery notice once it resets.")
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
                if UpdaterController.shared.policy == .offInTestBuild {
                    Text(UpdatePolicy.testBuildNotice)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Check for updates") {
                        Button("Check Now…") { UpdaterController.shared.checkForUpdates() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func applyHooks(_ enabled: Bool) {
        do {
            if enabled {
                guard let helper = ClaudeHookInstaller.installManagedCLI() else {
                    throw ClaudeHookInstaller.InstallError.helperUnavailable
                }
                _ = try ClaudeHookInstaller.install()
                let installed = "Installed. Restart running Claude Code sessions so they load the hooks."
                hookMessage = installed
                // The file being in place is not the helper running: macOS
                // may still refuse it (`HookHelperTrust`).
                Task {
                    let probe = await Task.detached { HookHelperTrust.probe(helper) }.value
                    guard hookMessage == installed, case .failed(let reason) = probe else { return }
                    hookMessage = "Installed, but the hook helper didn't run (\(reason)), so sessions can't report status."
                }
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
        UpdatePolicy.versionLabel(from: Bundle.main.infoDictionary)
    }
}
