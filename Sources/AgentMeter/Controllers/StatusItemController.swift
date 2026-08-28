import AppKit
import SwiftUI

/// Owns the visible set of independent NSStatusItems. Each slot behaves like an
/// iStat menu: its own menu-bar fields, its own popover, shared app data.
@MainActor
final class StatusItemController {
    private let model: AppViewModel
    private let coordinator: RefreshCoordinator
    private var slotControllers: [MenuBarSlot: StatusItemSlotController] = [:]
    private var slotOrder: [MenuBarSlot] = []

    init(model: AppViewModel, coordinator: RefreshCoordinator) {
        self.model = model
        self.coordinator = coordinator
        reconcileSlots()
        observeModel()

        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func defaultsChanged() {
        Task { @MainActor in
            self.reconcileSlots()
            self.updateAll()
        }
    }

    private func reconcileSlots() {
        let visible = MenuBarLayout.visibleSlots(model)
        guard visible != slotOrder else { return }

        for controller in slotControllers.values {
            controller.remove()
        }
        slotControllers.removeAll()
        slotOrder = visible

        for slot in visible {
            slotControllers[slot] = StatusItemSlotController(
                slot: slot,
                model: model,
                coordinator: coordinator,
                closeOthers: { [weak self] activeSlot in
                    self?.closePopovers(except: activeSlot)
                }
            )
        }
        updateAll()
    }

    /// Refresh the menubar text when the model changes.
    private func observeModel() {
        withObservationTracking {
            _ = model.codex
            _ = model.claude
            _ = model.copilot
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeModel()
            }
        }
        updateAll()
    }

    private func updateAll() {
        for slot in slotOrder {
            slotControllers[slot]?.updateTitle()
        }
    }

    private func closePopovers(except activeSlot: MenuBarSlot) {
        for (slot, controller) in slotControllers where slot != activeSlot {
            controller.closePopover()
        }
    }

    /// Opens the popover for a provider (notification taps). Falls back to the
    /// first visible slot when that provider's status item is hidden, so the
    /// tap still surfaces the app instead of doing nothing.
    func showPopover(for provider: Provider) {
        let slot = MenuBarSlot.allCases.first { $0.provider == provider }
        let controller = slot.flatMap { slotControllers[$0] }
            ?? slotOrder.first.flatMap { slotControllers[$0] }
        controller?.showPopover()
    }
}

@MainActor
private final class StatusItemSlotController: NSObject {
    private let slot: MenuBarSlot
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppViewModel
    private let coordinator: RefreshCoordinator
    private let closeOthers: (MenuBarSlot) -> Void
    private let contentView = MenuBarContentView()
    private var lastLength: CGFloat = -1

    init(
        slot: MenuBarSlot,
        model: AppViewModel,
        coordinator: RefreshCoordinator,
        closeOthers: @escaping (MenuBarSlot) -> Void
    ) {
        self.slot = slot
        self.model = model
        self.coordinator = coordinator
        self.closeOthers = closeOthers
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        updateTitle()
    }

    func remove() {
        closePopover()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = NSImage()
        button.imagePosition = .imageOnly
        contentView.passesClicksThrough = true
        contentView.autoresizingMask = [.height]
        button.addSubview(contentView)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        let root = MenuView(
            model: model,
            scope: MenuViewScope(slot: slot),
            onRefresh: { [weak self] in self?.coordinator.refresh(forceAll: true) },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    func updateTitle() {
        guard let button = statusItem.button else { return }
        let elements = MenuBarLayout.activeElements(model, slot: slot)
        let showCaptions = UserDefaults.standard.object(forKey: "menuBarShowCaptions") as? Bool ?? true
        let summary = accessibilitySummary()
        button.toolTip = summary
        button.setAccessibilityLabel(summary)

        let width = MenuBarContentView.width(elements: elements, showCaptions: showCaptions)
        let statusLength = MenuBarContentView.statusLength(forVisualWidth: width)
        if abs(statusLength - lastLength) > 0.5 {
            lastLength = statusLength
            statusItem.length = statusLength
        }
        contentView.frame = NSRect(x: 0, y: 0, width: width, height: button.bounds.height)
        contentView.apply(elements: elements, showCaptions: showCaptions)
    }

    private func accessibilitySummary() -> String {
        let rows = MenuBarLayout.activeSegments(model, slot: slot)
        guard !rows.isEmpty else { return "AgentMeter \(slot.displayName) — no items shown" }
        return "AgentMeter \(slot.displayName) — " + rows.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// Right-click quick actions, so refresh/settings/quit don't require
    /// opening the popover first.
    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AgentMeter", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        // Menu tracking inside performClick is synchronous; clearing the menu
        // afterwards restores the popover behavior for the next left click.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        coordinator.refresh(forceAll: true)
    }

    @objc private func openSettings() {
        SettingsOpener.open()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        closeOthers(slot)
        coordinator.setActiveAgentsVisible(true)
        coordinator.refresh(
            forceVisibleQuota: true,
            forcedUsageProviders: slot.provider == .copilot ? [] : [slot.provider],
            forceActiveAgents: true
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

extension StatusItemSlotController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        coordinator.setActiveAgentsVisible(false)
    }
}
