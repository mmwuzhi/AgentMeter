@testable import AgentMeter
import AppKit
import XCTest

/// The Settings field strips: their pure decisions (`ChipStrip`), and the real
/// AppKit views built off screen and driven the way a scroll or a drag would,
/// without showing a window or posting an event.
@MainActor
final class ChipStripTests: XCTestCase {
    // MARK: Document width

    func testTheDocumentIsNeverNarrowerThanTheStrip() {
        XCTAssertEqual(ChipStrip.documentWidth(chipWidths: [], visibleWidth: 300), 300)
        XCTAssertEqual(ChipStrip.documentWidth(chipWidths: [40, 50], visibleWidth: 300), 300)
        // 8 + 100 + 8 + 120 + 8 + 90 + 8
        XCTAssertEqual(ChipStrip.documentWidth(chipWidths: [100, 120, 90], visibleWidth: 300), 342)
    }

    // MARK: Wheel

    func testATrackpadSwipesSidewaysItselfAndLeavesVerticalSwipesToTheForm() {
        XCTAssertEqual(route(dx: -12, dy: 2, precise: true), .native)
        XCTAssertEqual(route(dx: 1, dy: -9, precise: true), .passOn)
        XCTAssertEqual(route(dx: 0, dy: 0, precise: true), .passOn)
    }

    func testAVerticalWheelMovesTheStripSidewaysWhileItCan() {
        let step = ChipStrip.wheelLineStep
        // Down goes toward the end, up toward the start.
        XCTAssertEqual(route(dy: -1, offset: 0), .scroll(to: step))
        XCTAssertEqual(route(dy: 1, offset: 100), .scroll(to: 100 - step))
        // The last bit of travel is clamped rather than skipped.
        XCTAssertEqual(route(dy: -1, offset: 190, maxOffset: 200), .scroll(to: 200))
        XCTAssertEqual(route(dy: 2, offset: 10), .scroll(to: 0))
    }

    func testAtTheEndTheWheelScrollsTheFormInstead() {
        XCTAssertEqual(route(dy: -1, offset: 200, maxOffset: 200), .passOn)
        XCTAssertEqual(route(dy: 1, offset: 0), .passOn)
        // Nothing to scroll at all: every event goes on.
        XCTAssertEqual(route(dy: -1, offset: 0, maxOffset: 0), .passOn)
        XCTAssertEqual(route(dx: -12, dy: 0, precise: true, maxOffset: 0), .passOn)
    }

    func testShiftWheelArrivesSidewaysAndMovesTheStripTheSameWay() {
        XCTAssertEqual(route(dx: -1, dy: 0, offset: 0), .scroll(to: ChipStrip.wheelLineStep))
        XCTAssertEqual(route(dx: 1, dy: 0, offset: 0), .passOn)
    }

    func testATrackpadGestureKeepsTheWayItBeganThroughItsMomentum() {
        var lock = ChipStrip.GestureLock()
        XCTAssertEqual(lock.route(.passOn, phase: .mayBegin, momentumPhase: []), .passOn)
        XCTAssertEqual(lock.route(.native, phase: .began, momentumPhase: []), .native)
        // A later event leaning vertical is still the sideways swipe's.
        XCTAssertEqual(lock.route(.passOn, phase: .changed, momentumPhase: []), .native)
        XCTAssertEqual(lock.route(.passOn, phase: .ended, momentumPhase: []), .native)
        XCTAssertEqual(lock.route(.passOn, phase: [], momentumPhase: .began), .native)
        XCTAssertEqual(lock.route(.passOn, phase: [], momentumPhase: .changed), .native)
        XCTAssertEqual(lock.route(.passOn, phase: [], momentumPhase: .ended), .native)

        XCTAssertNil(lock.fingers)
        XCTAssertNil(lock.momentum, "nothing outlives the gesture")
    }

    func testNoRouteOutlivesTheGestureThatSetIt() {
        var lock = ChipStrip.GestureLock()
        _ = lock.route(.native, phase: .began, momentumPhase: [])
        _ = lock.route(.native, phase: .cancelled, momentumPhase: [])
        XCTAssertNil(lock.fingers)
        // A stray event of no gesture takes its own way.
        XCTAssertEqual(lock.route(.passOn, phase: .changed, momentumPhase: []), .passOn)

        // Lifted with no momentum after it: the next gesture decides afresh.
        _ = lock.route(.native, phase: .began, momentumPhase: [])
        _ = lock.route(.native, phase: .ended, momentumPhase: [])
        XCTAssertEqual(lock.route(.passOn, phase: .mayBegin, momentumPhase: []), .passOn)
        XCTAssertNil(lock.momentum, "a new touch clears the coast the last one never had")
        XCTAssertEqual(lock.route(.passOn, phase: .began, momentumPhase: []), .passOn)
        XCTAssertEqual(lock.route(.native, phase: .changed, momentumPhase: []), .passOn)
    }

    private func route(dx: CGFloat = 0, dy: CGFloat = 0, precise: Bool = false,
                       offset: CGFloat = 0, maxOffset: CGFloat = 200) -> ChipStrip.WheelRoute {
        ChipStrip.wheelRoute(deltaX: dx, deltaY: dy, precise: precise, offset: offset, maxOffset: maxOffset)
    }

    // MARK: Autoscroll

    func testADragHeldNearAnEdgeScrollsTowardItFasterTheCloser() {
        let visible: ClosedRange<CGFloat> = 100...400
        func step(_ x: CGFloat, document: CGFloat = 1000, elapsed: TimeInterval = 0.05) -> CGFloat {
            ChipStrip.autoscrollStep(pointerX: x, visible: visible, documentWidth: document, elapsed: elapsed)
        }

        XCTAssertEqual(step(250), 0, "the middle does not scroll")
        XCTAssertEqual(step(100 + ChipStrip.edgeWidth + 1), 0)
        XCTAssertGreaterThan(step(395), 0)
        XCTAssertLessThan(step(105), 0)
        XCTAssertGreaterThan(step(399), step(380), "closer to the edge is faster")
        XCTAssertEqual(step(399, elapsed: 5), step(399, elapsed: 0.1), "a stalled update does not jump")
        // Never past either end of the document.
        XCTAssertEqual(ChipStrip.autoscrollStep(pointerX: 299, visible: 0...300, documentWidth: 302, elapsed: 0.05),
                       2, accuracy: 0.001)
        XCTAssertEqual(ChipStrip.autoscrollStep(pointerX: 2, visible: 0...300, documentWidth: 1000, elapsed: 0.05), 0)
    }

    // MARK: Drop position

    /// Five 40-point chips at 8, 56, 104, 152, 200 (inset 8, gaps 8).
    private let frames = (0..<5).map { CGRect(x: 8 + CGFloat($0) * 48, y: 8, width: 40, height: 30) }

    func testAnArrivingChipGoesInAtTheNearestGap() {
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 30, frames: [], source: nil)?.offset, 0, "an empty zone")
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 2, frames: frames, source: nil)?.offset, 0)
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 70, frames: frames, source: nil)?.offset, 1)
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 85, frames: frames, source: nil)?.offset, 2)
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 235, frames: frames, source: nil)?.offset, 5, "after the last chip")
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 290, frames: frames, source: nil)?.offset, 5, "empty space")
    }

    func testAChipInTheZoneMovesPastAnotherChipsCentreOrIntoTheEmptyEnds() {
        // Past the centre of a later chip: after it; of an earlier one: before it.
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 180, frames: frames, source: 1),
                       ChipStrip.DropMove(offset: 4, destination: 3))
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 20, frames: frames, source: 3),
                       ChipStrip.DropMove(offset: 0, destination: 0))
        // Over the near half of either, nothing yet.
        XCTAssertNil(ChipStrip.dropMove(pointerX: 165, frames: frames, source: 1))
        XCTAssertNil(ChipStrip.dropMove(pointerX: 40, frames: frames, source: 3))
        // The empty space after the last chip and before the first.
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 280, frames: frames, source: 1),
                       ChipStrip.DropMove(offset: 5, destination: nil))
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 3, frames: frames, source: 2),
                       ChipStrip.DropMove(offset: 0, destination: nil))
    }

    func testAnArrivalAndTheUpdatesAfterItAgree() {
        // Arriving on the right half of the last chip appends; the updates
        // that follow see the chip in the zone and must leave it there.
        let two = Array(frames.prefix(2))
        let arrival = ChipStrip.dropMove(pointerX: 80, frames: two, source: nil)
        XCTAssertEqual(arrival?.offset, 2)
        XCTAssertNil(ChipStrip.dropMove(pointerX: 80, frames: Array(frames.prefix(3)), source: 2))
        // And on the left half it goes before, where it stays too.
        XCTAssertEqual(ChipStrip.dropMove(pointerX: 70, frames: two, source: nil)?.offset, 1)
        let shifted = [frames[0], frames[1], frames[2]]
        XCTAssertNil(ChipStrip.dropMove(pointerX: 70, frames: shifted, source: 1))
    }

    func testAChipStaysPutOverItselfInAGapOrAtTheEndItAlreadyHolds() {
        XCTAssertNil(ChipStrip.dropMove(pointerX: 75, frames: frames, source: 1), "over itself")
        XCTAssertNil(ChipStrip.dropMove(pointerX: 100, frames: frames, source: 0), "in a gap")
        XCTAssertNil(ChipStrip.dropMove(pointerX: 280, frames: frames, source: 4))
        XCTAssertNil(ChipStrip.dropMove(pointerX: 3, frames: frames, source: 0))
    }

    // MARK: The views

    func testManyLongFieldsScrollAndTheLastOneCanBeReachedAndSeen() throws {
        let labels = (0..<12).map { "5h \($0)h21m" }
        let strip = try Strip(visible: labels, width: 300)
        let container = strip.visible.container
        let chips = container.arrangedViews
        let expected = ChipStrip.documentWidth(chipWidths: chips.map(\.bounds.width), visibleWidth: 300)

        XCTAssertGreaterThan(expected, 2 * 300, "long countdown captions make wide chips")
        XCTAssertEqual(container.frame.width, expected)
        XCTAssertEqual(container.frame.height, 46, "the strip keeps its height: no scroller takes any")
        XCTAssertEqual(strip.visible.scrollView.contentView.bounds.width, 300)
        XCTAssertFalse(strip.visible.showsLeadingHint)
        XCTAssertTrue(strip.visible.showsTrailingHint)
        let last = try XCTUnwrap(chips.last)
        XCTAssertFalse(container.visibleRect.contains(last.frame))

        strip.scrollToEnd(strip.visible)

        XCTAssertTrue(container.visibleRect.contains(last.frame), "the far end is reachable and fully shown")
        XCTAssertEqual(container.visibleRect.maxX, container.frame.width)
        XCTAssertTrue(strip.visible.showsLeadingHint)
        XCTAssertFalse(strip.visible.showsTrailingHint)
        for chip in chips {
            XCTAssertEqual(chip.frame.midY, 23, accuracy: 0.5, "chips centre in the 46-point strip")
        }
    }

    func testAFewFieldsFillTheStripAndItsEmptySpaceIsTheDropTarget() throws {
        let strip = try Strip(visible: ["5h", "7d"], width: 300)
        let zone = strip.visible

        XCTAssertEqual(zone.container.frame.width, 300)
        XCTAssertFalse(zone.showsLeadingHint)
        XCTAssertFalse(zone.showsTrailingHint)
        XCTAssertTrue(zone.hitTest(zone.convert(NSPoint(x: 280, y: 23), to: zone.superview)) === zone.container)
    }

    func testTheEdgeHintsNeverTakeAClickOrADrop() throws {
        let strip = try Strip(visible: (0..<10).map { "1h\($0)1m" }, width: 200)
        let zone = strip.visible
        XCTAssertTrue(zone.showsTrailingHint)
        let underHint = NSPoint(x: 195, y: 23)
        let chip = try XCTUnwrap(zone.container.arrangedViews.first {
            zone.container.convert($0.frame, to: zone).contains(underHint)
        })

        // `hitTest` takes the point in the superview's coordinates.
        XCTAssertTrue(zone.hitTest(zone.convert(underHint, to: zone.superview)) === chip)
    }

    func testNothingOverTheChipsTakesTheirMouseDownAfterAScroll() throws {
        // An overlay scroller, while it showed after a scroll, covered the
        // bottom 17 points and won the hit over the lower part of each chip.
        let strip = try Strip(visible: (0..<10).map { "5h \($0)h21m" }, width: 300)
        let zone = strip.visible
        strip.scrollToEnd(zone)
        zone.scrollView.flashScrollers()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(zone.scrollView.hasHorizontalScroller)
        for chip in zone.container.arrangedViews where zone.container.visibleRect.contains(chip.frame) {
            for y in [chip.frame.minY + 2, chip.frame.midY, chip.frame.maxY - 2] {
                let point = zone.container.convert(NSPoint(x: chip.frame.midX, y: y), to: zone.superview)
                XCTAssertTrue(zone.hitTest(point) === chip, "y \(y) of \(chip.key)")
            }
        }
    }

    func testANarrowStripWithOneLongFieldStillReachesItsEnd() throws {
        let strip = try Strip(visible: ["7d 6d12h"], width: 60)
        let container = strip.visible.container
        let chip = try XCTUnwrap(container.arrangedViews.first)

        XCTAssertGreaterThan(container.frame.width, 60)
        strip.scrollToEnd(strip.visible)
        XCTAssertEqual(container.visibleRect.maxX, chip.frame.maxX + ChipStrip.inset, accuracy: 0.5)
    }

    func testShrinkingTheContentPullsAScrolledStripBack() throws {
        let strip = try Strip(visible: (0..<10).map { "5h \($0)h21m" }, width: 300)
        strip.scrollToEnd(strip.visible)

        strip.visible.container.arrangedViews.removeLast(8)

        XCTAssertEqual(strip.visible.container.frame.width, 300)
        XCTAssertEqual(strip.visible.scrollView.contentView.bounds.minX, 0)
    }

    func testAWheelNotchScrollsTheStripAndAtTheEndGoesToTheForm() throws {
        let strip = try Strip(visible: (0..<10).map { "5h \($0)h21m" }, width: 300)
        let scroll = strip.visible.scrollView
        let down = try XCTUnwrap(wheelEvent(lines: -1))

        scroll.scrollWheel(with: down)
        XCTAssertEqual(scroll.contentView.bounds.minX, ChipStrip.wheelLineStep)
        XCTAssertEqual(strip.form.wheelEvents, 0)

        strip.scrollToEnd(strip.visible)
        scroll.scrollWheel(with: down)
        XCTAssertEqual(strip.form.wheelEvents, 1, "at the end the Form behind it scrolls")
    }

    func testAWheelOverAStripThatFitsScrollsTheForm() throws {
        let strip = try Strip(visible: ["5h"], width: 300)

        strip.visible.scrollView.scrollWheel(with: try XCTUnwrap(wheelEvent(lines: -1)))

        XCTAssertEqual(strip.form.wheelEvents, 1)
        XCTAssertEqual(strip.visible.scrollView.contentView.bounds.minX, 0)
    }

    /// A line-based (mouse wheel) scroll event. Created, never posted.
    private func wheelEvent(lines: Int32) -> NSEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
            .flatMap(NSEvent.init(cgEvent:))
    }

    // MARK: Dragging under scroll

    func testAFieldDroppedOnTheRightHalfOfTheLastChipStaysLast() throws {
        // AppKit keeps sending updates while the pointer rests, and each one
        // treats the arrived chip as already in the zone: it used to trade
        // places with the chip under the pointer and land before it.
        let strip = try Strip(visible: ["5h", "7d"], hidden: ["usd"], width: 300)
        let source = try XCTUnwrap(strip.hidden.container.arrangedViews.first)
        let drag = DragDouble(source: source)
        strip.backing.isDragging = true
        drag.move(to: source.frame.center, in: strip.hidden.container)
        _ = strip.hidden.container.draggingEntered(drag)
        strip.hidden.container.draggingExited(drag)

        let last = strip.visible.container.arrangedViews[1]
        drag.move(to: NSPoint(x: last.frame.midX + 4, y: last.frame.midY), in: strip.visible.container)
        _ = strip.visible.container.draggingEntered(drag)
        hold(drag, over: strip.visible.container)
        XCTAssertTrue(strip.visible.container.performDragOperation(drag))

        XCTAssertEqual(strip.backing.committed?.visible, ["v0", "v1", "h0"])
        XCTAssertEqual(strip.backing.committed?.hidden, [])
    }

    func testAFieldDroppedOnTheLeftHalfOfAChipGoesBeforeIt() throws {
        let strip = try Strip(visible: ["5h", "7d"], hidden: ["usd"], width: 300)
        let source = try XCTUnwrap(strip.hidden.container.arrangedViews.first)
        let drag = DragDouble(source: source)
        strip.backing.isDragging = true
        drag.move(to: source.frame.center, in: strip.hidden.container)
        _ = strip.hidden.container.draggingEntered(drag)
        strip.hidden.container.draggingExited(drag)

        let last = strip.visible.container.arrangedViews[1]
        drag.move(to: NSPoint(x: last.frame.midX - 4, y: last.frame.midY), in: strip.visible.container)
        _ = strip.visible.container.draggingEntered(drag)
        hold(drag, over: strip.visible.container)
        XCTAssertTrue(strip.visible.container.performDragOperation(drag))

        XCTAssertEqual(strip.backing.committed?.visible, ["v0", "h0", "v1"])
    }

    func testReorderingWithinAZoneSettlesUnderAStillPointer() throws {
        let strip = try Strip(visible: ["5h", "7d", "1h21m", "usd"], width: 300)
        let container = strip.visible.container
        let source = container.arrangedViews[0]
        let drag = DragDouble(source: source)
        strip.backing.isDragging = true
        drag.move(to: source.frame.center, in: container)
        _ = container.draggingEntered(drag)

        // Past the centre of the third chip: the first goes after it, once.
        let third = container.arrangedViews[2]
        drag.move(to: NSPoint(x: third.frame.midX + 3, y: third.frame.midY), in: container)
        hold(drag, over: container)
        XCTAssertTrue(container.performDragOperation(drag))

        XCTAssertEqual(strip.backing.committed?.visible, ["v1", "v2", "v0", "v3"])
    }

    /// Several updates at one pointer position, as AppKit sends them while a
    /// drag rests, with time for any slide to finish between them.
    private func hold(_ drag: DragDouble, over container: ChipContainerView, times: Int = 5) {
        for _ in 0..<times {
            _ = container.draggingUpdated(drag)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
    }

    func testDraggingAHiddenFieldPastTheLastVisibleOneAppendsIt() throws {
        let labels = (0..<10).map { "5h \($0)h21m" }
        let strip = try Strip(visible: labels, hidden: ["usd", "today"], width: 300)
        strip.scrollToEnd(strip.visible)
        let source = try XCTUnwrap(strip.hidden.container.arrangedViews.first)
        let drag = DragDouble(source: source)
        strip.backing.isDragging = true

        drag.move(to: source.frame.center, in: strip.hidden.container)
        _ = strip.hidden.container.draggingEntered(drag)
        _ = strip.hidden.container.draggingUpdated(drag)
        strip.hidden.container.draggingExited(drag)
        // Over the last visible chip, past its centre: scrolled to the end,
        // this is where the window says the pointer is.
        let last = try XCTUnwrap(strip.visible.container.arrangedViews.last)
        drag.move(to: NSPoint(x: last.frame.maxX - 2, y: last.frame.midY), in: strip.visible.container)
        _ = strip.visible.container.draggingEntered(drag)
        hold(drag, over: strip.visible.container)
        XCTAssertTrue(strip.visible.container.performDragOperation(drag))

        XCTAssertEqual(strip.backing.committed?.visible, ["v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "h0"])
        XCTAssertEqual(strip.backing.committed?.hidden, ["h1"])
    }

    func testReorderingInAScrolledStripUsesTheScrolledPositions() throws {
        let strip = try Strip(visible: (0..<10).map { "5h \($0)h21m" }, width: 300)
        strip.scrollToEnd(strip.visible)
        let container = strip.visible.container
        let chips = container.arrangedViews
        let source = chips[8]
        let drag = DragDouble(source: source)
        strip.backing.isDragging = true

        // Into the empty space after the last chip, which only exists at this
        // scroll offset: unscrolled, the same window point is over chip 2 or 3.
        drag.move(to: NSPoint(x: container.frame.width - 3, y: 23), in: container)
        _ = container.draggingEntered(drag)
        hold(drag, over: container)
        XCTAssertTrue(container.performDragOperation(drag))

        XCTAssertEqual(strip.backing.committed?.visible.suffix(2), ["v9", "v8"])
    }

    func testAChipCarriedOutAndBackOverEmptySpaceIsKept() throws {
        // It used to come back only over another chip; dropped in the empty
        // space it was left out of the saved layout altogether.
        let strip = try Strip(visible: ["5h", "7d", "1h21m"], width: 300)
        let container = strip.visible.container
        let source = container.arrangedViews[1]
        let drag = DragDouble(source: source)
        strip.backing.isDragging = true

        drag.move(to: source.frame.center, in: container)
        _ = container.draggingEntered(drag)
        container.draggingExited(drag)
        drag.move(to: NSPoint(x: 260, y: 23), in: container)
        _ = container.draggingEntered(drag)
        hold(drag, over: container)
        XCTAssertTrue(container.performDragOperation(drag))

        XCTAssertEqual(strip.backing.committed?.visible, ["v0", "v2", "v1"])
    }

    func testHoldingADragNearTheEdgeScrollsTheStrip() throws {
        let strip = try Strip(visible: (0..<10).map { "5h \($0)h21m" }, width: 300)
        let container = strip.visible.container
        let source = try XCTUnwrap(container.arrangedViews.first)
        let drag = DragDouble(source: source)
        strip.backing.isDragging = true
        let clip = strip.visible.scrollView.contentView

        drag.move(to: NSPoint(x: clip.bounds.maxX - 3, y: 23), in: container)
        _ = container.draggingEntered(drag)
        let afterEnter = clip.bounds.minX
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        _ = container.draggingUpdated(drag)

        XCTAssertGreaterThan(afterEnter, 0)
        XCTAssertGreaterThan(clip.bounds.minX, afterEnter, "it keeps going while the drag is held there")
        XCTAssertTrue(strip.visible.showsLeadingHint)
    }

    // MARK: Fixtures

    /// Two zones in an off-screen window (never ordered in), inside a view that
    /// stands in for the Form and counts the scroll events handed to it.
    private struct Strip {
        let window: NSWindow
        let form: FormDouble
        let backing: BackingDouble
        let visible: ChipZoneView
        let hidden: ChipZoneView

        @MainActor
        init(visible visibleLabels: [String], hidden hiddenLabels: [String] = [], width: CGFloat) throws {
            backing = BackingDouble(visible: visibleLabels, hidden: hiddenLabels)
            window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width + 40, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            form = FormDouble(frame: NSRect(x: 0, y: 0, width: width + 40, height: 200))
            window.contentView = form
            visible = ChipZoneView(zone: .visible, backing: backing)
            hidden = ChipZoneView(zone: .hidden, backing: backing)
            for (zone, y) in [(visible, CGFloat(120)), (hidden, CGFloat(40))] {
                backing.register(zone.container, zone: zone.container.zone)
                zone.container.configure(signature: "")
                zone.frame = NSRect(x: 20, y: y, width: width, height: 46)
                form.addSubview(zone)
            }
            form.layoutSubtreeIfNeeded()
        }

        @MainActor
        func scrollToEnd(_ zone: ChipZoneView) {
            let clip = zone.scrollView.contentView
            clip.scroll(to: NSPoint(x: zone.container.frame.width - clip.bounds.width, y: 0))
            zone.scrollView.reflectScrolledClipView(clip)
        }
    }

    final class FormDouble: NSView {
        var wheelEvents = 0
        override func scrollWheel(with event: NSEvent) { wheelEvents += 1 }
    }

    /// Chips drawn by the real `MenuBarContentView`, so their widths are the
    /// real ones for each caption. Keys are `v0…` and `h0…`.
    @MainActor
    final class BackingDouble: LayoutEditorBacking {
        var isDragging = false
        private var labels: [String: String] = [:]
        private var zones: [ChipContainerView.Zone: [String]] = [:]
        private var containers: [ChipContainerView.Zone: ChipContainerView] = [:]
        var committed: (visible: [String], hidden: [String])?

        init(visible: [String], hidden: [String]) {
            zones[.visible] = visible.indices.map { "v\($0)" }
            zones[.hidden] = hidden.indices.map { "h\($0)" }
            for (index, label) in visible.enumerated() { labels["v\(index)"] = label }
            for (index, label) in hidden.enumerated() { labels["h\(index)"] = label }
        }

        func keys(for zone: ChipContainerView.Zone) -> [String] { zones[zone] ?? [] }
        func displayName(for key: String) -> String { key }
        func emptyText(for zone: ChipContainerView.Zone) -> String { "Nothing here." }

        func makeContent(for key: String) -> NSView {
            let element = MenuBarElement.segment(
                MenuBarSegment(label: labels[key] ?? key, value: "63%", remaining: 63, alertLevel: .none))
            let view = MenuBarContentView()
            view.passesClicksThrough = true
            view.frame = NSRect(x: 0, y: 0,
                                width: MenuBarContentView.width(elements: [element], showCaptions: true), height: 22)
            view.apply(elements: [element], showCaptions: true, fillsByUsed: false)
            return view
        }

        func register(_ container: ChipContainerView, zone: ChipContainerView.Zone) { containers[zone] = container }

        func commit() {
            committed = (containers[.visible]?.arrangedViews.map(\.key) ?? [],
                         containers[.hidden]?.arrangedViews.map(\.key) ?? [])
        }

        func reload() {}
    }

    /// What AppKit hands a destination during a drag; only the location and
    /// the source matter to the zones.
    final class DragDouble: NSObject, NSDraggingInfo {
        let source: ChipItemView
        var draggingLocation = NSPoint.zero

        init(source: ChipItemView) { self.source = source }

        /// Puts the pointer at `point` in `view`'s coordinates, through the
        /// window, the way AppKit reports it.
        func move(to point: NSPoint, in view: NSView) { draggingLocation = view.convert(point, to: nil) }

        var draggingSource: Any? { source }
        var draggingDestinationWindow: NSWindow? { source.window }
        var draggingSourceOperationMask: NSDragOperation { .move }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { NSPasteboard(name: NSPasteboard.Name("com.shu.agentmeter.tests.drag")) }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }
}

private extension CGRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
