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
