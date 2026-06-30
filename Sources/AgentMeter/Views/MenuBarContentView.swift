import AppKit
import SwiftUI

/// The single source of truth for how a menu-bar arrangement is drawn — used both
/// for the real status item and (via `MenuBarElementView`) the Settings preview
/// chips, so the two are pixel-identical. Mirrors Stats' `Mini` widget: an optional
/// gauge glyph plus one compact column per item (caption over value), drawn live in
/// `draw(_:)` at native backing scale via baseline-anchored text.
final class MenuBarContentView: NSView {
    private var elements: [MenuBarElement] = []
    private var showCaptions = true
    private var alertColor: NSColor?

    /// When set, text/icon use this color instead of the menu-bar-adaptive one
    /// (the Settings chips render on a fixed dark bar, so they force white).
    var forcedColor: NSColor?
    /// The status item passes clicks through to its button; the chips don't.
    var passesClicksThrough = false

    // Layout constants (Stats-like horizontal columns).
    static let iconSize: CGFloat = 15
    static let spacing: CGFloat = 6  // between elements
    static let colPad: CGFloat = 3   // slack inside a column

    // Stats' Mini fonts, verbatim: caption 7pt .light, value 12pt .regular (14 when
    // captions are hidden).
    static func captionFont() -> NSFont { .systemFont(ofSize: 7, weight: .light) }
    static func valueFont(showCaptions: Bool) -> NSFont {
        .systemFont(ofSize: showCaptions ? 12 : 14, weight: .regular)
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }

    func apply(elements: [MenuBarElement], showCaptions: Bool, alertColor: NSColor?) {
        self.elements = elements
        self.showCaptions = showCaptions
        self.alertColor = alertColor
        needsDisplay = true
    }

    private var foreground: NSColor {
        if let forcedColor { return forcedColor }
        switch NSAppearance.currentDrawing().name {
        case .darkAqua, .vibrantDark,
             .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
            return .white
        default:
            return .textColor
        }
    }

    /// Width of one value column (sizing only; color-independent).
    static func columnWidth(_ seg: MenuBarSegment, showCaptions: Bool) -> CGFloat {
        let cFont = captionFont(), vFont = valueFont(showCaptions: showCaptions)
        let lw = showCaptions ? NSAttributedString(string: seg.label, attributes: [.font: cFont]).size().width : 0
        let vw = NSAttributedString(string: seg.value, attributes: [.font: vFont]).size().width
        return ceil(max(lw, vw)) + colPad
    }

    /// Total width for an arrangement (icon + columns + uniform gaps).
    static func width(elements: [MenuBarElement], showCaptions: Bool) -> CGFloat {
        guard !elements.isEmpty else { return iconSize + 2 }
        let pieces: [CGFloat] = elements.map {
            switch $0 {
            case .icon: return iconSize
            case .segment(let s): return columnWidth(s, showCaptions: showCaptions)
            }
        }
        let gaps = spacing * CGFloat(max(0, pieces.count - 1))
        return pieces.reduce(0, +) + gaps + 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        let fg = foreground

        // Never vanish: with nothing enabled, still show the gauge as a click target.
        guard !elements.isEmpty else {
            drawIcon(at: 0, height: height, color: fg)
            drawDot(in: height)
            return
        }

        let captionFont = Self.captionFont()
        let valueFont = Self.valueFont(showCaptions: showCaptions)
        let style = NSMutableParagraphStyle()
        style.alignment = showCaptions ? .left : .center
        let captionAttr: [NSAttributedString.Key: Any] = [
            .font: captionFont, .foregroundColor: fg, .paragraphStyle: style]
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: valueFont, .foregroundColor: fg, .paragraphStyle: style]

        // Stats draws via `str.draw(with:)` where the rect origin is the BASELINE —
        // no line-height padding, so caption and value pack tightly. Its view is inset
        // 2px from the bar bottom, so absolute baselines are value y=3, caption y=14.
        let marginY: CGFloat = 2
        var x: CGFloat = 0
        for element in elements {
            switch element {
            case .icon:
                drawIcon(at: x, height: height, color: fg)
                x += Self.iconSize + Self.spacing
            case .segment(let s):
                let w = Self.columnWidth(s, showCaptions: showCaptions)
                if showCaptions {
                    NSAttributedString(string: s.label, attributes: captionAttr)
                        .draw(with: NSRect(x: x, y: marginY + 12, width: w, height: 7), options: [], context: nil)
                    NSAttributedString(string: s.value, attributes: valueAttr)
                        .draw(with: NSRect(x: x, y: marginY + 1, width: w, height: valueFont.pointSize + 1), options: [], context: nil)
                } else {
                    let vy = (height - valueFont.pointSize) / 2
                    NSAttributedString(string: s.value, attributes: valueAttr)
                        .draw(with: NSRect(x: x, y: vy, width: w, height: valueFont.pointSize + 1), options: [], context: nil)
                }
                x += w + Self.spacing
            }
        }
        drawDot(in: height)
    }

    private func drawIcon(at x: CGFloat, height: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                             accessibilityDescription: "AgentMeter")?
            .withSymbolConfiguration(config)
        symbol?.draw(in: NSRect(x: x, y: (height - Self.iconSize) / 2,
                                width: Self.iconSize, height: Self.iconSize))
    }

    /// Low-quota cue: a 5pt colored dot tucked into the top-right corner.
    private func drawDot(in height: CGFloat) {
        guard let color = alertColor else { return }
        let size: CGFloat = 5
        let rect = NSRect(x: bounds.width - size - 1, y: height - size - 2, width: size, height: size)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: size / 2, yRadius: size / 2).fill()
    }
}

/// SwiftUI wrapper so the Settings chips render through the exact same drawing code
/// as the menu bar (forced white on the dark chip bar; no alert dot).
struct MenuBarElementView: NSViewRepresentable {
    let elements: [MenuBarElement]
    let showCaptions: Bool
    var color: NSColor = .white
    var barHeight: CGFloat = 22

    func makeNSView(context: Context) -> MenuBarContentView {
        let v = MenuBarContentView()
        v.forcedColor = color
        return v
    }

    func updateNSView(_ v: MenuBarContentView, context: Context) {
        v.forcedColor = color
        v.apply(elements: elements, showCaptions: showCaptions, alertColor: nil)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarContentView, context: Context) -> CGSize? {
        CGSize(width: MenuBarContentView.width(elements: elements, showCaptions: showCaptions),
               height: barHeight)
    }
}
