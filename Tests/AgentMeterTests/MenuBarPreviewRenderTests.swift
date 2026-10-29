@testable import AgentMeter
import AppKit
import XCTest

/// Renders menu-bar columns to PNG files for a visual check of their
/// alignment, since this environment cannot capture the menu bar. Skipped
/// unless `AGENTMETER_RENDER_DIR` names an output directory:
///
///     AGENTMETER_RENDER_DIR=/path/to/dir swift test --filter MenuBarPreviewRenderTests
///
/// Off-screen only; nothing is shown. Thin red lines mark where each column
/// starts, so a caption, value or gauge that does not start there stands out.
@MainActor
final class MenuBarPreviewRenderTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTMETER_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("set AGENTMETER_RENDER_DIR to render")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func quota(_ label: String, _ value: String, _ remaining: Double = 63,
                       alert: MenuBarAlertLevel = .none, tint: ResetTint? = nil) -> MenuBarSegment {
        let countdown = label.split(separator: " ").last.map(String.init) ?? label
        let reset = label == "5h" ? nil : ResetCaption(windowName: "5-hour", at: Date(), countdown: countdown, tint: tint)
        return MenuBarSegment(label: label, value: value, remaining: remaining, alertLevel: alert, reset: reset)
    }

    func testRenderColumnAlignment() throws {
        let orange = ResetTint(red: 1, green: 0.55, blue: 0)
        let rows: [(String, [MenuBarElement])] = [
            ("period", [
                .segment(quota("5h", "63%")),
                .segment(quota("7d", "8%", 8, alert: .critical)),
                .bar(quota("5h", "63%")),
                .segment(MenuBarSegment(label: "today", value: "1.2M", remaining: nil, alertLevel: .none)),
            ]),
            ("countdown", [
                .segment(quota("1h21m", "63%", tint: orange)),
                .segment(quota("6d12h", "8%", 8, alert: .critical)),
                .bar(quota("1h21m", "63%")),
                .segment(MenuBarSegment(label: "usd", value: "12.40", remaining: nil, alertLevel: .none)),
            ]),
            ("both", [
                .segment(quota("5h 1h21m", "63%", tint: orange)),
                .segment(quota("7d 6d12h", "100%", 100, alert: .warn)),
                .bar(quota("5h 1h21m", "63%")),
                .bar(quota("7d 6d12h", "18%", 18, alert: .warn)),
            ]),
        ]
        for (name, elements) in rows {
            for captions in [true, false] {
                for dark in [false, true] {
                    try write(strip(elements, captions: captions, dark: dark),
                              name: "columns-\(name)-\(captions ? "captions" : "plain")-\(dark ? "dark" : "light")")
                }
            }
        }
    }

    /// The Settings field strips: scrolled to the start, the middle and the
    /// end, one that fits, and an empty one.
    func testRenderTheFieldStrips() throws {
        let many = (0..<9).map { $0 % 3 == 0 ? "5h \($0)h21m" : ($0 % 3 == 1 ? "7d 6d1\($0)h" : "1h\($0)1m") }
        let cases: [(String, [String], CGFloat, CGFloat?)] = [
            ("many-start", many, 380, 0),
            ("many-middle", many, 380, 0.5),
            ("many-end", many, 380, 1),
            ("narrow-end", ["7d 6d12h", "5h"], 90, 1),
            ("fits", ["5h", "7d"], 380, nil),
            ("empty", [], 380, nil),
        ]
        for (name, labels, width, position) in cases {
            for dark in [false, true] {
                let backing = ChipStripTests.BackingDouble(visible: labels, hidden: [])
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width + 24, height: 62),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                let content = NSView(frame: NSRect(x: 0, y: 0, width: width + 24, height: 62))
                content.wantsLayer = true
                content.layer?.backgroundColor = (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
                window.contentView = content
                let zone = ChipZoneView(zone: .visible, backing: backing)
                backing.register(zone.container, zone: .visible)
                zone.container.configure(signature: "")
                zone.frame = NSRect(x: 12, y: 8, width: width, height: 46)
                content.addSubview(zone)
                content.layoutSubtreeIfNeeded()
                if let position {
                    let clip = zone.scrollView.contentView
                    let maxOffset = zone.container.frame.width - clip.bounds.width
                    clip.scroll(to: NSPoint(x: (maxOffset * position).rounded(), y: 0))
                    zone.scrollView.reflectScrolledClipView(clip)
                }
                CATransaction.flush()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                // AppKit attaches the scroll view's layers on display; the
                // next layout pass puts the edge hints back in front of them.
                zone.needsLayout = true
                content.layoutSubtreeIfNeeded()
                try writeLayers(content, name: "strip-\(name)-\(dark ? "dark" : "light")", scale: 2)
                window.close()
            }
        }
    }

    // MARK: - Rendering

    /// The content view on a menu-bar-like backdrop, with a guide at the left
    /// edge of every column.
    private func strip(_ elements: [MenuBarElement], captions: Bool, dark: Bool) -> NSView {
        let width = MenuBarContentView.width(elements: elements, showCaptions: captions)
        let pad: CGFloat = 8
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: width + pad * 2, height: 24))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        backdrop.appearance = appearance
        var x = pad + MenuBarContentView.horizontalInset
        for element in elements {
            let guide = NSView(frame: NSRect(x: x, y: 0, width: 0.5, height: 24))
            guide.wantsLayer = true
            guide.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
            backdrop.addSubview(guide)
            x += MenuBarContentView.width(elements: [element], showCaptions: captions) + MenuBarContentView.spacing
        }
        let view = MenuBarContentView()
        view.appearance = appearance
        view.apply(elements: elements, showCaptions: captions, fillsByUsed: false)
        view.frame = NSRect(x: pad, y: 0, width: width, height: 24)
        backdrop.addSubview(view)
        return backdrop
    }

    /// Through Core Animation rather than `cacheDisplay`, which leaves out
    /// layers that are not a view's own drawing (the strips' edge fades).
    private func writeLayers(_ view: NSView, name: String, scale: CGFloat) throws {
        view.displayIfNeeded()
        let layer = try XCTUnwrap(view.layer)
        let size = view.bounds.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    /// At three times the point size, so a half-point offset is visible.
    private func write(_ view: NSView, name: String, scale: CGFloat = 3) throws {
        let size = view.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
