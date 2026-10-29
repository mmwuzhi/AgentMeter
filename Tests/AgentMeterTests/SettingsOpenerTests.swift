@testable import AgentMeter
import AppKit
import XCTest

/// How Settings is found and shown. The windows here are never put on screen;
/// bringing a visible window forward is checked in the running app.
@MainActor
final class SettingsOpenerTests: XCTestCase {
    private func window(identifier: String? = nil, autosaveName: String? = nil, title: String = "") -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = title
        if let identifier { window.identifier = NSUserInterfaceItemIdentifier(identifier) }
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        return window
    }

    func testTheSettingsWindowIsFoundByItsSwiftUIIdentifierNotItsTitle() {
        let other = window(title: "AgentMeter Settings")
        // The title is the selected tab's, so it says nothing about the window.
        let settings = window(identifier: SettingsOpener.windowIdentifier, title: "Menu Bar")
        XCTAssertTrue(SettingsOpener.settingsWindow(in: [other, settings]) === settings)
        XCTAssertNil(SettingsOpener.settingsWindow(in: [other]))
    }

    func testTheFrameAutosaveNameAlsoIdentifiesIt() {
        let settings = window(autosaveName: SettingsOpener.windowIdentifier)
        XCTAssertTrue(SettingsOpener.settingsWindow(in: [window(), settings]) === settings)
    }

    func testAClosedOrMissingWindowIsOpenedThroughSwiftUI() {
        // No window yet, and one SwiftUI kept after it was closed (or that
        // was withdrawn at launch), both go through `openSettings`.
        XCTAssertEqual(SettingsOpener.plan(for: nil), .open)
        let hidden = window(identifier: SettingsOpener.windowIdentifier)
        XCTAssertFalse(hidden.isVisible)
        XCTAssertEqual(SettingsOpener.plan(for: hidden), .open)
    }

    func testThePopoverOpensSettingsThroughTheOpenerNotASettingsLink() throws {
        // A `SettingsLink` neither activates the app nor brings an open
        // window forward: behind other windows, a click on it did nothing.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(code.contains("SettingsLink"), "\(file.lastPathComponent) uses SettingsLink")
        }
    }
}
