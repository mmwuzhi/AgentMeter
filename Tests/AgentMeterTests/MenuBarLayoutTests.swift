import Foundation
@testable import AgentMeter
import XCTest

@MainActor
final class MenuBarLayoutTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "menuBarSlotsConfig")
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.claude")
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.activeAgents")
        super.tearDown()
    }

    func testDefaultVisibleSlotIsOverviewOnly() {
        UserDefaults.standard.removeObject(forKey: "menuBarSlotsConfig")

        XCTAssertEqual(MenuBarSlots.visibleSlots(), [.overview])
    }

    func testProviderSlotDefaultIncludesProviderUsageFields() {
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.claude")
        let model = AppViewModel()
        model.claude = claudeState()

        let keys = MenuBarLayout.merged(model, for: .claude).map(\.item.key)

        XCTAssertTrue(keys.contains("q:claude:five_hour"))
        XCTAssertTrue(keys.contains("q:claude:weekly"))
        XCTAssertTrue(keys.contains("u:claude:localDay"))
        XCTAssertTrue(keys.contains("u:claude:7d"))
        XCTAssertTrue(keys.contains("u:claude:30d"))
    }

    func testProviderSlotCaptionsAreNotProviderPrefixed() {
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.claude")
        let model = AppViewModel()
        model.claude = claudeState()

        let segments = MenuBarLayout.activeSegments(model, slot: .claude)

        XCTAssertEqual(segments.map(\.label), ["5h", "7d", "day", "7d", "30d"])
        XCTAssertEqual(segments.map(\.value), ["100%", "39%", "16.3M", "314.4M", "998.7M"])
    }

    func testActiveAgentsSlotShowsCount() {
        UserDefaults.standard.removeObject(forKey: "menuBarItemsConfig.activeAgents")
        let model = AppViewModel()
        model.activeAgents = [
            ActiveAgent(provider: .claude, pid: 1, parentPID: 0, command: "claude --resume",
                        elapsedSeconds: 60, observedAt: Date(),
                        session: ActiveAgentSession(
                            id: "abcdef12-3456",
                            projectPath: "/Users/me/project",
                            projectName: "project",
                            branch: "main",
                            lastUpdatedAt: Date(),
                            source: "test"
                        )),
            ActiveAgent(provider: .codex, pid: 2, parentPID: 0, command: "codex",
                        elapsedSeconds: 30, observedAt: Date()),
        ]

        let segments = MenuBarLayout.activeSegments(model, slot: .activeAgents)

        XCTAssertEqual(segments.map(\.label), ["agt", "ses"])
        XCTAssertEqual(segments.map(\.value), ["2", "abcdef12"])
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
