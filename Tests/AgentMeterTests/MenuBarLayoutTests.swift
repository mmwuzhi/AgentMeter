import Foundation
@testable import AgentMeter
import XCTest

@MainActor
final class MenuBarLayoutTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "menuBarSlotsConfig")
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.codex")
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.claude")
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.copilot")
        super.tearDown()
    }

    func testDefaultVisibleSlotsAreProvidersOnly() {
        UserDefaults.standard.removeObject(forKey: "menuBarSlotsConfig")
        let model = configuredModel()

        XCTAssertEqual(MenuBarSlots.visibleSlots(), [.codex, .claude])
        XCTAssertEqual(MenuBarLayout.visibleSlots(model), [.codex, .claude])
    }

    func testLegacyOverviewAndAgentsSlotsAreIgnored() throws {
        let legacy = [
            MenuBarSlotItem(key: "overview", enabled: true),
            MenuBarSlotItem(key: "activeAgents", enabled: true),
            MenuBarSlotItem(key: "codex", enabled: true),
            MenuBarSlotItem(key: "claude", enabled: false),
            MenuBarSlotItem(key: "copilot", enabled: false),
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(legacy), forKey: "menuBarSlotsConfig")

        XCTAssertEqual(MenuBarSlots.visibleSlots(), [.codex])
        XCTAssertEqual(MenuBarSlots.merged().map(\.item.key), ["codex", "claude", "copilot"])
    }

    func testVisibleSlotsComeFromProviderFields() {
        let model = configuredModel()
        MenuBarLayout.save([
            MenuBarItem(key: "icon", enabled: false),
            MenuBarItem(key: "q:claude:five_hour", enabled: false),
            MenuBarItem(key: "q:claude:weekly", enabled: false),
            MenuBarItem(key: "u:claude:localDay", enabled: false),
            MenuBarItem(key: "u:claude:7d", enabled: false),
            MenuBarItem(key: "u:claude:30d", enabled: false),
            MenuBarItem(key: "s:claude", enabled: false),
        ], for: .claude)

        XCTAssertEqual(MenuBarLayout.visibleSlots(model), [.codex])
    }

    func testLegacyProviderVisibilitySeedsFieldDefaults() throws {
        let legacy = [
            MenuBarSlotItem(key: "codex", enabled: false),
            MenuBarSlotItem(key: "claude", enabled: true),
            MenuBarSlotItem(key: "copilot", enabled: true),
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(legacy), forKey: "menuBarSlotsConfig")
        let model = configuredModel()

        XCTAssertEqual(MenuBarLayout.visibleSlots(model), [.claude, .copilot])
    }

    func testProviderSlotDefaultOffersProviderUsageFieldsDisabled() {
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.claude")
        let model = AppViewModel()
        model.claude = claudeState()

        let items = MenuBarLayout.merged(model, for: .claude).map(\.item)
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.enabled) })

        XCTAssertEqual(byKey["q:claude:five_hour"], true)
        XCTAssertEqual(byKey["q:claude:weekly"], false)
        XCTAssertEqual(byKey["u:claude:localDay"], false)
        XCTAssertEqual(byKey["u:claude:7d"], false)
        XCTAssertEqual(byKey["u:claude:30d"], false)
    }

    func testProviderSlotDefaultShowsMostNeededQuotaOnly() {
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.claude")
        let model = AppViewModel()
        model.claude = claudeState()

        let segments = MenuBarLayout.activeSegments(model, slot: .claude)

        XCTAssertEqual(segments.map(\.label), ["5h"])
        XCTAssertEqual(segments.map(\.value), ["100%"])
    }

    func testProviderSlotCaptionsAreNotProviderPrefixedWhenManuallyEnabled() {
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.claude")
        let model = AppViewModel()
        model.claude = claudeState()
        MenuBarLayout.save([
            MenuBarItem(key: "q:claude:five_hour", enabled: true),
            MenuBarItem(key: "q:claude:weekly", enabled: true),
            MenuBarItem(key: "u:claude:localDay", enabled: true),
            MenuBarItem(key: "u:claude:7d", enabled: true),
            MenuBarItem(key: "u:claude:30d", enabled: true),
        ], for: .claude)

        let segments = MenuBarLayout.activeSegments(model, slot: .claude)

        XCTAssertEqual(segments.map(\.label), ["5h", "7d", "day", "7d", "30d"])
        XCTAssertEqual(segments.map(\.value), ["100%", "39%", "16.3M", "314.4M", "998.7M"])
    }

    func testMenuBarWidthDoesNotAddTrailingAir() {
        let segment = MenuBarSegment(label: "5h", value: "69%", remaining: 69, alertLevel: .none)
        let width = MenuBarContentView.width(
            elements: [.icon(.provider(.claude)), .segment(segment)],
            showCaptions: true
        )

        XCTAssertEqual(
            width,
            MenuBarContentView.iconSize
                + MenuBarContentView.spacing
                + MenuBarContentView.columnWidth(segment, showCaptions: true)
        )
    }

    func testStatusLengthUsesSymmetricVisualOverhang() {
        let visualWidth: CGFloat = 48

        XCTAssertEqual(
            MenuBarContentView.statusLength(forVisualWidth: visualWidth),
            visualWidth - MenuBarContentView.statusItemOverhang * 2
        )
    }

    func testProviderTemplateIconsLoad() {
        XCTAssertNotNil(MenuBarContentView.templateIcon(for: .claude))
        XCTAssertNotNil(MenuBarContentView.templateIcon(for: .copilot))

        let codexTemplate = "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png"
        if FileManager.default.fileExists(atPath: codexTemplate) {
            XCTAssertNotNil(MenuBarContentView.templateIcon(for: .codex))
        }
    }

    private func configuredModel() -> AppViewModel {
        let model = AppViewModel()
        model.codex = providerState(.codex)
        model.claude = claudeState()
        model.copilot = providerState(.copilot)
        return model
    }

    private func providerState(_ provider: Provider) -> ProviderState {
        ProviderState(
            provider: provider,
            quota: QuotaSnapshot(
                provider: provider,
                windows: [
                    QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 50, resetsAt: nil)
                ],
                source: .appServer,
                planType: nil,
                fetchedAt: Date(),
                note: nil
            ),
            usage: .empty(provider)
        )
    }

    private func claudeState() -> ProviderState {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let old = cal.date(byAdding: .day, value: -29, to: today)!
        return ProviderState(
            provider: .claude,
            quota: QuotaSnapshot(
                provider: .claude,
                windows: [
                    QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil),
                    QuotaWindow(id: "weekly", label: "Weekly", usedPercent: 61, resetsAt: nil),
                ],
                source: .oauth,
                planType: "pro",
                fetchedAt: Date(),
                note: nil
            ),
            usage: UsageReport(
                provider: .claude,
                buckets: [
                    UsageBucket(day: old, inputTokens: 684_300_000, outputTokens: 0,
                                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: 0),
                    UsageBucket(day: today, inputTokens: 16_300_000, outputTokens: 0,
                                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: 0),
                    UsageBucket(day: cal.date(byAdding: .day, value: -6, to: today)!,
                                inputTokens: 298_100_000, outputTokens: 0,
                                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, costUSD: 0),
                ],
                totalCostUSD: 0,
                totalTokens: 998_700_000
            )
        )
    }
}
