import AppKit
import SwiftUI

/// Shows the SwiftUI `Settings` scene where the user can see it, from AppKit
/// contexts (the popover's Settings button, the status-item context menu).
/// An open window is brought forward as it is, keeping its frame and tab;
/// only a closed one goes through the sanctioned `openSettings` action, which
/// macOS 14 left as the only path (the `showSettingsWindow:` selector is gone)
/// and which needs a view to read it from: a transient invisible window
/// whose root view captures it and fires it once.
@MainActor
enum SettingsOpener {
    /// SwiftUI's identifier and frame autosave name for the Settings window.
    /// Its title is the selected tab's ("Menu Bar"), so it cannot be found by title.
    static let windowIdentifier = "com_apple_SwiftUI_Settings_window"

    enum Plan: Equatable {
        case bringForward
        case open
    }

    static func open() {
        let window = settingsWindow(in: NSApp.windows)
        let plan = plan(for: window)
        // Before the activation: activating first can already switch to the
        // Space the window was left on ("switch to a Space with open windows").
        if plan == .bringForward { window?.collectionBehavior.insert(.moveToActiveSpace) }
        // An accessory app's windows open inactive, behind the active app and
        // with desaturated control accents; the click that got here is ours,
        // so the activation is granted.
        NSApp.activate()
        switch plan {
        case .bringForward:
            if let window { bringForward(window) }
        case .open:
            requestSettingsScene()
        }
    }

    /// SwiftUI puts the Settings window on screen at launch, before the
    /// delegate's `applicationDidFinishLaunching`, in a binary that records
    /// the macOS 14 SDK, which is what SwiftPM's build stamps (`otool -l`,
    /// LC_BUILD_VERSION; a probe linked with the real SDK recorded shows
    /// nothing). Nobody asked for that window, and left open behind other
    /// windows or on another display it made Settings seem impossible to
    /// find. Called first thing in `applicationDidFinishLaunching`; the flush
    /// hands the hide to the window server now instead of after the rest of
    /// the launch work (on screen about 0.2–0.3 s instead of 0.5 s).
    static func withdrawLaunchPresentation() {
        guard let window = settingsWindow(in: NSApp.windows), window.isVisible else { return }
        window.orderOut(nil)
        CATransaction.flush()
    }

    static func settingsWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first {
            $0.identifier?.rawValue == windowIdentifier || $0.frameAutosaveName == windowIdentifier
        }
    }

    /// Open, even minimized: reuse it. Closed (SwiftUI may keep the window
    /// object around) or never created: let SwiftUI open the scene.
    static func plan(for window: NSWindow?) -> Plan {
        guard let window, window.isVisible || window.isMiniaturized else { return .open }
        return .bringForward
    }

    private static func bringForward(_ window: NSWindow) {
        // Join the Space the user clicked from instead of switching to the
        // one the window was left on.
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Left on a display that is gone: back onto one the user has.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private static func requestSettingsScene() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = NSHostingView(rootView: Opener { [weak window] in
            window?.close()
            // The scene's window exists once the action has run; bring it
            // forward the same way as an open one.
            DispatchQueue.main.async {
                if let settings = settingsWindow(in: NSApp.windows) { bringForward(settings) }
            }
        })
        window.orderFrontRegardless()
    }

    private struct Opener: View {
        @Environment(\.openSettings) private var openSettings
        var done: @MainActor () -> Void

        var body: some View {
            Color.clear.onAppear {
                openSettings()
                done()
            }
        }
    }
}
