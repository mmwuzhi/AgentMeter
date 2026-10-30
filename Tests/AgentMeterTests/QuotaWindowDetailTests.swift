import Foundation
@testable import AgentMeter
import XCTest

/// `QuotaWindow.detail` is an additive optional: a `last-state.json` written
/// before it decodes, a build that predates it ignores it, and every place that
/// rebuilds a snapshot or swaps a window carries it.
final class QuotaWindowDetailTests: XCTestCase {
    private static let detail = QuotaWindowDetail(
        isActive: true, severity: "warning", lockedReason: "plan_limit", scopeName: "Fable",
        shareUsedOfWeekly: 23.5, shareAllowanceOfWeekly: 50, utilizationStated: true)

    private static let reset = Date(timeIntervalSince1970: 1_800_003_600)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ id: String = "five_hour", used: Double = 10, detail: QuotaWindowDetail? = QuotaWindowDetailTests.detail) -> QuotaWindow {
        QuotaWindow(id: id, label: id, usedPercent: used, resetsAt: Self.reset, detail: detail)
    }

    // MARK: - Codable

    func testWindowJSONWithoutADetailKeyDecodesWithNilDetail() throws {
        let data = Data(#"{"id":"five_hour","label":"5-hour","usedPercent":10,"resetsAt":0,"cycle":18000}"#.utf8)

        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: data)

        XCTAssertNil(decoded.detail)
        XCTAssertEqual(decoded.cycle, 18000)
        XCTAssertEqual(decoded.usedPercent, 10)
    }

    func testWindowJSONWithADetailKeyDecodesEveryField() throws {
        let data = Data("""
        {"id":"seven_day_fable","label":"Weekly (Fable)","usedPercent":46,
         "detail":{"isActive":false,"severity":"normal","lockedReason":"x","scopeName":"Fable",
                   "shareUsedOfWeekly":23,"shareAllowanceOfWeekly":50,"utilizationStated":true}}
        """.utf8)

        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: data)

        XCTAssertEqual(decoded.detail, QuotaWindowDetail(
            isActive: false, severity: "normal", lockedReason: "x", scopeName: "Fable",
            shareUsedOfWeekly: 23, shareAllowanceOfWeekly: 50, utilizationStated: true))
    }

    func testADetailWithOnlySomeKeysDecodes() throws {
        let data = Data(#"{"id":"five_hour","label":"5-hour","usedPercent":1,"detail":{"utilizationStated":false}}"#.utf8)

        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: data)

        XCTAssertEqual(decoded.detail, QuotaWindowDetail(utilizationStated: false))
    }

    func testDetailRoundTripsAndNilDetailWritesNoKey() throws {
        let with = window()
        let without = window(detail: nil)

        XCTAssertEqual(try JSONDecoder().decode(QuotaWindow.self, from: JSONEncoder().encode(with)), with)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(without)) as? [String: Any]
        XCTAssertNotNil(plain)
        XCTAssertFalse(plain?.keys.contains("detail") ?? true, "a window with no detail writes the file an older build wrote")
    }

    /// A build that predates `detail` reads the new file: the unknown key is
    /// ignored (JSONDecoder's default), everything else is as before.
    func testAnOlderBuildIgnoresTheNewKey() throws {
        struct PreDetailWindow: Codable, Equatable {
            let id: String
            let label: String
            let usedPercent: Double
            let resetsAt: Date?
            var isOneTimeCredit: Bool?
            var isModelScoped: Bool?
            var cycle: TimeInterval?
        }

        let data = try JSONEncoder().encode(window())
        let old = try JSONDecoder().decode(PreDetailWindow.self, from: data)

        XCTAssertEqual(old, PreDetailWindow(id: "five_hour", label: "five_hour", usedPercent: 10,
                                            resetsAt: Self.reset, isOneTimeCredit: nil, isModelScoped: nil, cycle: nil))
    }

    func testLastStateFileRoundTripKeepsDetailAndOldFileDecodes() throws {
        let quota = QuotaSnapshot(provider: .claude, windows: [window(), window("seven_day", used: 3, detail: nil)],
                                  source: .oauth, planType: "max", fetchedAt: Self.now, note: nil)
        let state = StateCache.Snapshot(
            codex: ProviderState(provider: .codex, quota: .unavailable(.codex, note: "x"), usage: .empty(.codex)),
            claude: ProviderState(provider: .claude, quota: quota, usage: .empty(.claude)),
            copilot: ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "x"), usage: .empty(.copilot)))

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(StateCache.Snapshot.self, from: data)

        XCTAssertEqual(decoded.claude.quota, quota)
        XCTAssertEqual(decoded.claude.quota.windows.first?.detail, Self.detail)
        XCTAssertNil(decoded.claude.quota.windows.last?.detail)

        // The same file as an older build wrote it: no `detail` anywhere.
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func removeDetail(_ node: Any) -> Any {
            if var object = node as? [String: Any] {
                object["detail"] = nil
                return object.mapValues(removeDetail)
            }
            if let array = node as? [Any] { return array.map(removeDetail) }
            return node
        }
        tree = try XCTUnwrap(removeDetail(tree) as? [String: Any])
        let oldData = try JSONSerialization.data(withJSONObject: tree)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("detail"))
        let restored = try JSONDecoder().decode(StateCache.Snapshot.self, from: oldData)
        XCTAssertEqual(restored.claude.quota.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(restored.claude.quota.windows.map(\.usedPercent), [10, 3])
        XCTAssertNil(restored.claude.quota.windows.first?.detail)
    }

    // MARK: - Every place a snapshot is rebuilt or a window is swapped

    /// `QuotaSnapshot.withResetCreditsExpiresAt` rebuilds the snapshot field by
    /// field (`Models.swift`).
    func testWithResetCreditsExpiresAtKeepsEveryWindowDetail() {
        let quota = QuotaSnapshot(provider: .codex, windows: [window("primary"), window("secondary", detail: nil)],
                                  source: .oauth, planType: "plus", resetCreditsAvailable: 1,
                                  fetchedAt: Self.now, note: nil)

        let rebuilt = quota.withResetCreditsExpiresAt(Self.reset)

        XCTAssertEqual(rebuilt.windows, quota.windows)
        XCTAssertEqual(rebuilt.windows.first?.detail, Self.detail)
        XCTAssertNil(rebuilt.windows.last?.detail)
        XCTAssertEqual(rebuilt.resetCreditsExpiresAt, Self.reset)
    }

    /// `preservingSameEpochRecoverySpikes` (`RefreshCoordinator.swift`) swaps a
    /// spiking window for the previous one and rebuilds the snapshot.
    func testPreservingSameEpochRecoverySpikesCarriesDetailOfTheWindowItKeeps() {
        let previousDetail = QuotaWindowDetail(isActive: false, severity: "previous")
        let previous = QuotaSnapshot(
            provider: .codex,
            windows: [window("primary", used: 50, detail: previousDetail), window("secondary", used: 5, detail: nil)],
            source: .oauth, planType: "plus", fetchedAt: Self.now.addingTimeInterval(-60), note: nil)
        let current = QuotaSnapshot(
            provider: .codex,
            // primary recovers 40 points inside one epoch: a spike; secondary does not.
            windows: [window("primary", used: 10, detail: Self.detail), window("secondary", used: 6, detail: Self.detail)],
            source: .oauth, planType: "plus", fetchedAt: Self.now, note: nil)

        let kept = current.preservingSameEpochRecoverySpikes(from: previous, at: Self.now)

        XCTAssertEqual(kept.windows.first?.usedPercent, 50, "the spiking window is the previous one")
        XCTAssertEqual(kept.windows.first?.detail, previousDetail, "and brings its own detail")
        XCTAssertEqual(kept.windows.last?.detail, Self.detail, "a window that was not swapped keeps its detail")
        XCTAssertEqual(kept.fetchedAt, current.fetchedAt)
    }

    /// `preservingHigherAuthoritySameEpochWindows` is the other rebuild site.
    func testPreservingHigherAuthorityWindowsCarriesDetailOfTheWindowItKeeps() {
        let previousDetail = QuotaWindowDetail(isActive: true, severity: "previous")
        let previous = QuotaSnapshot(
            provider: .codex, windows: [window("primary", used: 30, detail: previousDetail)],
            source: .oauth, planType: "plus", fetchedAt: Self.now.addingTimeInterval(-60), note: nil)
        let current = QuotaSnapshot(
            provider: .codex, windows: [window("primary", used: 31, detail: Self.detail), window("secondary", used: 2, detail: Self.detail)],
            source: .appServer, planType: "plus", fetchedAt: Self.now, note: nil)

        let kept = current.preservingHigherAuthoritySameEpochWindows(from: previous, at: Self.now)

        XCTAssertEqual(kept.windows.first?.detail, previousDetail)
        XCTAssertEqual(kept.windows.first?.usedPercent, 30)
        XCTAssertEqual(kept.windows.last?.detail, Self.detail, "secondary has no previous peer and stays as it was")
        XCTAssertEqual(kept.source, .appServer)
    }

    /// When nothing is swapped both helpers return the snapshot itself.
    func testHelpersThatSwapNothingReturnTheSnapshotWithItsDetail() {
        let quota = QuotaSnapshot(provider: .codex, windows: [window("primary", used: 30)],
                                  source: .oauth, planType: "plus", fetchedAt: Self.now, note: nil)

        XCTAssertEqual(quota.preservingSameEpochRecoverySpikes(from: quota, at: Self.now), quota)
        XCTAssertEqual(quota.preservingHigherAuthoritySameEpochWindows(from: quota, at: Self.now), quota)
        XCTAssertEqual(quota.preservingSameEpochRecoverySpikes(from: quota, at: Self.now).windows.first?.detail, Self.detail)
    }

    /// A failed cycle keeps the previous snapshot whole.
    func testPreservingLiveQuotaKeepsThePreviousSnapshotWithItsDetail() {
        let previous = QuotaSnapshot(provider: .claude, windows: [window()], source: .oauth, planType: "max",
                                     fetchedAt: Self.now.addingTimeInterval(-60), note: nil)
        let failed = ProviderState(provider: .claude, quota: .unavailable(.claude, note: "offline"), usage: .empty(.claude))

        let shown = failed.preservingLiveQuota(from: previous, at: Self.now)

        XCTAssertEqual(shown.quota.windows.first?.detail, Self.detail)
    }

    // MARK: - Parser output survives the same trip

    func testParserDetailSurvivesEncodeDecodeAndTheRebuildHelper() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"five_hour":{"utilization":74,"resets_at":"2025-01-03T10:00:00.123456+00:00"},
         "limits":[{"kind":"session","percent":74,"is_active":true,"severity":"warning"}]}
        """.utf8)) as? [String: Any])
        let parsed = try ClaudeOAuthFetcher.parseSnapshot(from: body)

        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(parsed))
        let rebuilt = decoded.withResetCreditsExpiresAt(Self.reset)

        XCTAssertEqual(rebuilt.windows.first?.detail,
                       QuotaWindowDetail(isActive: true, severity: "warning", utilizationStated: true))
    }
}
