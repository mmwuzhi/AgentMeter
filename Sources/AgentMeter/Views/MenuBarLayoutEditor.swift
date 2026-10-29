import AppKit
import SwiftUI

// An Ice-style two-zone layout editor: native AppKit drag-and-drop with animated
// live reordering (SwiftUI's `.draggable`/`.dropDestination` is choppy for reorder).
// Modeled on Ice's LayoutBarContainer / LayoutBarItemView.

extension NSPasteboard.PasteboardType {
    static let agentMeterChip = Self("com.shu.agentmeter.layout-chip")
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
    /// A pre-sized NSView drawing the chip's content (appearance-adaptive, like
    /// the real menu bar).
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
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
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

/// One zone (Visible or Hidden): lays out chips left→right, animates reordering
/// during a drag, and is the drop target. It is the document of a `ChipZoneView`
/// strip, which draws the bar behind it and scrolls it sideways.
final class ChipContainerView: NSView {
    enum Zone { case visible, hidden }
    enum DraggingPhase { case entered, exited, updated, ended }

    let zone: Zone
    weak var backing: (any LayoutEditorBacking)?

    private var currentSignature = ""
    var shouldAnimateNextLayoutPass = true
    /// When the last autoscroll step of the current drag ran, so the strip
    /// scrolls by time held near an edge rather than by how often AppKit
    /// happens to send updates.
    private var lastAutoscroll: Date?

    var arrangedViews = [ChipItemView]() {
        didSet { layoutArrangedViews(oldViews: oldValue) }
    }

    init(zone: Zone, backing: any LayoutEditorBacking) {
        self.zone = zone
        self.backing = backing
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.agentMeterChip])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

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
        // Sized before the chips are placed: the height they centre in is the
        // strip's, and a chip that just arrived may need the room.
        fitToVisibleWidth()
        let maxHeight = arrangedViews.map { $0.bounds.height }.max() ?? bounds.height
        var x: CGFloat = ChipStrip.inset
        for var view in arrangedViews {
            if subviews.contains(view) {
                if shouldAnimateNextLayoutPass { view = view.animator() }
            } else {
                addSubview(view)
                view.hasContainer = true
            }
            view.setFrameOrigin(CGPoint(x: x, y: (bounds.height - maxHeight) / 2 + (maxHeight - view.bounds.height) / 2))
            x += view.bounds.width + ChipStrip.spacing
        }
        needsDisplay = true
    }

    /// As wide as the chips need and never narrower than what the strip shows,
    /// as tall as the strip. The empty space after the last chip is then still
    /// this view, so it stays a drop target. Returns whether the size changed.
    @discardableResult
    func fitToVisibleWidth() -> Bool {
        guard let clip = enclosingScrollView?.contentView else { return false }
        let size = NSSize(
            width: ChipStrip.documentWidth(chipWidths: arrangedViews.map(\.bounds.width),
                                           visibleWidth: clip.bounds.width),
            height: clip.bounds.height)
        guard frame.size != size else { return false }
        setFrameSize(size)
        // A strip that lost chips would otherwise stay scrolled past its end.
        let maxOffset = max(0, size.width - clip.bounds.width)
        if clip.bounds.minX > maxOffset {
            clip.scroll(to: NSPoint(x: maxOffset, y: clip.bounds.minY))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        return true
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
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: text, attributes: attr)
        str.draw(at: NSPoint(x: ChipStrip.inset + 4, y: (bounds.height - str.size().height) / 2))
    }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastAutoscroll = nil
        return updateArrangedViewsForDrag(with: sender, phase: .entered)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateArrangedViewsForDrag(with: sender, phase: .updated)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        lastAutoscroll = nil
        if let sender { updateArrangedViewsForDrag(with: sender, phase: .exited) }
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        lastAutoscroll = nil
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
            autoscroll(toward: info)
            // In this view's coordinates, so the scroll offset is already in it.
            let location = convert(info.draggingLocation, from: nil)
            let sourceIndex = arrangedViews.firstIndex(of: source)
            guard let move = ChipStrip.dropMove(pointerX: location.x, frames: arrangedViews.map(\.frame),
                                                source: sourceIndex) else {
                return .move
            }
            // Let a chip finish sliding before it is swapped again, or two
            // neighbours trade places back and forth under a still cursor.
            if let destination = move.destination, arrangedViews[destination].layer?.animationKeys() != nil {
                return .move
            }
            if let sourceIndex {
                arrangedViews.move(fromOffsets: [sourceIndex], toOffset: move.offset)
            } else {
                arrangedViews.insert(source, at: move.offset)
            }
            return .move
        case .ended:
            return .move
        }
    }

    /// Scrolls the strip while a drag is held near one of its edges, so a chip
    /// can be carried to fields that are scrolled out of sight.
    private func autoscroll(toward info: NSDraggingInfo) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let now = Date()
        let elapsed = lastAutoscroll.map { now.timeIntervalSince($0) } ?? ChipStrip.firstAutoscrollInterval
        lastAutoscroll = now
        let step = ChipStrip.autoscrollStep(pointerX: clip.convert(info.draggingLocation, from: nil).x,
                                            visible: clip.bounds.minX...clip.bounds.maxX,
                                            documentWidth: bounds.width, elapsed: elapsed)
        guard step != 0 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX + step, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// The geometry and input decisions of a zone strip, as pure functions of
/// what the views report, so they can be checked without a window or a drag.
enum ChipStrip {
    /// Padding before the first chip and after the last, and between chips.
    static let inset: CGFloat = 8
    static let spacing: CGFloat = 8
    /// How far a vertical wheel notch moves the strip sideways.
    static let wheelLineStep: CGFloat = 24
    /// Width of the edge fades, which is also where a held drag autoscrolls.
    static let edgeWidth: CGFloat = 28
    /// Autoscroll speed, from the inner side of the edge band to the very edge.
    static let autoscrollSpeed: ClosedRange<CGFloat> = 80...480
    static let firstAutoscrollInterval: TimeInterval = 1.0 / 30

    /// The document's width: the chips with their padding and gaps, or what
    /// the strip shows when that is more.
    static func documentWidth(chipWidths: [CGFloat], visibleWidth: CGFloat) -> CGFloat {
        let chips = chipWidths.reduce(0, +) + spacing * CGFloat(max(0, chipWidths.count - 1))
        return max(visibleWidth, ceil(inset * 2 + chips))
    }

    /// What one scroll event over the strip does.
    enum WheelRoute: Equatable {
        /// `NSScrollView`'s own handling: a sideways swipe, with its momentum
        /// and rubber band.
        case native
        /// Move the strip to this offset.
        case scroll(to: CGFloat)
        /// Hand it to the enclosing scroll view, so the Form keeps scrolling.
        case passOn
    }

    /// A trackpad or Magic Mouse (`precise`) swipes sideways itself, so only
    /// a mostly-horizontal gesture is the strip's. A wheel that turns one way
    /// only moves the strip instead (down goes right, shift+wheel arrives as
    /// `deltaX` already), but only while it can still move that way: at the
    /// end the event goes on and the Form scrolls as if the strip were not
    /// there. Deltas follow `NSEvent.scrollingDelta*`, positive meaning
    /// toward the start.
    static func wheelRoute(deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                           offset: CGFloat, maxOffset: CGFloat) -> WheelRoute {
        guard maxOffset > 0 else { return .passOn }
        if precise { return abs(deltaX) > abs(deltaY) ? .native : .passOn }
        let delta = deltaX != 0 ? deltaX : deltaY
        let target = min(maxOffset, max(0, offset - delta * wheelLineStep))
        return abs(target - offset) < 0.5 ? .passOn : .scroll(to: target)
    }

    /// Which way a trackpad gesture goes, decided by its first event: its later
    /// events, and the momentum after the fingers lift, carry deltas that may
    /// point either way and must all go where the gesture began. Nothing
    /// outlives the gesture: the fingers' route ends when they lift or cancel,
    /// the momentum's when it ends, and a new touch clears both.
    struct GestureLock {
        private(set) var fingers: WheelRoute?
        private(set) var momentum: WheelRoute?

        /// The route for an event with these phases, given the one its own
        /// deltas would take.
        mutating func route(_ own: WheelRoute, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> WheelRoute {
            if phase.contains(.mayBegin) || phase.contains(.began) {
                fingers = nil
                momentum = nil
            }
            var route = own
            if phase.contains(.began) {
                fingers = own
            } else if !phase.isEmpty, let fingers {
                route = fingers
            } else if !momentumPhase.isEmpty, let momentum {
                route = momentum
            }
            // Whatever coasts after the fingers lift belongs to this gesture.
            if phase.contains(.ended) { momentum = fingers }
            if phase.contains(.ended) || phase.contains(.cancelled) { fingers = nil }
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { momentum = nil }
            return route
        }
    }

    /// How far to scroll for a drag held at `pointerX` (in the clip view's
    /// coordinates, so `visible` is the scrolled-to range) for `elapsed`
    /// seconds: faster the closer to the edge, nothing outside the edge bands
    /// or where the strip cannot move further.
    static func autoscrollStep(pointerX: CGFloat, visible: ClosedRange<CGFloat>, documentWidth: CGFloat,
                               elapsed: TimeInterval) -> CGFloat {
        let fromStart = pointerX - visible.lowerBound
        let fromEnd = visible.upperBound - pointerX
        let distance = min(fromStart, fromEnd)
        guard distance < edgeWidth else { return 0 }
        let closeness = 1 - max(0, distance) / edgeWidth
        let speed = autoscrollSpeed.lowerBound + (autoscrollSpeed.upperBound - autoscrollSpeed.lowerBound) * closeness
        // Capped so a stall (a slow update) does not turn into a jump.
        let length = speed * CGFloat(min(elapsed, 0.1))
        let maxOffset = max(0, documentWidth - (visible.upperBound - visible.lowerBound))
        let offset = visible.lowerBound
        let target = fromStart <= fromEnd ? max(0, offset - length) : min(maxOffset, offset + length)
        return target - offset
    }

    /// Where a dragged chip goes, as an offset for `move(fromOffsets:toOffset:)`
    /// when it is already in the zone and an index for `insert(_:at:)` when it
    /// is arriving; `destination` is the chip it trades places with, if any.
    struct DropMove: Equatable {
        let offset: Int
        let destination: Int?
    }

    /// `frames` are the zone's chips in order and `source` the dragged chip's
    /// index among them, nil while it is not in this zone. An arriving chip
    /// goes in at the gap nearest the pointer: before a chip whose centre the
    /// pointer has not reached, after it otherwise, so dropping after the last
    /// chip, or anywhere in an empty zone, puts it last. A chip already in the
    /// zone follows the same halves: it trades places with the chip under the
    /// pointer only once the pointer is past that chip's centre, coming from
    /// the source's side, or moves into the empty space before the first chip
    /// or after the last. AppKit keeps sending updates while the pointer
    /// rests, and every update after an arrival is an in-zone one, so a rule
    /// that disagreed with the arrival rule moved the chip straight back.
    static func dropMove(pointerX x: CGFloat, frames: [CGRect], source: Int?) -> DropMove? {
        guard let source else {
            return DropMove(offset: frames.filter { $0.midX < x }.count, destination: nil)
        }
        guard let first = frames.first, let last = frames.last else { return nil }
        if x > last.maxX { return source == frames.count - 1 ? nil : DropMove(offset: frames.count, destination: nil) }
        if x < first.minX { return source == 0 ? nil : DropMove(offset: 0, destination: nil) }
        guard let nearest = frames.indices.min(by: { abs(frames[$0].midX - x) < abs(frames[$1].midX - x) }),
              nearest != source,
              (frames[nearest].minX...frames[nearest].maxX).contains(x) else { return nil }
        let movesRight = nearest > source
        guard movesRight ? x > frames[nearest].midX : x < frames[nearest].midX else { return nil }
        return DropMove(offset: movesRight ? nearest + 1 : nearest, destination: nearest)
    }
}

/// A zone's strip: the menu-bar-like bar, a horizontal scroll view whose
/// document is the zone's `ChipContainerView`, and a fade with a chevron at
/// each edge while there is more to see that way. The fades are plain layers,
/// so they take no part in hit-testing or in finding a drag's destination.
final class ChipZoneView: NSView {
    let container: ChipContainerView
    let scrollView = ChipZoneScrollView()
    private let leadingHint = EdgeHintLayer(leading: true)
    private let trailingHint = EdgeHintLayer(leading: false)

    init(zone: ChipContainerView.Zone, backing: any LayoutEditorBacking) {
        container = ChipContainerView(zone: zone, backing: backing)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        // No scroller at all. An overlay one covers the strip's bottom 17
        // points while it shows, which is after every scroll, and took the
        // mouse-down on the lower part of every chip under it; a legacy one
        // would take the height. The edge hints show that there is more.
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = container
        scrollView.onScroll = { [weak self] in self?.updateEdgeHints() }
        addSubview(scrollView)

        for hint in [leadingHint, trailingHint] {
            hint.zPosition = 1
            layer?.addSublayer(hint)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whether the edge hints are showing, for tests.
    var showsLeadingHint: Bool { leadingHint.opacity > 0 }
    var showsTrailingHint: Bool { trailingHint.opacity > 0 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        container.fitToVisibleWidth()
        let width = min(ChipStrip.edgeWidth, bounds.width / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leadingHint.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        trailingHint.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        raiseEdgeHints()
        CATransaction.commit()
        updateEdgeHints()
    }

    /// `zPosition` puts the hints in front on screen, but AppKit adds the
    /// scroll view's layers after them once the strip is shown, and anything
    /// that flattens the tree in order (`render(in:)`) would then draw the
    /// chips over the fades. Keeping them last makes the order agree.
    private func raiseEdgeHints() {
        guard let layer, let sublayers = layer.sublayers,
              !(sublayers.count >= 2 && sublayers[sublayers.count - 2] === leadingHint
                  && sublayers[sublayers.count - 1] === trailingHint) else { return }
        layer.addSublayer(leadingHint)
        layer.addSublayer(trailingHint)
    }

    private func updateEdgeHints() {
        let visible = scrollView.contentView.bounds
        leadingHint.opacity = visible.minX > 0.5 ? 1 : 0
        trailingHint.opacity = visible.maxX < container.frame.width - 0.5 ? 1 : 0
    }

    /// Menu-bar-like backdrop that follows the window appearance, so chips are
    /// previewed dark-on-light in light mode and light-on-dark in dark mode.
    /// Layer colours are fixed values, so they are set again on a change.
    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bar = NSColor(white: isDark ? 0.18 : 0.85, alpha: 1)
        layer?.backgroundColor = bar.cgColor
        var chevron = NSColor.secondaryLabelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            chevron = NSColor.secondaryLabelColor.cgColor
        }
        for hint in [leadingHint, trailingHint] {
            hint.apply(bar: bar.cgColor, chevron: chevron)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}

/// The strip's scroll view, scrolled sideways by gestures, the wheel and drags
/// (see `ChipStrip.wheelRoute`), with no scroller of its own.
final class ChipZoneScrollView: NSScrollView {
    /// Called after every scroll and document resize, for the edge hints.
    var onScroll: (() -> Void)?
    private var gesture = ChipStrip.GestureLock()

    override func tile() {
        super.tile()
        // The clip view has its new size only now.
        if (documentView as? ChipContainerView)?.fitToVisibleWidth() == true {
            documentView?.needsLayout = true
        }
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        onScroll?()
    }

    override func scrollWheel(with event: NSEvent) {
        let clip = contentView
        let maxOffset = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
        var route = ChipStrip.wheelRoute(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                         precise: event.hasPreciseScrollingDeltas,
                                         offset: clip.bounds.minX, maxOffset: maxOffset)
        if event.hasPreciseScrollingDeltas {
            route = gesture.route(route, phase: event.phase, momentumPhase: event.momentumPhase)
        }
        switch route {
        case .native:
            super.scrollWheel(with: event)
        case .scroll(let offset):
            clip.scroll(to: NSPoint(x: offset, y: clip.bounds.minY))
            reflectScrolledClipView(clip)
        case .passOn:
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// A fade from the bar's colour to clear, with a chevron pointing at the
/// hidden side. Drawn by Core Animation only; it is no view.
final class EdgeHintLayer: CAGradientLayer {
    private let leading: Bool
    private let chevron = CAShapeLayer()

    init(leading: Bool) {
        self.leading = leading
        super.init()
        startPoint = CGPoint(x: leading ? 0 : 1, y: 0.5)
        endPoint = CGPoint(x: leading ? 1 : 0, y: 0.5)
        opacity = 0
        chevron.fillColor = nil
        chevron.lineWidth = 1.5
        chevron.lineCap = .round
        chevron.lineJoin = .round
        addSublayer(chevron)
    }

    override init(layer: Any) {
        leading = (layer as? EdgeHintLayer)?.leading ?? true
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(bar: CGColor, chevron color: CGColor) {
        colors = [bar, bar.copy(alpha: 0) ?? bar]
        // The solid part sits under the chevron; the rest fades out.
        locations = [0.35, 1]
        chevron.strokeColor = color
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let path = CGMutablePath()
        let midY = bounds.midY, tip: CGFloat = 6, depth: CGFloat = 4, half: CGFloat = 4.5
        if leading {
            path.move(to: CGPoint(x: tip + depth, y: midY + half))
            path.addLine(to: CGPoint(x: tip, y: midY))
            path.addLine(to: CGPoint(x: tip + depth, y: midY - half))
        } else {
            let x = bounds.maxX - tip
            path.move(to: CGPoint(x: x - depth, y: midY + half))
            path.addLine(to: CGPoint(x: x, y: midY))
            path.addLine(to: CGPoint(x: x - depth, y: midY - half))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.frame = bounds
        chevron.path = path
        CATransaction.commit()
    }
}

/// SwiftUI bridge for one zone. `signature` carries extra display state that should
/// trigger a chip rebuild (e.g. the menu bar's caption toggle); pass "" if none.
struct LayoutZoneView: NSViewRepresentable {
    let zone: ChipContainerView.Zone
    let backing: any LayoutEditorBacking
    var signature: String = ""

    func makeNSView(context: Context) -> ChipZoneView {
        let view = ChipZoneView(zone: zone, backing: backing)
        backing.register(view.container, zone: zone)
        view.container.configure(signature: signature)
        return view
    }

    func updateNSView(_ view: ChipZoneView, context: Context) {
        view.container.configure(signature: signature)
    }
}

// MARK: - Menu-bar item backing

/// Backs the menu-bar item arrangement (icon + quota/usage/spend columns) via `MenuBarLayout`.
@MainActor
final class LayoutEditorCoordinator: ObservableObject, LayoutEditorBacking {
    let model: AppViewModel
    let slot: MenuBarSlot
    private(set) var names: [String: String] = [:]
    private var visibleKeys: [String] = []
    private var hiddenKeys: [String] = []

    weak var visibleContainer: ChipContainerView?
    weak var hiddenContainer: ChipContainerView?
    var isDragging = false

    init(model: AppViewModel, slot: MenuBarSlot = .codex) {
        self.model = model
        self.slot = slot
        load()
    }

    private func load() {
        let merged = MenuBarLayout.merged(model, for: slot)
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
            if key == "icon" { return .icon(MenuBarLayout.icon(for: slot)) }
            if let element = MenuBarLayout.preview(key, model, slot: slot) { return element }
            return .segment(MenuBarSegment(label: names[key] ?? key, value: "—", remaining: nil, alertLevel: .none))
        }()
        let v = MenuBarContentView()
        v.passesClicksThrough = true
        let w = MenuBarContentView.width(elements: [element], showCaptions: showCaptions)
        v.frame = CGRect(x: 0, y: 0, width: w, height: 22)
        v.apply(elements: [element], showCaptions: showCaptions, fillsByUsed: QuotaDisplay.showsUsed)
        return v
    }

    func register(_ container: ChipContainerView, zone: ChipContainerView.Zone) {
        if zone == .visible { visibleContainer = container } else { hiddenContainer = container }
    }

    func commit() {
        guard let visibleContainer, let hiddenContainer else { return }
        let vis = visibleContainer.arrangedViews.map(\.key)
        let hid = hiddenContainer.arrangedViews.map(\.key)
        guard !vis.isEmpty || MenuBarLayout.canHideSlot(model, slot: slot) else { reload(); return }
        visibleKeys = vis
        hiddenKeys = hid
        let items = vis.map { MenuBarItem(key: $0, enabled: true) }
            + hid.map { MenuBarItem(key: $0, enabled: false) }
        MenuBarLayout.save(items, for: slot)   // fires UserDefaults change → menu bar re-renders
    }

    func reload() {
        load()
        visibleContainer?.reconfigure(force: true)
        hiddenContainer?.reconfigure(force: true)
    }
}
