import AppKit
import SwiftUI

/// Opens the SwiftUI `Settings` scene from AppKit contexts (status-item context
/// menus). macOS 14 removed the `showSettingsWindow:` selector path, so this
/// hosts a transient invisible window whose root view captures the sanctioned
/// `openSettings` environment action and fires it once.
@MainActor
enum SettingsOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = NSHostingView(rootView: Opener { [weak window] in
            window?.close()
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
