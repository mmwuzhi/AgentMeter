import Foundation
@testable import AgentMeter
import XCTest

@MainActor
final class MenuBarResetCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        UserDefaults.standard.set(ResetCaptionMode.countdown.rawValue, forKey: ResetCaptionMode.defaultsKey)
    }

    override func tearDown() {
        for key in ["menuBarSlotsConfig", "menuBarItemsConfig.codex", "menuBarItemsConfig.claude",
                    "menuBarItemsConfig.copilot", QuotaDisplay.defaultsKey,
                    ResetCaptionMode.defaultsKey, ResetCaptionColors.defaultsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func setMode(_ mode: ResetCaptionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: ResetCaptionMode.defaultsKey)
    }

    private func setColors(_ colors: [String: String]) {
        UserDefaults.standard.set(ResetCaptionColors.encode(colors), forKey: ResetCaptionColors.defaultsKey)
    }

    // MARK: Three windows, three resets

    func testEachClaudeWindowCountsDownToItsOwnReset() {
        let model = claudeModel(windows: [
            window("five_hour", "5-hour", used: 37, resetsIn: 3 * hour + 23 * 60),
            window("seven_day", "Weekly", used: 13, resetsIn: 6 * day + 12 * hour),
            window("seven_day_fable", "Weekly (Fable)", used: 100, resetsIn: 2 * day + 5 * hour, modelScoped: true),
        ])
        showAllWindows(of: model)

        let segments = MenuBarLayout.activeSegments(model, slot: .claude, now: now)

        XCTAssertEqual(segments.map(\.label), ["3h23m", "6d12h", "2d05h"])
        XCTAssertEqual(segments.map(\.value), ["63%", "87%", "0%"])
        XCTAssertEqual(segments.compactMap(\.reset?.windowName), ["5-hour", "Weekly", "Weekly (Fable)"])
        XCTAssertEqual(segments.compactMap(\.reset?.at), [
            now.addingTimeInterval(3 * hour + 23 * 60),
            now.addingTimeInterval(6 * day + 12 * hour),
            now.addingTimeInterval(2 * day + 5 * hour),
        ])
    }

    func testTwoWeeklyWindowsWithTheSameResetAreStillTwoColumns() {
        // The 5h / 7d / 7d captions could not tell the two weeklies apart; the
        // countdowns can differ, and where they do not, the tooltip names them.
        let model = claudeModel(windows: [
            window("seven_day", "Weekly", used: 13, resetsIn: 6 * day),
            window("seven_day_fable", "Weekly (Fable)", used: 0, resetsIn: 6 * day, modelScoped: true),
        ])
        showAllWindows(of: model)

        let segments = MenuBarLayout.activeSegments(model, slot: .claude, now: now)

        XCTAssertEqual(segments.map(\.label), ["6d00h", "6d00h"])
        XCTAssertEqual(segments.map { $0.spokenText(end: "left") }, [
            "Weekly 87% left (resets in 6d00h)",
            "Weekly (Fable) 100% left (resets in 6d00h)",
        ])
    }

    func testBarColumnCarriesTheCountdownCaption() {
        let model = claudeModel(windows: [window("five_hour", "5-hour", used: 37, resetsIn: 3 * hour)])
        MenuBarLayout.save([
            MenuBarItem(key: "icon", enabled: false),
            MenuBarItem(key: "b:claude:five_hour", enabled: true),
        ], for: .claude)

        guard case .bar(let segment)? = MenuBarLayout.activeElements(model, slot: .claude, now: now).first else {
            return XCTFail("expected a bar element")
        }
        XCTAssertEqual(segment.label, "3h00m")
        XCTAssertEqual(segment.remaining, 63)
    }

    // MARK: The clock moves, the data does not

    func testCaptionsCountDownWithoutNewUsageData() {
        let model = claudeModel(windows: [window("five_hour", "5-hour", used: 37, resetsIn: 3 * hour + 23 * 60)])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:five_hour", enabled: true)], for: .claude)

        func label(after seconds: TimeInterval) -> String? {
            MenuBarLayout.activeSegments(model, slot: .claude, now: now.addingTimeInterval(seconds)).first?.label
        }

        XCTAssertEqual(label(after: 0), "3h23m")
        XCTAssertEqual(label(after: 60), "3h22m")
        XCTAssertEqual(label(after: 2 * hour), "1h23m")
        XCTAssertEqual(label(after: 3 * hour + 22 * 60 + 30), "1m")
    }

    func testAMovedResetReplacesTheCaption() {
        let model = claudeModel(windows: [window("five_hour", "5-hour", used: 37, resetsIn: 20 * 60)])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:five_hour", enabled: true)], for: .claude)
        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .claude, now: now).map(\.label), ["20m"])

        // The window rolled over and the next refresh stated a new reset.
        model.claude = claudeState([window("five_hour", "5-hour", used: 2, resetsIn: 5 * hour)])

        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .claude, now: now).map(\.label), ["5h00m"])
    }

    // MARK: Degradation

    func testWindowWithoutAResetKeepsItsCode() {
        let model = claudeModel(windows: [
            window("five_hour", "5-hour", used: 0, resetsIn: nil),
            window("seven_day", "Weekly", used: 13, resetsIn: nil),
        ])
        MenuBarLayout.save([
            MenuBarItem(key: "q:claude:five_hour", enabled: true),
            MenuBarItem(key: "q:claude:seven_day", enabled: true),
        ], for: .claude)

        let segments = MenuBarLayout.activeSegments(model, slot: .claude, now: now)

        XCTAssertEqual(segments.map(\.label), ["5h", "7d"])
        XCTAssertEqual(segments.compactMap(\.reset), [])
    }

    func testPassedResetFallsBackToTheCodeNeverANegativeCountdown() {
        let model = claudeModel(windows: [
            window("five_hour", "5-hour", used: 63, resetsIn: -1),
            window("seven_day", "Weekly", used: 13, resetsIn: -2 * day),
        ])
        MenuBarLayout.save([
            MenuBarItem(key: "q:claude:five_hour", enabled: true),
            MenuBarItem(key: "q:claude:seven_day", enabled: true),
        ], for: .claude)

        let segments = MenuBarLayout.activeSegments(model, slot: .claude, now: now)

        XCTAssertEqual(segments.map(\.label), ["5h", "7d"])
        XCTAssertEqual(segments.map(\.value), ["37%", "87%"])
    }

    func testOneWindowExpiringDoesNotTouchTheOthers() {
        let model = claudeModel(windows: [
            window("five_hour", "5-hour", used: 63, resetsIn: 90),
            window("seven_day", "Weekly", used: 13, resetsIn: 6 * day),
        ])
        showAllWindows(of: model)

        let later = now.addingTimeInterval(120)

        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .claude, now: now).map(\.label), ["2m", "6d00h"])
        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .claude, now: later).map(\.label), ["5h", "5d23h"])
    }

    func testOneTimeCreditKeepsItsCodeBecauseItsDateIsAnExpiry() {
        var credit = window("cinder_cove", "Included credit", used: 20, resetsIn: 9 * day)
        credit.isOneTimeCredit = true
        let model = claudeModel(windows: [credit])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:cinder_cove", enabled: true)], for: .claude)

        let segment = MenuBarLayout.activeSegments(model, slot: .claude, now: now).first

        XCTAssertEqual(segment?.label, "Inc")
        XCTAssertNil(segment?.reset)
    }

    func testCodexAndCopilotUseTheSharedCaptionMode() {
        let model = AppViewModel(snapshot: nil, storedLifetimeSpend: [])
        model.codex = ProviderState(
            provider: .codex,
            quota: QuotaSnapshot(
                provider: .codex,
                windows: [window("primary", "5-hour", used: 10, resetsIn: 2 * hour),
                          window("secondary", "Weekly", used: 10, resetsIn: 3 * day)],
                source: .appServer, planType: nil, fetchedAt: now, note: nil),
            usage: .empty(.codex))
        model.copilot = ProviderState(
            provider: .copilot,
            quota: QuotaSnapshot(provider: .copilot, windows: [
                window("premium_interactions", "Premium", used: 40, resetsIn: 14 * day),
            ], source: .cli, planType: nil, fetchedAt: now, note: nil),
            usage: .empty(.copilot))
        MenuBarLayout.save([
            MenuBarItem(key: "q:codex:primary", enabled: true),
            MenuBarItem(key: "b:codex:secondary", enabled: true),
        ], for: .codex)
        MenuBarLayout.save([MenuBarItem(key: "q:copilot:premium_interactions", enabled: true)], for: .copilot)
        setColors(["codex:secondary": "0088FF"])

        setMode(.window)
        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .codex, now: now).map(\.label), ["5h", "7d"])
        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .copilot, now: now).map(\.label), ["prem"])

        setMode(.countdown)
        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .codex, now: now).map(\.label), ["2h00m", "3d00h"])
        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .copilot, now: now).map(\.label), ["14d00h"])

        setMode(.both)
        let elements = MenuBarLayout.activeElements(model, slot: .codex, now: now)
        XCTAssertEqual(elements.compactMap(\.segment?.label), ["5h 2h00m", "7d 3d00h"])
        XCTAssertEqual(MenuBarLayout.activeSegments(model, slot: .copilot, now: now).map(\.label), ["prem 14d00h"])
        XCTAssertEqual(MenuBarLayout.nextCountdownChange(in: elements, after: now), now.addingTimeInterval(60))
        let preview = MenuBarLayout.preview("b:codex:secondary", model, slot: .codex, now: now)
        XCTAssertEqual(preview?.segment?.label, "7d 3d00h")
        XCTAssertEqual(preview?.segment?.reset?.tint, ResetCaptionColors.tint(hex: "0088FF"))
    }

    func testSettingsChipsFollowTheCaptionMode() {
        let model = claudeModel(windows: [window("five_hour", "5-hour", used: 37, resetsIn: 3 * hour)])

        func chipLabel() -> String? {
            guard case .segment(let chip)? = MenuBarLayout.preview("q:claude:five_hour", model, slot: .claude, now: now)
            else { return nil }
            return chip.label
        }

        setMode(.window)
        XCTAssertEqual(chipLabel(), "5h")
        setMode(.countdown)
        XCTAssertEqual(chipLabel(), "3h00m")
        setMode(.both)
        XCTAssertEqual(chipLabel(), "5h 3h00m")
    }

    // MARK: Tooltip

    func testTooltipNamesTheWindowTheCaptionNoLongerDoes() {
        let model = claudeModel(windows: [
            window("five_hour", "5-hour", used: 37, resetsIn: 3 * hour + 23 * 60),
            window("seven_day", "Weekly", used: 13, resetsIn: 6 * day + 12 * hour),
        ])
        showAllWindows(of: model)

        let spoken = MenuBarLayout.activeSegments(model, slot: .claude, now: now).map { $0.spokenText(end: "left") }

        XCTAssertEqual(spoken, ["5-hour 63% left (resets in 3h23m)", "Weekly 87% left (resets in 6d12h)"])
    }

    func testTooltipOfAnUncountedColumnReadsAsBefore() {
        let quota = MenuBarSegment(label: "5h", value: "63%", remaining: 63, alertLevel: .none)
        let usage = MenuBarSegment(label: "day", value: "16.3M", remaining: nil, alertLevel: .none)

        XCTAssertEqual(quota.spokenText(end: "left"), "5h 63% left")
        XCTAssertEqual(usage.spokenText(end: "left"), "day 16.3M")
    }

    // MARK: Scheduling

    func testNextTickIsTheEarliestChangeAmongTheShownCountdowns() {
        let model = claudeModel(windows: [
            window("five_hour", "5-hour", used: 37, resetsIn: 3 * hour + 23 * 60),
            window("seven_day", "Weekly", used: 13, resetsIn: 6 * day + 12 * hour + 30 * 60),
        ])
        showAllWindows(of: model)

        let elements = MenuBarLayout.activeElements(model, slot: .claude, now: now)

        // The 5-hour caption changes first (after a minute); the weekly one,
        // which says whole hours, would not change for 31 minutes.
        XCTAssertEqual(MenuBarLayout.nextCountdownChange(in: elements, after: now), now.addingTimeInterval(60))
    }

    func testNothingIsScheduledWhenNoCountdownIsShown() {
        let model = claudeModel(windows: [window("five_hour", "5-hour", used: 0, resetsIn: nil)])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:five_hour", enabled: true)], for: .claude)

        let elements = MenuBarLayout.activeElements(model, slot: .claude, now: now)

        XCTAssertNil(MenuBarLayout.nextCountdownChange(in: elements, after: now))
    }

    func testTheCountdownEndingIsAChangeToScheduleFor() {
        let model = claudeModel(windows: [window("five_hour", "5-hour", used: 37, resetsIn: 45)])
        MenuBarLayout.save([MenuBarItem(key: "q:claude:five_hour", enabled: true)], for: .claude)

        let elements = MenuBarLayout.activeElements(model, slot: .claude, now: now)

        XCTAssertEqual(MenuBarLayout.nextCountdownChange(in: elements, after: now), now.addingTimeInterval(45))
    }

    // MARK: Layout

    func testCaptionDigitsDoNotChangeTheColumnWidth() {
        // The item's length follows its text and the popover is anchored to the
        // item, so a minute that turns a "1" into an "8" must not resize it.
        // The value is narrow so that the caption sets the width.
        let widths = ["1h11m", "8h08m", "5h00m", "3h23m", "6d12h", "7d00h"].map {
            MenuBarContentView.columnWidth(
                MenuBarSegment(label: $0, value: "9%", remaining: 9, alertLevel: .none), showCaptions: true)
        }
        XCTAssertEqual(Set(widths.dropLast(2)).count, 1, "\(widths)")
        XCTAssertEqual(Set(widths.suffix(2)).count, 1, "\(widths)")
    }

    func testCountdownColumnsStayCompact() {
        // Only here to catch a format that suddenly gets long: the old codes
        // are a 25 pt column for a two-digit value, the longest countdown
        // forms about 10 pt more.
        for label in ["5h", "7d", "3h23m", "6d12h", "8h08m", "23h59m", "10d00h", "99d23h", "5h 3h23m", "7d 23h59m"] {
            let width = MenuBarContentView.columnWidth(
                MenuBarSegment(label: label, value: "63%", remaining: 63, alertLevel: .none), showCaptions: true)
            XCTAssertLessThanOrEqual(width, label.contains(" ") ? 62 : 42, "\(label) is \(width) pt wide")
        }
    }

    // MARK: Fixtures

    private func window(_ id: String, _ label: String, used: Double, resetsIn: TimeInterval?,
                        modelScoped: Bool = false) -> QuotaWindow {
        QuotaWindow(id: id, label: label, usedPercent: used,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                    isModelScoped: modelScoped ? true : nil,
                    cycle: ClaudeOAuthFetcher.cycle(forWindowID: id))
    }

    private func claudeState(_ windows: [QuotaWindow]) -> ProviderState {
        ProviderState(
            provider: .claude,
            quota: QuotaSnapshot(provider: .claude, windows: windows, source: .oauth,
                                 planType: "max", fetchedAt: now, note: nil),
            usage: .empty(.claude))
    }

    private func claudeModel(windows: [QuotaWindow]) -> AppViewModel {
        let model = AppViewModel(snapshot: nil, storedLifetimeSpend: [])
        model.claude = claudeState(windows)
        return model
    }

    /// Every window of the model's Claude snapshot, in order, as quota columns.
    private func showAllWindows(of model: AppViewModel) {
        MenuBarLayout.save(model.claude.quota.windows.map {
            MenuBarItem(key: "q:claude:\($0.id)", enabled: true)
        }, for: .claude)
    }
}
