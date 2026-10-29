import AppKit
import Foundation
@testable import AgentMeter
import XCTest

/// The caption mode, the per-quota countdown colours and the Settings picker
/// order. The countdown arithmetic itself is `ResetCountdownTests`.
@MainActor
final class ResetCaptionSettingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    override func tearDown() {
        for key in ["menuBarSlotsConfig", "menuBarItemsConfig.claude", ResetCaptionMode.defaultsKey,
                    ResetCaptionColors.defaultsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: Mode

    func testWindowModeIsTheDefaultAndLeavesEveryCaptionAlone() {
        // Nothing stored: what the app always showed, whatever the resets say,
        // with no countdown computed and so nothing for the ticker to schedule.
        let model = claudeModel([
            window("five_hour", "5-hour", resetsIn: 3 * hour),
            window("seven_day", "Weekly", resetsIn: -60),
            window("seven_day_fable", "Weekly (Fable)", resetsIn: nil),
        ])
        showAll(model)

        let elements = MenuBarLayout.activeElements(model, slot: .claude, now: now)
        let segments = elements.compactMap(\.segment)

        XCTAssertEqual(ResetCaptionMode.current, .window)
        XCTAssertEqual(segments.map(\.label), ["5h", "7d", "7d"])
        XCTAssertEqual(segments.compactMap(\.reset), [])
        XCTAssertNil(MenuBarLayout.nextCountdownChange(in: elements, after: now))
    }

    func testAnUnrecognisedStoredModeReadsAsWindow() {
        UserDefaults.standard.set("seconds", forKey: ResetCaptionMode.defaultsKey)

        XCTAssertEqual(ResetCaptionMode.current, .window)
    }

    func testBothModeShowsTheCodeThenTheCountdown() {
        UserDefaults.standard.set("both", forKey: ResetCaptionMode.defaultsKey)
        let model = claudeModel([
            window("five_hour", "5-hour", resetsIn: 3 * hour + 23 * 60),
            window("seven_day", "Weekly", resetsIn: 6 * day + 12 * hour),
            window("seven_day_fable", "Weekly (Fable)", resetsIn: nil),
        ])
        showAll(model)

        let segments = MenuBarLayout.activeSegments(model, slot: .claude, now: now)

        XCTAssertEqual(segments.map(\.label), ["5h 3h23m", "7d 6d12h", "7d"])
        XCTAssertEqual(segments.compactMap(\.reset?.countdown), ["3h23m", "6d12h"])
        XCTAssertTrue(zip(segments, segments.compactMap(\.reset)).allSatisfy { $0.label.hasSuffix($1.countdown) })
    }

    func testBothModeFallsBackToTheBareCodeWithoutAUsableReset() {
        UserDefaults.standard.set("both", forKey: ResetCaptionMode.defaultsKey)
        let model = claudeModel([window("five_hour", "5-hour", resetsIn: 90)])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:five_hour", enabled: true)], for: .claude)

        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .claude, now: now).map(\.label), ["5h 2m"])
        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .claude, now: now.addingTimeInterval(120)).map(\.label),
                       ["5h"])
    }

    func testBothModeTooltipNamesTheWindowAndTheCountdownOnce() {
        UserDefaults.standard.set("both", forKey: ResetCaptionMode.defaultsKey)
        let model = claudeModel([window("five_hour", "5-hour", resetsIn: 3 * hour + 23 * 60)])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:five_hour", enabled: true)], for: .claude)

        let segment = MenuBarLayout.activeSegments(model, slot: .claude, now: now).first

        XCTAssertEqual(segment?.spokenText(end: "left"), "5-hour 63% left (resets in 3h23m)")
    }

    // MARK: Colours

    func testColorsAreReadDefensively() {
        XCTAssertEqual(ResetCaptionColors.decode(""), [:])
        XCTAssertEqual(ResetCaptionColors.decode("not json"), [:])
        XCTAssertEqual(ResetCaptionColors.decode(#"{"claude:seven_day":"FF8800"}"#), ["claude:seven_day": "FF8800"])
        // Anything that is not exactly six hex digits is dropped, not guessed at.
        let bad = #"{"a":"ZZZZZZ","b":"12345","c":"+12345","d":"1234567","e":"","f":"-00000","g":"00FF00"}"#
        XCTAssertEqual(ResetCaptionColors.decode(bad), ["g": "00FF00"])
    }

    func testHexAndTintRoundTrip() {
        let tint = ResetCaptionColors.tint(hex: "FF8000")
        XCTAssertEqual(tint, ResetTint(red: 1, green: 128 / 255, blue: 0))
        XCTAssertEqual(ResetCaptionColors.hex(red: 1, green: 128 / 255, blue: 0), "FF8000")
        XCTAssertEqual(ResetCaptionColors.hex(red: -3, green: 7, blue: 0.5), "00FF80", "components are clamped")
        let stored = ResetCaptionColors.encode(["claude:five_hour": "0A0B0C"])
        XCTAssertEqual(ResetCaptionColors.tint(forKey: "claude:five_hour", in: stored),
                       ResetCaptionColors.tint(hex: "0A0B0C"))
    }

    func testEachWeeklyTakesItsOwnColor() {
        setColors(["claude:seven_day": "FF0000", "claude:seven_day_fable": "0000FF"])
        let model = claudeModel([
            window("five_hour", "5-hour", resetsIn: 3 * hour),
            window("seven_day", "Weekly", resetsIn: 6 * day),
            window("seven_day_fable", "Weekly (Fable)", resetsIn: 6 * day),
        ])
        showAll(model)

        let tints = tintsByWindow(model)

        XCTAssertEqual(tints, [
            "5-hour": nil,
            "Weekly": ResetCaptionColors.tint(hex: "FF0000"),
            "Weekly (Fable)": ResetCaptionColors.tint(hex: "0000FF"),
        ])
    }

    func testAColorStaysWithItsQuotaWhenTheFieldsAreReordered() {
        setColors(["claude:seven_day": "FF0000", "claude:seven_day_fable": "0000FF"])
        let model = claudeModel([
            window("seven_day", "Weekly", resetsIn: 6 * day),
            window("seven_day_fable", "Weekly (Fable)", resetsIn: 6 * day),
        ])
        let before = tintsByWindow(model, order: ["seven_day", "seven_day_fable"])

        // What a drag does: the layout array is saved again in another order.
        let after = tintsByWindow(model, order: ["seven_day_fable", "seven_day"])

        XCTAssertEqual(before, after)
        XCTAssertNotEqual(after["Weekly"] ?? nil, after["Weekly (Fable)"] ?? nil)
    }

    func testTheTextAndBarFieldsOfOneQuotaShareItsColor() {
        setColors(["claude:five_hour": "00FF00"])
        UserDefaults.standard.set("countdown", forKey: ResetCaptionMode.defaultsKey)
        let model = claudeModel([window("five_hour", "5-hour", resetsIn: 3 * hour)])
        MenuBarLayout.save([
            MenuBarItem(key: "q:claude:five_hour", enabled: true),
            MenuBarItem(key: "b:claude:five_hour", enabled: true),
        ], for: .claude)

        let tints = MenuBarLayout.activeSegments(model, slot: .claude, now: now).map { $0.reset?.tint }

        XCTAssertEqual(tints, [ResetCaptionColors.tint(hex: "00FF00"), ResetCaptionColors.tint(hex: "00FF00")])
    }

    func testNoChoiceMeansNoTint() {
        UserDefaults.standard.set("countdown", forKey: ResetCaptionMode.defaultsKey)
        let model = claudeModel([window("five_hour", "5-hour", resetsIn: 3 * hour)])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:five_hour", enabled: true)], for: .claude)

        let reset = MenuBarLayout.activeSegments(model, slot: .claude, now: now).first?.reset

        XCTAssertNotNil(reset, "a countdown is shown, so the missing tint is the choice")
        XCTAssertNil(reset?.tint)
    }

    func testWindowModeIgnoresTheColors() {
        setColors(["claude:five_hour": "00FF00"])
        UserDefaults.standard.set("window", forKey: ResetCaptionMode.defaultsKey)
        let model = claudeModel([window("five_hour", "5-hour", resetsIn: 3 * hour)])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:five_hour", enabled: true)], for: .claude)

        let segment = MenuBarLayout.activeSegments(model, slot: .claude, now: now).first

        XCTAssertEqual(segment?.label, "5h")
        XCTAssertNil(segment?.reset)
    }

    // MARK: Drawing the caption

    private let base: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor.white,
    ]

    private func color(of text: NSAttributedString, at index: Int) -> NSColor? {
        (text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    }

    func testOnlyTheCountdownPartOfABothCaptionIsColoured() {
        let tint = ResetTint(red: 1, green: 0, blue: 0)
        let segment = MenuBarSegment(
            label: "5h 3h23m", value: "63%", remaining: 63, alertLevel: .none,
            reset: ResetCaption(windowName: "5-hour", at: now, countdown: "3h23m", tint: tint))

        let text = MenuBarContentView.captionString(segment, attributes: base)

        XCTAssertEqual(text.string, "5h 3h23m")
        XCTAssertEqual(color(of: text, at: 0), NSColor.white.usingColorSpace(.sRGB))
        XCTAssertEqual(color(of: text, at: 2), NSColor.white.usingColorSpace(.sRGB), "the space is not tinted")
        XCTAssertEqual(color(of: text, at: 3), NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(color(of: text, at: 7), NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    }

    func testACountdownOnlyCaptionIsColouredWhole() {
        let tint = ResetTint(red: 0, green: 0, blue: 1)
        let segment = MenuBarSegment(
            label: "3h23m", value: "63%", remaining: 63, alertLevel: .none,
            reset: ResetCaption(windowName: "5-hour", at: now, countdown: "3h23m", tint: tint))

        let text = MenuBarContentView.captionString(segment, attributes: base)

        XCTAssertEqual((0..<text.length).compactMap { color(of: text, at: $0) },
                       Array(repeating: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), count: 5))
    }

    func testWithoutAChoiceTheCaptionKeepsTheSystemColor() {
        for reset in [nil, ResetCaption(windowName: "5-hour", at: now, countdown: "3h23m", tint: nil)] {
            let segment = MenuBarSegment(label: "5h 3h23m", value: "63%", remaining: 63, alertLevel: .none,
                                         reset: reset)

            let text = MenuBarContentView.captionString(segment, attributes: base)

            XCTAssertEqual((0..<text.length).compactMap { color(of: text, at: $0) },
                           Array(repeating: NSColor.white.usingColorSpace(.sRGB)!, count: text.length))
        }
    }

    func testAStaleQuotaFadesTheChosenColorToo() {
        let segment = MenuBarSegment(
            label: "3h23m", value: "63%", remaining: 63, alertLevel: .none,
            reset: ResetCaption(windowName: "5-hour", at: now, countdown: "3h23m",
                                tint: ResetTint(red: 1, green: 0, blue: 0)))

        let text = MenuBarContentView.captionString(segment, attributes: base, dimmed: true)

        XCTAssertEqual(color(of: text, at: 0)?.alphaComponent ?? 0, 0.45, accuracy: 0.001)
    }

    func testATintOnACaptionThatLostItsCountdownIsIgnored() {
        // The invariant is that the label ends with the countdown; if it ever
        // does not, nothing is coloured rather than the wrong characters.
        let segment = MenuBarSegment(
            label: "5h", value: "63%", remaining: 63, alertLevel: .none,
            reset: ResetCaption(windowName: "5-hour", at: now, countdown: "3h23m",
                                tint: ResetTint(red: 1, green: 0, blue: 0)))

        let text = MenuBarContentView.captionString(segment, attributes: base)

        XCTAssertEqual(color(of: text, at: 0), NSColor.white.usingColorSpace(.sRGB))
    }

    func testBothModeCaptionWidthStaysCompact() {
        // Wider than the countdown alone by the code; the bound catches a
        // format that suddenly gets long.
        let both = MenuBarContentView.columnWidth(
            MenuBarSegment(label: "7d 23h59m", value: "63%", remaining: 63, alertLevel: .none), showCaptions: true)
        let countdown = MenuBarContentView.columnWidth(
            MenuBarSegment(label: "23h59m", value: "63%", remaining: 63, alertLevel: .none), showCaptions: true)

        XCTAssertGreaterThan(both, countdown)
        XCTAssertLessThanOrEqual(both, 62)
    }

    // MARK: Provider picker order

    func testPickerListsProvidersAlphabetically() {
        XCTAssertEqual(MenuBarSlot.alphabetical, [.claude, .codex, .copilot])
    }

    func testPickerOrderDoesNotTouchSlotIdentityOrMenuBarOrder() {
        // `allCases` is the menu bar's slot order and the raw values are the
        // stored ids; only the picker's listing is sorted.
        XCTAssertEqual(MenuBarSlot.allCases, [.codex, .claude, .copilot])
        XCTAssertEqual(MenuBarSlot.alphabetical.map(\.rawValue).sorted(), ["claude", "codex", "copilot"])
        UserDefaults.standard.removeObject(forKey: "menuBarSlotsConfig")
        XCTAssertEqual(MenuBarSlots.visibleSlots(), [.codex, .claude])
        XCTAssertEqual(MenuBarSlots.merged().map(\.item.key), ["codex", "claude", "copilot"])
    }

    // MARK: Preview signature

    func testEveryDisplayPreferenceChangesThePreviewSignature() {
        func signature(captions: Bool = true, used: Bool = false, mode: ResetCaptionMode = .window,
                       colors: String = "") -> String {
            MenuBarPreviewSignature.make(showCaptions: captions, quotaShowsUsed: used,
                                         resetCaptionMode: mode, resetColors: colors)
        }
        let base = signature()

        XCTAssertEqual(base, signature())
        XCTAssertNotEqual(base, signature(captions: false))
        XCTAssertNotEqual(base, signature(used: true))
        XCTAssertNotEqual(base, signature(mode: .countdown))
        XCTAssertNotEqual(signature(mode: .countdown), signature(mode: .both))
        XCTAssertNotEqual(base, signature(colors: #"{"claude:five_hour":"00FF00"}"#))
    }

    // MARK: Fixtures

    private func window(_ id: String, _ label: String, resetsIn: TimeInterval?) -> QuotaWindow {
        QuotaWindow(id: id, label: label, usedPercent: 37, resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                    cycle: ClaudeOAuthFetcher.cycle(forWindowID: id))
    }

    private func claudeModel(_ windows: [QuotaWindow]) -> AppViewModel {
        let model = AppViewModel(snapshot: nil, storedLifetimeSpend: [])
        model.claude = ProviderState(
            provider: .claude,
            quota: QuotaSnapshot(provider: .claude, windows: windows, source: .oauth,
                                 planType: "max", fetchedAt: now, note: nil),
            usage: .empty(.claude))
        return model
    }

    private func showAll(_ model: AppViewModel) {
        MenuBarLayout.save(model.claude.quota.windows.map {
            MenuBarItem(key: "q:claude:\($0.id)", enabled: true)
        }, for: .claude)
    }

    private func setColors(_ colors: [String: String]) {
        UserDefaults.standard.set(ResetCaptionColors.encode(colors), forKey: ResetCaptionColors.defaultsKey)
    }

    /// The tint each window's column ends up with, keyed by window name, for
    /// the fields saved in `order` (the model's own order when nil).
    private func tintsByWindow(_ model: AppViewModel, order: [String]? = nil) -> [String: ResetTint?] {
        UserDefaults.standard.set("countdown", forKey: ResetCaptionMode.defaultsKey)
        let ids = order ?? model.claude.quota.windows.map(\.id)
        MenuBarLayout.save(ids.map { MenuBarItem(key: "q:claude:\($0)", enabled: true) }, for: .claude)
        let segments = MenuBarLayout.activeSegments(model, slot: .claude, now: now)
        return Dictionary(uniqueKeysWithValues: segments.compactMap { segment in
            segment.reset.map { ($0.windowName, $0.tint) }
        })
    }
}
