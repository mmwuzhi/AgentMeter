import AppKit
import SwiftUI

/// Owns the NSStatusItem and the popover that hosts the SwiftUI MenuView.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppViewModel
    private let coordinator: RefreshCoordinator
    private let contentView = MenuBarContentView()
    private var lastLength: CGFloat = -1

    init(model: AppViewModel, coordinator: RefreshCoordinator) {
        self.model = model
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        observeModel()

        // Menu-bar title also depends on UserDefaults (which items, captions).
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func defaultsChanged() {
        Task { @MainActor in self.updateTitle() }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover)
        button.target = self
        // Stats-style live rendering: host an NSView that draws the menu-bar content
        // in its draw(_:), instead of rasterizing to a template image (which thins
        // out small/light text). The empty image makes the button reserve a frame;
        // the subview ignores hit-testing so clicks still reach the button's action.
        button.image = NSImage()
        button.imagePosition = .imageOnly
        contentView.passesClicksThrough = true
        contentView.autoresizingMask = [.width, .height]
        button.addSubview(contentView)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        let root = MenuView(
            model: model,
            onRefresh: { [weak self] in self?.coordinator.refresh() },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    /// Refresh the menubar title text when the model changes.
    private func observeModel() {
        withObservationTracking {
            // Touch everything the menu bar can show: all providers' quota and
            // usage (spend), so spend-only and mixed-provider modes refresh too.
            _ = model.codex
            _ = model.claude
            _ = model.copilot
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeModel()
            }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let elements = MenuBarLayout.activeElements(model)
        let showCaptions = UserDefaults.standard.object(forKey: "menuBarShowCaptions") as? Bool ?? true
        let summary = accessibilitySummary()
        button.toolTip = summary
        button.setAccessibilityLabel(summary)

        // Size the status item to the content, then let the view draw it live.
        let width = MenuBarContentView.width(elements: elements, showCaptions: showCaptions)
        if abs(width - lastLength) > 0.5 {
            lastLength = width
            statusItem.length = width
        }
        contentView.frame = button.bounds
        contentView.apply(elements: elements, showCaptions: showCaptions)
    }

    /// Spoken/hover summary for VoiceOver and the tooltip — the shown columns.
    private func accessibilitySummary() -> String {
        let rows = MenuBarLayout.activeSegments(model)
        guard !rows.isEmpty else { return "AgentMeter — no items shown" }
        return "AgentMeter — " + rows.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            coordinator.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
