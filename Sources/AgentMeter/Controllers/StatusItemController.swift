import AppKit
import SwiftUI

/// Owns the visible set of independent NSStatusItems. Each slot behaves like an
/// iStat menu: its own menu-bar fields, its own popover, shared app data.
@MainActor
final class StatusItemController {
    private let model: AppViewModel
    private let coordinator: RefreshCoordinator
    private let taskEvents: TaskEventFeed?
    private var slotControllers: [MenuBarSlot: StatusItemSlotController] = [:]
    private var slotOrder: [MenuBarSlot] = []

    init(model: AppViewModel, coordinator: RefreshCoordinator, taskEvents: TaskEventFeed? = nil) {
        self.model = model
        self.coordinator = coordinator
        self.taskEvents = taskEvents
        reconcileSlots()
        observeModel()

        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
        // A reset countdown is read off the clock, and its tick is a timer that
        // sleep stalls and a clock change can leave an hour out of step.
        NotificationCenter.default.addObserver(
            self, selector: #selector(clockMayHaveJumped),
            name: .NSSystemClockDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(clockMayHaveJumped),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func defaultsChanged() {
        Task { @MainActor in
            self.reconcileSlots()
            self.updateAll()
        }
    }

    /// `nonisolated`: nothing documents which thread posts a clock change, and
    /// a main-actor `@objc` thunk traps when it is called from another one.
    @objc private nonisolated func clockMayHaveJumped() {
        Task { @MainActor in self.updateAll() }
    }

    private func reconcileSlots() {
        let visible = MenuBarLayout.visibleSlots(model)
        guard visible != slotOrder else { return }

        for controller in slotControllers.values {
            controller.remove()
        }
        slotControllers.removeAll()
        slotOrder = visible

        let host = Self.taskEventsSlot(visible: visible)
        for slot in visible {
            slotControllers[slot] = StatusItemSlotController(
                slot: slot,
                model: model,
                coordinator: coordinator,
                taskEvents: slot == host ? taskEvents : nil,
                closeOthers: { [weak self] activeSlot in
                    self?.closePopovers(except: activeSlot)
                }
            )
        }
        updateAll()
    }

    /// The status item that carries the unread count and whose popover lists
    /// the task notifications: Claude's (the tasks are Claude Code's), or the
    /// first visible one while Claude's is hidden, so the count never
    /// disappears with it.
    static func taskEventsSlot(visible: [MenuBarSlot]) -> MenuBarSlot? {
        visible.contains(.claude) ? .claude : visible.first
    }

    /// Refresh the menubar text when the model changes.
    private func observeModel() {
        withObservationTracking {
            _ = model.codex
            _ = model.claude
            _ = model.copilot
            _ = model.staleQuotaProviders
            _ = model.taskEvents.unreadCount
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

    /// Opens the popover that lists the task notifications.
    func showTaskEvents() {
        guard let slot = Self.taskEventsSlot(visible: slotOrder) else { return }
        slotControllers[slot]?.showPopover()
    }
}

@MainActor
private final class StatusItemSlotController: NSObject {
    private let slot: MenuBarSlot
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppViewModel
    private let coordinator: RefreshCoordinator
    /// Set on the one slot that carries the task notifications.
    private let taskEvents: TaskEventFeed?
    private let closeOthers: (MenuBarSlot) -> Void
    private let contentView = MenuBarContentView()
    private var lastLength: CGFloat = -1
    /// Re-renders when a reset countdown in this item next changes text.
    private lazy var countdownTicker = CountdownTicker { [weak self] in self?.updateTitle() }

    init(
        slot: MenuBarSlot,
        model: AppViewModel,
        coordinator: RefreshCoordinator,
        taskEvents: TaskEventFeed?,
        closeOthers: @escaping (MenuBarSlot) -> Void
    ) {
        self.slot = slot
        self.model = model
        self.coordinator = coordinator
        self.taskEvents = taskEvents
        self.closeOthers = closeOthers
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        updateTitle()
    }

    func remove() {
        countdownTicker.stop()
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
            taskEvents: taskEvents,
            onRefresh: { [weak self] in self?.coordinator.refresh(forceAll: true) },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    func updateTitle() {
        guard let button = statusItem.button else { return }
        // One reading for the captions, the tooltip and the next tick.
        let now = Date()
        let elements = MenuBarLayout.activeElements(model, slot: slot, now: now)
        let showCaptions = UserDefaults.standard.object(forKey: "menuBarShowCaptions") as? Bool ?? true
        // Dim only when the item actually displays quota numbers — usage/spend
        // come from local logs and are never network-stale.
        let showsQuota = elements.contains { $0.segment?.remaining != nil }
        let stale = showsQuota && model.staleQuotaProviders.contains(slot.provider)
        contentView.dimmed = stale
        let unread = taskEvents == nil ? 0 : model.taskEvents.unreadCount
        contentView.unreadBadge = unread
        let summary = accessibilitySummary(elements.compactMap(\.segment))
            + (stale ? " — quota data stale, refresh failing" : "")
            + MenuBarContentView.unreadSummary(unread)
        // Only on a change: most renders (defaults, model, wake) leave it as it was.
        if button.toolTip != summary {
            button.toolTip = summary
            button.setAccessibilityLabel(summary)
        }

        let width = MenuBarContentView.width(elements: elements, showCaptions: showCaptions, unreadBadge: unread)
        let statusLength = MenuBarContentView.statusLength(forVisualWidth: width)
        if abs(statusLength - lastLength) > 0.5 {
            lastLength = statusLength
            statusItem.length = statusLength
        }
        contentView.frame = NSRect(x: 0, y: 0, width: width, height: button.bounds.height)
        contentView.apply(
            elements: elements,
            showCaptions: showCaptions,
            fillsByUsed: QuotaDisplay.showsUsed
        )
        countdownTicker.arm(at: MenuBarLayout.nextCountdownChange(in: elements, after: now))
    }

    private func accessibilitySummary(_ rows: [MenuBarSegment]) -> String {
        guard !rows.isEmpty else { return "AgentMeter \(slot.displayName) — no items shown" }
        let end = QuotaDisplay.word(showsUsed: QuotaDisplay.showsUsed)
        return "AgentMeter \(slot.displayName) — " + rows.map { $0.spokenText(end: end) }.joined(separator: ", ")
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
        // The popover opens on the button's screen; record its height so the
        // popover caps itself to that screen, not whichever one is "main".
        model.popoverScreenVisibleHeight = button.window?.screen?.visibleFrame.height
        closeOthers(slot)
        coordinator.setActiveAgentsVisible(true)
        coordinator.refresh(
            forceVisibleQuota: true,
            forcedUsageProviders: slot.provider == .copilot ? [] : [slot.provider],
            forceActiveAgents: true
        )
        // Another instance may have written the log meanwhile.
        taskEvents?.scheduleReload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

extension StatusItemSlotController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        coordinator.setActiveAgentsVisible(false)
        if taskEvents != nil { model.taskEventNotice = nil }
    }
}
