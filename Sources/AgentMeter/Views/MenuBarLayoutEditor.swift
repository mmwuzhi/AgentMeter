import AppKit
import SwiftUI

// An Ice-style menu-bar layout editor: native AppKit drag-and-drop with animated
// live reordering, instead of SwiftUI's `.draggable`/`.dropDestination` (which is
// choppy for reordering). Modeled on Ice's LayoutBarContainer / LayoutBarItemView.

extension NSPasteboard.PasteboardType {
    static let agentMeterChip = Self("co.softbrain.AgentMeter.layout-chip")
}

/// Shared brain for the two zones (Visible / Hidden): holds the canonical item list,
/// resolves chips, and persists edits. Both zones reference one coordinator so a drag
/// can move chips between them and a drop can commit the combined order.
@MainActor
final class LayoutEditorCoordinator: ObservableObject {
    let model: AppViewModel
    private(set) var names: [String: String] = [:]
    private var visibleKeys: [String] = []
    private var hiddenKeys: [String] = []

    weak var visibleContainer: ChipContainerView?
    weak var hiddenContainer: ChipContainerView?

    /// True while a drag session is live, so SwiftUI `updateNSView` passes don't
    /// rebuild the chips out from under the drag.
    var isDragging = false

    init(model: AppViewModel) {
        self.model = model
        load()
    }

    private func load() {
        let merged = MenuBarLayout.merged(model)
        names = Dictionary(merged.map { ($0.item.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        visibleKeys = merged.filter { $0.item.enabled }.map(\.item.key)
        hiddenKeys = merged.filter { !$0.item.enabled }.map(\.item.key)
    }

    func keys(for zone: ChipContainerView.Zone) -> [String] {
        zone == .visible ? visibleKeys : hiddenKeys
    }

    func element(for key: String) -> MenuBarElement {
        if key == "icon" { return .icon }
        if let seg = MenuBarLayout.preview(key, model) { return .segment(seg) }
        return .segment(MenuBarSegment(label: names[key] ?? key, value: "—", remaining: nil))
    }

    func register(_ container: ChipContainerView, zone: ChipContainerView.Zone) {
        if zone == .visible { visibleContainer = container } else { hiddenContainer = container }
    }

    /// Commit the live arrangement after a drop. Reads both containers (their order is
    /// the source of truth post-drag); enforces "at least one visible" by snapping back.
    func commit() {
        guard let visibleContainer, let hiddenContainer else { return }
        let vis = visibleContainer.arrangedViews.map(\.key)
        let hid = hiddenContainer.arrangedViews.map(\.key)
        guard !vis.isEmpty else { reload(); return }   // never let Visible go empty

        visibleKeys = vis
        hiddenKeys = hid
        let items = vis.map { MenuBarItem(key: $0, enabled: true) }
            + hid.map { MenuBarItem(key: $0, enabled: false) }
        MenuBarLayout.save(items)   // fires UserDefaults change → menu bar re-renders
    }

    /// Reset both zones to the last saved arrangement (used to snap back an illegal move).
    func reload() {
        load()
        visibleContainer?.reconfigure(force: true)
        hiddenContainer?.reconfigure(force: true)
    }
}

/// One draggable chip — draws a menu-bar element via the shared `MenuBarContentView`
/// on a token background, and is the `NSDraggingSource`.
final class ChipItemView: NSView, NSDraggingSource {
    let key: String
    private let content = MenuBarContentView()

    /// Where the chip lived before being dragged out, so it can be reinserted if the
    /// drop lands nowhere (mirrors Ice's `oldContainerInfo`).
    var oldContainerInfo: (container: ChipContainerView, index: Int)?
    var hasContainer = false

    var isDraggingPlaceholder = false {
        didSet {
            content.isHidden = isDraggingPlaceholder
            needsDisplay = true
        }
    }

    private static let hPad: CGFloat = 8
    private static let height: CGFloat = 30

    init(key: String, name: String, element: MenuBarElement, showCaptions: Bool) {
        self.key = key
        let w = MenuBarContentView.width(elements: [element], showCaptions: showCaptions)
        super.init(frame: CGRect(x: 0, y: 0, width: w + Self.hPad * 2, height: Self.height))
        wantsLayer = true
        content.forcedColor = .white
        content.passesClicksThrough = true   // mouse events reach this chip, not the text
        content.frame = CGRect(x: Self.hPad, y: (Self.height - 22) / 2, width: w, height: 22)
        content.apply(elements: [element], showCaptions: showCaptions, alertColor: nil)
        addSubview(content)
        toolTip = name   // human-readable, e.g. "Claude · Weekly" (not the raw key)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard !isDraggingPlaceholder else { return }
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.10).setFill()
        bg.fill()
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let item = NSPasteboardItem()
        item.setData(Data(), forType: .agentMeterChip)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// A bitmap of the chip (bg + text) for the floating drag image.
    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        (superview as? ChipContainerView)?.coordinator?.isDragging = true
        session.animatesToStartingPositionsOnCancelOrFail = false
        DispatchQueue.main.async { self.isDraggingPlaceholder = true }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { oldContainerInfo = nil }
        isDraggingPlaceholder = false
        let coordinator = (superview as? ChipContainerView)?.coordinator
            ?? oldContainerInfo?.container.coordinator
        coordinator?.isDragging = false
        // Dropped outside any container: put it back where it started.
        if !hasContainer, let (container, index) = oldContainerInfo {
            container.shouldAnimateNextLayoutPass = false
            container.arrangedViews.insert(self, at: min(index, container.arrangedViews.count))
        }
    }
}

/// One zone (Visible or Hidden): a dark rounded bar that lays out chips left→right,
/// animates reordering during a drag, and is the drop target.
final class ChipContainerView: NSView {
    enum Zone { case visible, hidden }
    enum DraggingPhase { case entered, exited, updated, ended }

    let zone: Zone
    weak var coordinator: LayoutEditorCoordinator?

    private let spacing: CGFloat = 8
    private let inset: CGFloat = 8
    private var currentShowCaptions = true
    var shouldAnimateNextLayoutPass = true

    var arrangedViews = [ChipItemView]() {
        didSet { layoutArrangedViews(oldViews: oldValue) }
    }

    init(zone: Zone, coordinator: LayoutEditorCoordinator) {
        self.zone = zone
        self.coordinator = coordinator
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        registerForDraggedTypes([.agentMeterChip])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Population

    func configure(showCaptions: Bool) {
        guard !(coordinator?.isDragging ?? false) else { return }
        let keys = coordinator?.keys(for: zone) ?? []
        if keys == arrangedViews.map(\.key), showCaptions == currentShowCaptions { return }
        currentShowCaptions = showCaptions
        rebuild(keys: keys, showCaptions: showCaptions)
    }

    func reconfigure(force: Bool) {
        rebuild(keys: coordinator?.keys(for: zone) ?? [], showCaptions: currentShowCaptions)
    }

    private func rebuild(keys: [String], showCaptions: Bool) {
        guard let coordinator else { return }
        shouldAnimateNextLayoutPass = false
        arrangedViews = keys.map { key in
            ChipItemView(key: key, name: coordinator.names[key] ?? key,
                         element: coordinator.element(for: key), showCaptions: showCaptions)
        }
    }

    // MARK: Layout (animated, mirrors Ice)

    private func layoutArrangedViews(oldViews: [ChipItemView]? = nil) {
        defer { shouldAnimateNextLayoutPass = true }
        let oldViews = oldViews ?? arrangedViews
        for view in oldViews where !arrangedViews.contains(view) {
            view.removeFromSuperview()
            view.hasContainer = false
        }
        let maxHeight = arrangedViews.map { $0.bounds.height }.max() ?? bounds.height
        var x: CGFloat = inset
        for var view in arrangedViews {
            if subviews.contains(view) {
                if shouldAnimateNextLayoutPass { view = view.animator() }
            } else {
                addSubview(view)
                view.hasContainer = true
            }
            view.setFrameOrigin(CGPoint(x: x, y: (bounds.height - maxHeight) / 2 + (maxHeight - view.bounds.height) / 2))
            x += view.bounds.width + spacing
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Re-center vertically when the bar gets its height from Auto Layout.
        if !(coordinator?.isDragging ?? false) {
            shouldAnimateNextLayoutPass = false
            layoutArrangedViews()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard arrangedViews.isEmpty else { return }
        let text = zone == .visible ? "Drag items here to show them." : "Everything is shown."
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        let str = NSAttributedString(string: text, attributes: attr)
        str.draw(at: NSPoint(x: inset + 4, y: (bounds.height - str.size().height) / 2))
    }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateArrangedViewsForDrag(with: sender, phase: .entered)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateArrangedViewsForDrag(with: sender, phase: .updated)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender { updateArrangedViewsForDrag(with: sender, phase: .exited) }
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        updateArrangedViewsForDrag(with: sender, phase: .ended)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSource is ChipItemView else { return false }
        coordinator?.commit()
        return true
    }

    @discardableResult
    private func updateArrangedViewsForDrag(with info: NSDraggingInfo, phase: DraggingPhase) -> NSDragOperation {
        guard let source = info.draggingSource as? ChipItemView else { return [] }
        switch phase {
        case .entered:
            if !arrangedViews.contains(source) { shouldAnimateNextLayoutPass = false }
            return updateArrangedViewsForDrag(with: info, phase: .updated)
        case .exited:
            if let index = arrangedViews.firstIndex(of: source) {
                shouldAnimateNextLayoutPass = false
                arrangedViews.remove(at: index)
            }
            return .move
        case .updated:
            if source.oldContainerInfo == nil, let index = arrangedViews.firstIndex(of: source) {
                source.oldContainerInfo = (self, index)
            }
            // Empty container: just drop the source in.
            guard !arrangedViews.isEmpty else {
                arrangedViews.insert(source, at: 0)
                return .move
            }
            let location = convert(info.draggingLocation, from: nil)
            guard
                let destination = arrangedView(nearestTo: location.x),
                destination !== source,
                destination.layer?.animationKeys() == nil,
                let destinationIndex = arrangedViews.firstIndex(of: destination)
            else {
                return .move
            }
            // Only swap once the cursor crosses the destination's horizontal center.
            let midX = destination.frame.midX
            let halfW = destination.frame.width / 2
            if !((midX - halfW)...(midX + halfW)).contains(location.x),
               source.oldContainerInfo?.container === self {
                return .move
            }
            if let sourceIndex = arrangedViews.firstIndex(of: source) {
                var target = destinationIndex
                if destinationIndex > sourceIndex { target += 1 }
                arrangedViews.move(fromOffsets: [sourceIndex], toOffset: target)
            } else {
                arrangedViews.insert(source, at: destinationIndex)
            }
            return .move
        case .ended:
            return .move
        }
    }

    private func arrangedView(nearestTo x: CGFloat) -> ChipItemView? {
        arrangedViews.min { abs($0.frame.midX - x) < abs($1.frame.midX - x) }
    }
}

/// SwiftUI bridge for one zone.
struct MenuBarZoneView: NSViewRepresentable {
    let zone: ChipContainerView.Zone
    let coordinator: LayoutEditorCoordinator
    let showCaptions: Bool

    func makeNSView(context: Context) -> ChipContainerView {
        let view = ChipContainerView(zone: zone, coordinator: coordinator)
        coordinator.register(view, zone: zone)
        view.configure(showCaptions: showCaptions)
        return view
    }

    func updateNSView(_ view: ChipContainerView, context: Context) {
        view.configure(showCaptions: showCaptions)
    }
}
