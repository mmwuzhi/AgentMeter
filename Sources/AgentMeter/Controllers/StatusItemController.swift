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
        let visible = MenuBarSlots.visibleSlots()
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
            _ = model.activeAgents
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
        button.action = #selector(togglePopover)
        button.target = self
        button.image = NSImage()
        button.imagePosition = .imageOnly
        contentView.passesClicksThrough = true
        contentView.autoresizingMask = [.width, .height]
        button.addSubview(contentView)
    }

    private func configurePopover() {
        popover.behavior = .transient
        let root = MenuView(
            model: model,
            scope: MenuViewScope(slot: slot),
            onRefresh: { [weak self] in self?.coordinator.refresh() },
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
        if abs(width - lastLength) > 0.5 {
            lastLength = width
            statusItem.length = width
        }
        contentView.frame = button.bounds
        contentView.apply(elements: elements, showCaptions: showCaptions)
    }

    private func accessibilitySummary() -> String {
        let rows = MenuBarLayout.activeSegments(model, slot: slot)
        guard !rows.isEmpty else { return "AgentMeter \(slot.displayName) — no items shown" }
        return "AgentMeter \(slot.displayName) — " + rows.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            closeOthers(slot)
            coordinator.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
