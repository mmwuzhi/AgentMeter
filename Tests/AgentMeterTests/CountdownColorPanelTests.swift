@testable import AgentMeter
import AppKit
import XCTest

/// The colour panel behind Settings › Claude Quota Labels: only a colour the
/// user picks is stored, for the window the panel was opened for. Uses the
/// real shared panel, never shown, and a defaults suite of its own.
@MainActor
final class CountdownColorPanelTests: XCTestCase, @unchecked Sendable {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var controller: CountdownColorPanel!
    private var shown = 0
    /// What the panel does as it goes on screen, in place of ordering it in.
    private var onShow: ((NSColorPanel) -> Void)?
    private let panel = NSColorPanel.shared

    override func setUpWithError() throws {
        try MainActor.assumeIsolated {
            suiteName = "com.shu.agentmeter.tests.countdown-colors.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            controller = CountdownColorPanel(defaults: defaults, panel: { NSColorPanel.shared },
                                             show: { [weak self] panel in
                                                 self?.shown += 1
                                                 self?.onShow?(panel)
                                             })
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            controller.stop()
            defaults.removePersistentDomain(forName: suiteName)
            super.tearDown()
        }
    }

    private var stored: [String: String] {
        ResetCaptionColors.decode(defaults.string(forKey: ResetCaptionColors.defaultsKey) ?? "")
    }

    /// Lets anything the panel posts on its own arrive.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    func testOpeningThePanelStoresNothing() {
        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: .white, until: nil)
        settle()

        XCTAssertEqual(shown, 1)
        XCTAssertEqual(controller.editingKey, "claude:five_hour")
        XCTAssertEqual(stored, [:], "a window opened from Automatic stays Automatic")
        XCTAssertNil(defaults.object(forKey: ResetCaptionColors.defaultsKey))
    }

    func testThePanelReportsItsOwnColourChangesSoTheStartingColourMustBeSetDetached() {
        // Why `edit` attaches last: once attached, a colour set in code is
        // reported like a pick.
        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: .white, until: nil)

        panel.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        settle()

        XCTAssertEqual(stored, ["claude:five_hour": "FF0000"])
    }

    func testThePanelIsShownBeforeItIsAttachedSoWhatItDoesOnScreenIsNoPick() {
        var attachedWhenShown: String?? = .none
        onShow = { [weak self] panel in
            attachedWhenShown = .some(self?.controller.editingKey)
            // A panel that re-sets the colour it was given as it appears,
            // in another colour space.
            panel.color = NSColor.white.usingColorSpace(.deviceRGB) ?? .white
        }

        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: .white, until: nil)
        settle()

        XCTAssertEqual(attachedWhenShown, .some(nil), "not attached yet when shown")
        XCTAssertEqual(stored, [:])
    }

    func testAReportOfTheStartingColourAfterAttachingIsNoPickUntilTheUserMovesOffIt() {
        let start = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        onShow = { panel in
            // Arrives a moment later, once attached, converted.
            DispatchQueue.main.async { panel.color = start.usingColorSpace(.genericRGB) ?? start }
        }

        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: start, until: nil)
        settle()
        XCTAssertEqual(stored, [:], "the panel settling on its starting colour")

        controller.choose(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        controller.choose(start)
        XCTAssertEqual(stored, ["claude:five_hour": ResetCaptionColors.hex(red: 0.2, green: 0.4, blue: 0.6)],
                       "once the user has moved off it, going back to it is a pick")
    }

    func testClosingTheSettingsWindowStopsThePanel() {
        let settings = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                                styleMask: [.titled, .closable], backing: .buffered, defer: true)
        settings.isReleasedWhenClosed = false
        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: .white, until: settings)

        settings.close()
        controller.choose(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))

        XCTAssertNil(controller.editingKey)
        XCTAssertEqual(stored, [:])
    }

    func testAnotherWindowClosingLeavesThePanelAttached() {
        let settings = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                                styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                             styleMask: [.titled, .closable], backing: .buffered, defer: true)
        for window in [settings, other] { window.isReleasedWhenClosed = false }
        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: .white, until: settings)

        other.close()
        controller.choose(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))

        XCTAssertEqual(stored, ["claude:five_hour": "FF0000"])
        settings.close()
    }

    func testAPickIsStoredForTheWindowBeingEditedOnly() {
        defaults.set(ResetCaptionColors.encode(["claude:seven_day": "00FF00"]), forKey: ResetCaptionColors.defaultsKey)
        controller.edit(key: "claude:seven_day_fable", title: "Weekly (Fable) Countdown", startingAt: .white, until: nil)

        controller.choose(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))

        XCTAssertEqual(stored, ["claude:seven_day": "00FF00", "claude:seven_day_fable": "0000FF"])
        XCTAssertEqual(ResetCaptionColors.tint(forKey: "claude:seven_day_fable",
                                               in: defaults.string(forKey: ResetCaptionColors.defaultsKey) ?? ""),
                       ResetTint(red: 0, green: 0, blue: 1))
    }

    func testReopeningForAnotherWindowMovesTheTargetWithoutCopyingTheColour() {
        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: .white, until: nil)
        controller.choose(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))

        controller.edit(key: "claude:seven_day", title: "Weekly Countdown", startingAt: .white, until: nil)
        settle()

        XCTAssertEqual(stored, ["claude:five_hour": "FF0000"])
        XCTAssertEqual(panel.title, "Weekly Countdown", "the one panel says which countdown it is for")
    }

    func testAfterStoppingThePanelWritesNothingAndKeepsItsOwnTitle() {
        let title = panel.title
        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: .white, until: nil)

        controller.stop()
        panel.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        controller.choose(.red)
        settle()

        XCTAssertNil(controller.editingKey)
        XCTAssertEqual(stored, [:])
        XCTAssertEqual(panel.title, title)
    }

    func testUseAutomaticOnAnotherRowLeavesTheOpenPanelAttached() {
        controller.edit(key: "claude:five_hour", title: "5-hour Countdown", startingAt: .white, until: nil)

        controller.stop(editing: "claude:seven_day")
        XCTAssertEqual(controller.editingKey, "claude:five_hour")

        controller.stop(editing: "claude:five_hour")
        XCTAssertNil(controller.editingKey)
    }
}
