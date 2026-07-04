import AppKit
import SwiftUI

/// The single source of truth for how a menu-bar arrangement is drawn — used both
/// for the real status item and (via `MenuBarElementView`) the Settings preview
/// chips, so the two are pixel-identical. Mirrors Stats' `Mini` widget: an optional
/// provider icon plus one compact column per item (caption over value), drawn live in
/// `draw(_:)` at native backing scale via baseline-anchored text.
final class MenuBarContentView: NSView {
    private var elements: [MenuBarElement] = []
    private var showCaptions = true

    /// When set, text/icon use this color instead of the menu-bar-adaptive one
    /// (the Settings chips render on a fixed dark bar, so they force white).
    var forcedColor: NSColor?
    /// The status item passes clicks through to its button; the chips don't.
    var passesClicksThrough = false

    // Layout constants (Stats-like horizontal columns).
    static let iconSize: CGFloat = 15
    static let spacing: CGFloat = 4
    static let horizontalInset: CGFloat = 0
    static let textYOffset: CGFloat = 2
    static let statusItemOverhang: CGFloat = 6

    // iStat-style compact two-line readout: balanced captions and restrained values.
    static func captionFont() -> NSFont { .systemFont(ofSize: 8.5, weight: .regular) }
    static func valueFont(showCaptions: Bool) -> NSFont {
        .systemFont(ofSize: showCaptions ? 11 : 14, weight: .regular)
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }

    func apply(elements: [MenuBarElement], showCaptions: Bool) {
        self.elements = elements
        self.showCaptions = showCaptions
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
        let alertPad: CGFloat = seg.alertLevel == .none ? 0 : 6
        return ceil(max(lw, vw)) + alertPad
    }

    /// Total width for an arrangement (icon + columns + uniform gaps).
    static func width(elements: [MenuBarElement], showCaptions: Bool) -> CGFloat {
        guard !elements.isEmpty else { return iconSize + horizontalInset * 2 }
        let pieces: [CGFloat] = elements.map {
            switch $0 {
            case .icon: return iconSize
            case .segment(let s): return columnWidth(s, showCaptions: showCaptions)
            }
        }
        let gaps = spacing * CGFloat(max(0, pieces.count - 1))
        return pieces.reduce(0, +) + gaps + horizontalInset * 2
    }

    static func statusLength(forVisualWidth width: CGFloat) -> CGFloat {
        max(1, width - statusItemOverhang * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        let fg = foreground

        // Never vanish: with nothing enabled, still show a provider icon as a click target.
        guard !elements.isEmpty else {
            drawIcon(.provider(.codex), at: Self.horizontalInset, height: height, color: fg)
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

        let captionHeight = captionFont.pointSize + 1
        let valueHeight = valueFont.pointSize + 1
        let lineGap: CGFloat = -1
        let stackHeight = showCaptions ? captionHeight + valueHeight + lineGap : valueHeight
        let valueY = max(0, floor((height - stackHeight) / 2) + Self.textYOffset)
        let captionY = valueY + valueHeight + lineGap
        let alertDotY = showCaptions ? captionY + (captionHeight - 4) / 2 - 2 : valueY + valueHeight - 5

        var x: CGFloat = Self.horizontalInset
        for element in elements {
            switch element {
            case .icon(let icon):
                drawIcon(icon, at: x, height: height, color: fg)
                x += Self.iconSize + Self.spacing
            case .segment(let s):
                let w = Self.columnWidth(s, showCaptions: showCaptions)
                if showCaptions {
                    NSAttributedString(string: s.label, attributes: captionAttr)
                        .draw(with: NSRect(x: x, y: captionY, width: w, height: captionHeight), options: [], context: nil)
                    NSAttributedString(string: s.value, attributes: valueAttr)
                        .draw(with: NSRect(x: x, y: valueY, width: w, height: valueHeight), options: [], context: nil)
                } else {
                    let vy = (height - valueFont.pointSize) / 2
                    NSAttributedString(string: s.value, attributes: valueAttr)
                        .draw(with: NSRect(x: x, y: vy, width: w, height: valueFont.pointSize + 1), options: [], context: nil)
                }
                drawAlertDot(
                    for: s,
                    at: x,
                    width: w,
                    captionAttributes: captionAttr,
                    valueAttributes: valueAttr,
                    y: alertDotY
                )
                x += w + Self.spacing
            }
        }
    }

    private func drawIcon(_ icon: MenuBarIcon, at x: CGFloat, height: CGFloat, color: NSColor) {
        switch icon {
        case .provider(let provider):
            let rect = NSRect(x: x, y: (height - Self.iconSize) / 2,
                              width: Self.iconSize, height: Self.iconSize)
            if let image = Self.templateIcon(for: provider) {
                drawTemplateImage(image, in: rect, color: color)
                return
            }
            let symbolName: String
            switch provider {
            case .codex: symbolName = "terminal"
            case .claude: symbolName = "text.bubble"
            case .copilot: symbolName = "sparkles"
            }
            let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize - 1, weight: .regular)
                .applying(.init(paletteColors: [color]))
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: provider.displayName)?
                .withSymbolConfiguration(config)
            symbol?.draw(in: NSRect(x: x, y: (height - Self.iconSize) / 2,
                                    width: Self.iconSize, height: Self.iconSize))
        }
    }

    private func drawTemplateImage(_ image: NSImage, in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        color.setFill()
        rect.fill()
        image.draw(in: rect,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .destinationIn,
                   fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static var templateIconCache: [Provider: NSImage] = [:]

    static func templateIcon(for provider: Provider) -> NSImage? {
        if let cached = templateIconCache[provider] { return cached }
        let image: NSImage?
        switch provider {
        case .codex:
            image = fileTemplateIcon(at: "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png")
        case .claude:
            image = svgTemplateIcon(Self.claudeSVG)
                ?? fileTemplateIcon(at: "/Applications/Claude.app/Contents/Resources/TrayIconTemplate@2x.png")
        case .copilot:
            image = svgTemplateIcon(Self.githubCopilotSVG)
        }
        if let image {
            image.isTemplate = true
            templateIconCache[provider] = image
        }
        return image
    }

    private static func fileTemplateIcon(at path: String) -> NSImage? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.size = NSSize(width: iconSize, height: iconSize)
        return image
    }

    private static func svgTemplateIcon(_ svg: String) -> NSImage? {
        guard let data = svg.data(using: .utf8),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: iconSize, height: iconSize)
        return image
    }

    private static let claudeSVG = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"/></svg>
    """

    private static let githubCopilotSVG = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z"/></svg>
    """

    /// Low-quota cue: a tiny dot inside the specific quota column that triggered it.
    private func drawAlertDot(
        for segment: MenuBarSegment,
        at x: CGFloat,
        width: CGFloat,
        captionAttributes: [NSAttributedString.Key: Any],
        valueAttributes: [NSAttributedString.Key: Any],
        y: CGFloat
    ) {
        let color: NSColor
        switch segment.alertLevel {
        case .none: return
        case .warn: color = .systemYellow
        case .critical: color = .systemRed
        }
        let size: CGFloat = 4
        let textWidth: CGFloat
        if showCaptions {
            textWidth = NSAttributedString(string: segment.label, attributes: captionAttributes).size().width
        } else {
            textWidth = NSAttributedString(string: segment.value, attributes: valueAttributes).size().width
        }
        let textLeft = showCaptions ? x : x + max(0, (width - textWidth) / 2)
        let rect = NSRect(x: ceil(textLeft + textWidth + 1), y: y, width: size, height: size)
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
        v.apply(elements: elements, showCaptions: showCaptions)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarContentView, context: Context) -> CGSize? {
        CGSize(width: MenuBarContentView.width(elements: elements, showCaptions: showCaptions),
               height: barHeight)
    }
}
