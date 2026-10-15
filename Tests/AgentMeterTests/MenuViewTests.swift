@testable import AgentMeter
import XCTest

final class MenuViewTests: XCTestCase {
    func testSectionsCapClampsToScreenAndMinimum() {
        XCTAssertEqual(MenuView.sectionsCap(screenVisibleHeight: 1_000), 860)
        XCTAssertEqual(MenuView.sectionsCap(screenVisibleHeight: nil), 660)
        XCTAssertEqual(MenuView.sectionsCap(screenVisibleHeight: 300), 200,
                       "never collapses below the readable minimum")
    }

    @MainActor
    func testPruneSessionDisclosureDropsVanishedGroups() {
        let model = AppViewModel()
        model.sessionDisclosure = [
            "claude:/Users/me/alpha": true,
            "claude:/Users/me/gone": false,
            "subagents:stale": true,
        ]

        model.pruneSessionDisclosure(keeping: ["claude:/Users/me/alpha"])

        XCTAssertEqual(model.sessionDisclosure, ["claude:/Users/me/alpha": true])
    }

    /// The header spinner drifted the popover twice, once as the arrow alone
    /// and once as the whole interface: a `repeatForever` animation lives on
    /// the transaction it starts in, and the transaction that inserts the
    /// spinner also lays out the popover. The spin now reads the clock through
    /// `TimelineView`; keep repeating animations out of the app entirely.
    func testNoRepeatingAnimationInSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("repeatForever") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                XCTFail("\(url.lastPathComponent):\(index + 1) uses a repeating animation: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(scanned, 0, "the Sources directory was not found from #filePath")
    }

    func testCodexResetLineIsUnchanged() {
        let base = Date().addingTimeInterval(3 * 86_400)
        let credits = [
            CodexResetCreditExpiry(id: "late", grantedAt: base, expiresAt: base.addingTimeInterval(86_400)),
            CodexResetCreditExpiry(id: "early", grantedAt: base, expiresAt: base),
        ]
        let items = ResetCreditItem.items(codex: credits)

        XCTAssertEqual(ResetCreditItem.headline(items), "2 resets available")
        XCTAssertEqual(ResetCreditItem.countdowns(items), [base, base.addingTimeInterval(86_400)]
            .map { QuotaRow.relative($0, prefixed: false) }.joined(separator: " · "))
        XCTAssertEqual(ResetCreditItem.headline(ResetCreditItem.items(codex: [credits[0]])), "1 reset available")
        XCTAssertNil(ResetCreditItem.headline([]))
    }

    func testClaudeGrantLineNamesWhatItRefills() {
        let now = Date()
        let endsAt = now.addingTimeInterval(7 * 86_400)
        let state = ClaudeResetState(eligible: true, grants: [
            ClaudeResetGrant(id: "g", resetsLeft: 2, endsAt: endsAt, clears: ["seven_day"]),
        ])
        let items = ResetCreditItem.items(claude: state, at: now)

        XCTAssertEqual(ResetCreditItem.headline(items), "2 resets available · refills Weekly")
        XCTAssertEqual(ResetCreditItem.countdowns(items, labeled: true),
                       "Expires in " + QuotaRow.relative(endsAt, prefixed: false) + " ×2")
    }

    func testClaudeGrantsRefillingDifferentWindowsLabelEachCountdown() {
        let now = Date()
        let soon = now.addingTimeInterval(2 * 86_400)
        let state = ClaudeResetState(eligible: true, grants: [
            ClaudeResetGrant(id: "weekly", resetsLeft: 1, endsAt: soon, clears: ["seven_day"]),
            ClaudeResetGrant(id: "session", resetsLeft: 1, endsAt: nil, clears: ["five_hour"]),
            ClaudeResetGrant(id: "unnamed", resetsLeft: 1, endsAt: nil, clears: ["seven_day_cowork"]),
        ])
        let items = ResetCreditItem.items(claude: state, at: now)

        XCTAssertEqual(ResetCreditItem.headline(items), "3 resets available")
        XCTAssertEqual(ResetCreditItem.countdowns(items),
                       "Weekly \(QuotaRow.relative(soon, prefixed: false)) · 5-hour")
        XCTAssertEqual(ResetCreditItem.countdowns(items, labeled: true),
                       "Weekly expires in \(QuotaRow.relative(soon, prefixed: false)) · 5-hour")
    }

    func testClaudeResetLineHidesExpiredIneligibleAndEmptyStates() {
        let now = Date()
        let expired = ClaudeResetState(eligible: true, grants: [
            ClaudeResetGrant(id: "old", resetsLeft: 1, endsAt: now.addingTimeInterval(-60), clears: ["seven_day"]),
        ])

        XCTAssertNil(ResetCreditItem.headline(ResetCreditItem.items(claude: expired, at: now)))
        XCTAssertNil(ResetCreditItem.headline(ResetCreditItem.items(
            claude: ClaudeResetState(eligible: false, ineligibleReason: "seat"), at: now)))
        XCTAssertNil(ResetCreditItem.headline(ResetCreditItem.items(claude: ClaudeResetState(), at: now)))
    }
}
