import AppKit
import SwiftUI

// An Ice-style two-zone layout editor: native AppKit drag-and-drop with animated
// live reordering (SwiftUI's `.draggable`/`.dropDestination` is choppy for reorder).
// Modeled on Ice's LayoutBarContainer / LayoutBarItemView. Generic over what the
// chips represent via `LayoutEditorBacking`, so it drives both the menu-bar item
// arrangement and the popover provider-panel arrangement.

extension NSPasteboard.PasteboardType {
    static let agentMeterChip = Self("co.softbrain.AgentMeter.layout-chip")
}

/// What a pair of zones (Visible / Hidden) is editing. The backing owns the canonical
/// key lists, builds each chip's visual, and persists a drop. One backing is shared by
/// its two zones so a drag can move chips between them.
@MainActor
protocol LayoutEditorBacking: AnyObject {
    /// Set while a drag is live so SwiftUI `updateNSView` passes don't rebuild chips
    /// out from under the drag.
    var isDragging: Bool { get set }
    func keys(for zone: ChipContainerView.Zone) -> [String]
    func displayName(for key: String) -> String
    /// A pre-sized NSView drawing the chip's content (white, on the dark bar).
    func makeContent(for key: String) -> NSView
    func emptyText(for zone: ChipContainerView.Zone) -> String
    func register(_ container: ChipContainerView, zone: ChipContainerView.Zone)
    /// Persist the live arrangement after a drop (reads the registered containers).
    func commit()
    /// Reset both zones to the last saved arrangement (snap back an illegal move).
    func reload()
}

/// One draggable chip — wraps a backing-supplied content view on a token background
/// and is the `NSDraggingSource`.
final class ChipItemView: NSView, NSDraggingSource {
    let key: String
    private let content: NSView

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
    private static let minHeight: CGFloat = 30

    init(key: String, name: String, content: NSView) {
        self.key = key
        self.content = content
        let cw = content.frame.width
        let ch = content.frame.height
        let h = max(Self.minHeight, ch + 8)
        super.init(frame: CGRect(x: 0, y: 0, width: cw + Self.hPad * 2, height: h))
        wantsLayer = true
        content.frame = CGRect(x: Self.hPad, y: (h - ch) / 2, width: cw, height: ch)
        addSubview(content)
        toolTip = name
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

    /// A bitmap of the chip (bg + content) for the floating drag image.
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
        (superview as? ChipContainerView)?.backing?.isDragging = true
        session.animatesToStartingPositionsOnCancelOrFail = false
        DispatchQueue.main.async { self.isDraggingPlaceholder = true }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { oldContainerInfo = nil }
        isDraggingPlaceholder = false
        let backing = (superview as? ChipContainerView)?.backing ?? oldContainerInfo?.container.backing
        backing?.isDragging = false
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
    weak var backing: (any LayoutEditorBacking)?

    private let spacing: CGFloat = 8
    private let inset: CGFloat = 8
    private var currentSignature = ""
    var shouldAnimateNextLayoutPass = true

    var arrangedViews = [ChipItemView]() {
        didSet { layoutArrangedViews(oldViews: oldValue) }
    }

    init(zone: Zone, backing: any LayoutEditorBacking) {
        self.zone = zone
        self.backing = backing
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        registerForDraggedTypes([.agentMeterChip])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Population

    /// Rebuild chips when the keys change or `signature` (extra display state, e.g.
    /// the menu bar's caption toggle) changes — but never mid-drag.
    func configure(signature: String) {
        guard let backing, !backing.isDragging else { return }
        let keys = backing.keys(for: zone)
        if keys == arrangedViews.map(\.key), signature == currentSignature { return }
        currentSignature = signature
        rebuild(keys: keys)
    }

    func reconfigure(force: Bool) {
        rebuild(keys: backing?.keys(for: zone) ?? [])
    }

    private func rebuild(keys: [String]) {
        guard let backing else { return }
        shouldAnimateNextLayoutPass = false
        arrangedViews = keys.map { key in
            ChipItemView(key: key, name: backing.displayName(for: key), content: backing.makeContent(for: key))
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
        if !(backing?.isDragging ?? false) {
            shouldAnimateNextLayoutPass = false
            layoutArrangedViews()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard arrangedViews.isEmpty else { return }
        let text = backing?.emptyText(for: zone) ?? ""
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
        backing?.commit()
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

/// SwiftUI bridge for one zone. `signature` carries extra display state that should
/// trigger a chip rebuild (e.g. the menu bar's caption toggle); pass "" if none.
struct LayoutZoneView: NSViewRepresentable {
    let zone: ChipContainerView.Zone
    let backing: any LayoutEditorBacking
    var signature: String = ""

    func makeNSView(context: Context) -> ChipContainerView {
        let view = ChipContainerView(zone: zone, backing: backing)
        backing.register(view, zone: zone)
        view.configure(signature: signature)
        return view
    }

    func updateNSView(_ view: ChipContainerView, context: Context) {
        view.configure(signature: signature)
    }
}

// MARK: - Menu-bar item backing

/// Backs the menu-bar item arrangement (icon + quota/spend columns) via `MenuBarLayout`.
@MainActor
final class LayoutEditorCoordinator: ObservableObject, LayoutEditorBacking {
    let model: AppViewModel
    private(set) var names: [String: String] = [:]
    private var visibleKeys: [String] = []
    private var hiddenKeys: [String] = []

    weak var visibleContainer: ChipContainerView?
    weak var hiddenContainer: ChipContainerView?
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

    func displayName(for key: String) -> String { names[key] ?? key }

    func emptyText(for zone: ChipContainerView.Zone) -> String {
        zone == .visible ? "Drag items here to show them." : "Everything is shown."
    }

    func makeContent(for key: String) -> NSView {
        let showCaptions = UserDefaults.standard.object(forKey: "menuBarShowCaptions") as? Bool ?? true
        let element: MenuBarElement = {
            if key == "icon" { return .icon }
            if let seg = MenuBarLayout.preview(key, model) { return .segment(seg) }
            return .segment(MenuBarSegment(label: names[key] ?? key, value: "—", remaining: nil, alertLevel: .none))
        }()
        let v = MenuBarContentView()
        v.forcedColor = .white
        v.passesClicksThrough = true
        let w = MenuBarContentView.width(elements: [element], showCaptions: showCaptions)
        v.frame = CGRect(x: 0, y: 0, width: w, height: 22)
        v.apply(elements: [element], showCaptions: showCaptions)
        return v
    }

    func register(_ container: ChipContainerView, zone: ChipContainerView.Zone) {
        if zone == .visible { visibleContainer = container } else { hiddenContainer = container }
    }

    func commit() {
        guard let visibleContainer, let hiddenContainer else { return }
        let vis = visibleContainer.arrangedViews.map(\.key)
        let hid = hiddenContainer.arrangedViews.map(\.key)
        guard !vis.isEmpty else { reload(); return }   // never let the menu bar go empty
        visibleKeys = vis
        hiddenKeys = hid
        let items = vis.map { MenuBarItem(key: $0, enabled: true) }
            + hid.map { MenuBarItem(key: $0, enabled: false) }
        MenuBarLayout.save(items)   // fires UserDefaults change → menu bar re-renders
    }

    func reload() {
        load()
        visibleContainer?.reconfigure(force: true)
        hiddenContainer?.reconfigure(force: true)
    }
}

// MARK: - Popover provider-panel backing

/// A simple white "● Name" chip for a provider.
private final class ProviderChipContentView: NSView {
    private let title: String
    private let dotColor: NSColor

    init(title: String, dotColor: NSColor) {
        self.title = title
        self.dotColor = dotColor
        let textW = (title as NSString).size(withAttributes: [.font: Self.font]).width
        super.init(frame: CGRect(x: 0, y: 0, width: 7 + 6 + ceil(textW), height: 18))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // events reach the chip

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        let dotSize: CGFloat = 7
        let dotRect = NSRect(x: 0, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        let attr: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attr)
        (title as NSString).draw(at: NSPoint(x: dotSize + 6, y: (bounds.height - size.height) / 2), withAttributes: attr)
    }
}

/// Backs the popover provider-panel arrangement via `PopoverOrder` (which providers
/// show, in what order). Reuses the same drag editor as the menu bar.
@MainActor
final class PopoverOrderCoordinator: ObservableObject, LayoutEditorBacking {
    weak var visibleContainer: ChipContainerView?
    weak var hiddenContainer: ChipContainerView?
    var isDragging = false

    func keys(for zone: ChipContainerView.Zone) -> [String] {
        let providers = zone == .visible ? PopoverOrder.visible() : PopoverOrder.hidden()
        return providers.map(\.rawValue)
    }

    func displayName(for key: String) -> String {
        Provider(rawValue: key)?.displayName ?? key
    }

    func emptyText(for zone: ChipContainerView.Zone) -> String {
        zone == .visible ? "Drag a provider here to show it." : "Drag a provider here to hide it."
    }

    func makeContent(for key: String) -> NSView {
        let p = Provider(rawValue: key)
        return ProviderChipContentView(title: p?.displayName ?? key,
                                       dotColor: NSColor(PopoverOrder.tint(p ?? .codex)))
    }

    func register(_ container: ChipContainerView, zone: ChipContainerView.Zone) {
        if zone == .visible { visibleContainer = container } else { hiddenContainer = container }
    }

    func commit() {
        guard let visibleContainer, let hiddenContainer else { return }
        let vis = visibleContainer.arrangedViews.map(\.key).compactMap(Provider.init(rawValue:))
        let hid = hiddenContainer.arrangedViews.map(\.key).compactMap(Provider.init(rawValue:))
        guard !vis.isEmpty else { reload(); return }   // keep at least one panel
        PopoverOrder.save(visible: vis, hidden: hid)   // fires UserDefaults change → popover updates
    }

    func reload() {
        visibleContainer?.reconfigure(force: true)
        hiddenContainer?.reconfigure(force: true)
    }
}
