@testable import AgentMeter
import AppKit
import XCTest

/// Where a column's caption, value, gauge and alert dot actually land, read
/// back from the pixels `MenuBarContentView` draws. The status item and the
/// Settings chips share this drawing, so this is what both show.
@MainActor
final class MenuBarColumnAlignmentTests: XCTestCase {
    /// Glyphs carry a little side bearing, so ink starts a fraction of a point
    /// after the pen position.
    private let bearing: CGFloat = 1.5

    private func quota(_ label: String, _ value: String = "63%", alert: MenuBarAlertLevel = .none,
                       tint: ResetTint? = nil) -> MenuBarSegment {
        let reset = tint.map { ResetCaption(windowName: "5-hour", at: Date(), countdown: label, tint: $0) }
        return MenuBarSegment(label: label, value: value, remaining: 63, alertLevel: alert, reset: reset)
    }

    // MARK: Left alignment

    func testAGaugeStartsWhereItsCaptionStartsHoweverLongTheCaption() throws {
        for label in ["5h", "1h21m", "5h 1h21m", "7d 6d12h"] {
            let ink = try Ink(.bar(quota(label)), captions: true)

            let caption = try XCTUnwrap(ink.leftmost(in: ink.captionBand), label)
            let gauge = try XCTUnwrap(ink.leftmost(in: ink.valueBand), label)

            XCTAssertEqual(gauge, 0, accuracy: 0.5, "\(label): the gauge starts at the column edge")
            XCTAssertEqual(caption, 0, accuracy: bearing, "\(label): the caption starts at the column edge")
        }
    }

    func testCaptionAndValueStartAtTheColumnEdgeWhicheverIsWider() throws {
        for (label, value) in [("5h", "63%"), ("1h21m", "8%"), ("5h 1h21m", "100%"), ("today", "1.2M")] {
            let ink = try Ink(.segment(quota(label, value)), captions: true)

            XCTAssertEqual(try XCTUnwrap(ink.leftmost(in: ink.captionBand)), 0, accuracy: bearing, label)
            XCTAssertEqual(try XCTUnwrap(ink.leftmost(in: ink.valueBand)), 0, accuracy: bearing, value)
        }
    }

    func testWithoutCaptionsTheValueStartsAtTheColumnEdgeAndItsDotFollowsIt() throws {
        for alert in [MenuBarAlertLevel.warn, .critical] {
            let segment = quota("5h", "8%", alert: alert)
            let width = MenuBarContentView.columnWidth(segment, showCaptions: false)
            let ink = try Ink(.segment(segment), captions: false)

            let textLeft = try XCTUnwrap(ink.leftmost(in: ink.fullHeight, where: \.isNeutral))
            let textRight = try XCTUnwrap(ink.rightmost(in: ink.fullHeight, where: \.isNeutral))
            let dotLeft = try XCTUnwrap(ink.leftmost(in: ink.fullHeight, where: \.isColored))
            let dotRight = try XCTUnwrap(ink.rightmost(in: ink.fullHeight, where: \.isColored))

            XCTAssertEqual(textLeft, 0, accuracy: bearing)
            XCTAssertLessThanOrEqual(dotLeft - textRight, 2.5, "the dot sits right after the value")
            XCTAssertLessThanOrEqual(dotRight, width, "the dot stays inside the width the column declares")
        }
    }

    // MARK: Countdown colour

    func testACountdownColourTintsTheCaptionOnlyNeverTheValueOrTheDot() throws {
        let red = ResetTint(red: 1, green: 0, blue: 0)
        let blue = ResetTint(red: 0, green: 0, blue: 1)

        let tinted = try Ink(.segment(quota("1h21m", "63%", tint: red)), captions: true)
        XCTAssertNotNil(tinted.leftmost(in: tinted.captionBand, where: \.isRed))
        XCTAssertNil(tinted.leftmost(in: tinted.valueBand, where: \.isRed), "the percentage keeps the text colour")

        let alerting = try Ink(.segment(quota("1h21m", "8%", alert: .critical, tint: blue)), captions: true)
        XCTAssertNotNil(alerting.leftmost(in: alerting.captionBand, where: \.isRed), "the alert dot is still red")
        XCTAssertNil(alerting.leftmost(in: alerting.valueBand, where: \.isBlue))
    }

    // MARK: Ink

    /// One element drawn black on clear at 4x, read back pixel by pixel.
    private struct Ink {
        struct Pixel {
            let red, green, blue, alpha: CGFloat
            var isInk: Bool { alpha > 0.25 }
            var isNeutral: Bool { isInk && max(red, green, blue) - min(red, green, blue) < 0.2 }
            var isColored: Bool { isInk && !isNeutral }
            var isRed: Bool { isInk && red > 0.6 && green < 0.4 && blue < 0.4 }
            var isBlue: Bool { isInk && blue > 0.6 && red < 0.4 && green < 0.4 }
        }

        static let height: CGFloat = 22
        /// Drawn past the column's declared width too, so ink that spills
        /// over it is seen rather than cut off by the bitmap.
        static let overscan: CGFloat = 10
        let scale: CGFloat = 4
        let width: CGFloat
        let rep: NSBitmapImageRep

        /// Bands in points from the bottom, from the layout `draw` uses at a
        /// 22-point height: values (and gauges) on a baseline at 2, captions
        /// on one at 13.
        let captionBand: ClosedRange<CGFloat> = 13...Self.height
        let valueBand: ClosedRange<CGFloat> = 0...12.5
        let fullHeight: ClosedRange<CGFloat> = 0...Self.height

        @MainActor
        init(_ element: MenuBarElement, captions: Bool) throws {
            width = MenuBarContentView.width(elements: [element], showCaptions: captions)
            let view = MenuBarContentView()
            view.forcedColor = .black
            view.apply(elements: [element], showCaptions: captions, fillsByUsed: false)
            view.frame = NSRect(x: 0, y: 0, width: width + Self.overscan, height: Self.height)
            rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((width + Self.overscan) * scale),
                pixelsHigh: Int(Self.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
        }

        private func pixel(column: Int, row: Int) -> Pixel? {
            guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { return nil }
            return Pixel(red: color.redComponent, green: color.greenComponent,
                         blue: color.blueComponent, alpha: color.alphaComponent)
        }

        /// Bitmap rows run top-down; the bands are in points from the bottom.
        private func rows(_ band: ClosedRange<CGFloat>) -> ClosedRange<Int> {
            let top = Int(((Self.height - band.upperBound) * scale).rounded())
            let bottom = Int(((Self.height - band.lowerBound) * scale).rounded()) - 1
            return max(0, top)...min(rep.pixelsHigh - 1, bottom)
        }

        private func columns(in band: ClosedRange<CGFloat>, where test: (Pixel) -> Bool) -> [Int] {
            let rows = rows(band)
            return (0..<rep.pixelsWide).filter { column in
                rows.contains { row in pixel(column: column, row: row).map(test) ?? false }
            }
        }

        func leftmost(in band: ClosedRange<CGFloat>, where test: (Pixel) -> Bool = \.isInk) -> CGFloat? {
            columns(in: band, where: test).first.map { CGFloat($0) / scale }
        }

        func rightmost(in band: ClosedRange<CGFloat>, where test: (Pixel) -> Bool = \.isInk) -> CGFloat? {
            columns(in: band, where: test).last.map { CGFloat($0 + 1) / scale }
        }
    }
}
