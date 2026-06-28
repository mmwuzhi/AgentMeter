import AppKit
import SwiftUI

/// Owns the NSStatusItem and the popover that hosts the SwiftUI MenuView.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppViewModel
    private let coordinator: RefreshCoordinator
    private var lastRenderedKey: String?

    init(model: AppViewModel, coordinator: RefreshCoordinator) {
        self.model = model
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        observeModel()

        // Menu-bar title also depends on UserDefaults (which provider, show %).
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func defaultsChanged() {
        Task { @MainActor in self.updateTitle() }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.action = #selector(togglePopover)
        button.target = self
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
            _ = model.headlineWindows
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeModel()
            }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let showPercent = UserDefaults.standard.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        let provider = UserDefaults.standard.string(forKey: "menuBarProvider") ?? "codex"
        let windows = showPercent ? Array(model.headlineWindows.prefix(2)) : []
        let key = Self.renderKey(showPercent: showPercent, provider: provider, windows: windows)
        guard key != lastRenderedKey else { return }
        lastRenderedKey = key
        button.image = Self.renderImage(windows: windows)
    }

    private static func renderKey(showPercent: Bool, provider: String, windows: [QuotaWindow]) -> String {
        guard showPercent else { return "icon-only" }
        let windowKey = windows.map {
            "\($0.id):\($0.shortLabel):\(Int($0.remainingPercent.rounded()))"
        }.joined(separator: "|")
        return "\(provider)|\(windowKey)"
    }

    /// Render the menu-bar content (gauge glyph + up to two quota lines, labels
    /// left, percentages right-aligned) into a vertically-centered template image.
    /// NSStatusBarButton top-aligns multi-line `attributedTitle` and won't size it,
    /// so we draw it ourselves; a template image auto-contrasts on the menu bar.
    private static func renderImage(windows: [QuotaWindow]) -> NSImage {
        let height = NSStatusBar.system.thickness
        let iconSize: CGFloat = 15
        let gap: CGFloat = 4

        let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                             accessibilityDescription: "AgentMeter")?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular))

        func drawIcon() {
            symbol?.draw(in: NSRect(x: 0, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
        }

        guard !windows.isEmpty else {
            let only = NSImage(size: NSSize(width: iconSize + 2, height: height))
            only.lockFocus(); drawIcon(); only.unlockFocus()
            only.isTemplate = true
            return only
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let measure: [NSAttributedString.Key: Any] = [.font: font]
        let labelW = windows.map { ($0.shortLabel as NSString).size(withAttributes: measure).width }.max() ?? 0
        let valueW = windows.map {
            ("\(Int($0.remainingPercent.rounded()))%" as NSString).size(withAttributes: measure).width
        }.max() ?? 0
        let tabLocation = ceil(labelW + 8 + valueW)

        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineSpacing = 0
        para.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation)]

        let text = NSMutableAttributedString()
        for (i, w) in windows.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(
                string: "\(w.shortLabel)\t\(Int(w.remainingPercent.rounded()))%",
                attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: para]))
        }

        let textSize = text.size()
        let textW = max(tabLocation, ceil(textSize.width))
        let width = iconSize + gap + textW + 2
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        drawIcon()
        text.draw(in: NSRect(x: iconSize + gap, y: (height - textSize.height) / 2,
                             width: textW + 1, height: textSize.height))
        image.unlockFocus()
        image.isTemplate = true
        return image
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
