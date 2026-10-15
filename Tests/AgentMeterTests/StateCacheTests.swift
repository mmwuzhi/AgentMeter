import Foundation
@testable import AgentMeter
import XCTest

final class StateCacheTests: XCTestCase {
    func testSnapshotDecodesCacheWithoutQuotaObservations() throws {
        struct OldSnapshot: Encodable {
            var codex: ProviderState
            var claude: ProviderState
            var copilot: ProviderState
        }

        let snapshot = OldSnapshot(
            codex: ProviderState(provider: .codex, quota: .unavailable(.codex, note: "old"), usage: .empty(.codex)),
            claude: ProviderState(provider: .claude, quota: .unavailable(.claude, note: "old"), usage: .empty(.claude)),
            copilot: ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "old"), usage: .empty(.copilot))
        )
        let data = try JSONEncoder().encode(snapshot)

        let decoded = try JSONDecoder().decode(StateCache.Snapshot.self, from: data)

        XCTAssertTrue(decoded.quotaObservations.isEmpty)
        XCTAssertEqual(decoded.codex.provider, .codex)
        XCTAssertEqual(decoded.claude.provider, .claude)
        XCTAssertEqual(decoded.copilot.provider, .copilot)
        XCTAssertNil(decoded.codexResetCreditState.lastObservedCount)
        XCTAssertTrue(decoded.codexResetCreditState.credits.isEmpty)
    }

    /// `last-state.json` written before windows carried a cycle must keep
    /// decoding; the field is simply unknown for those rows.
    func testQuotaWindowDecodesWithoutACycleKey() throws {
        let data = Data(#"{"id":"five_hour","label":"5-hour","usedPercent":10}"#.utf8)

        let window = try JSONDecoder().decode(QuotaWindow.self, from: data)

        XCTAssertNil(window.cycle)
        XCTAssertNil(window.resetsAt)
        XCTAssertEqual(window.remainingPercent, 90)
    }

    /// `last-state.json` written before the Claude badge knew about the
    /// rate-limit tier must keep decoding; the tier is simply unknown for that
    /// row, and the badge falls back to the plan alone.
    func testQuotaSnapshotDecodesWithoutARateLimitTierKey() throws {
        let data = Data(#"{"provider":"claude","windows":[{"id":"five_hour","label":"5-hour","usedPercent":10}],"source":"oauth","planType":"team","fetchedAt":0}"#.utf8)

        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data)

        XCTAssertNil(snapshot.rateLimitTier)
        XCTAssertEqual(snapshot.planType, "team")
        XCTAssertEqual(snapshot.planBadge, PlanBadge(text: "TEAM", help: nil))
    }

    func testSnapshotPreservesCodexResetCreditState() throws {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let state = CodexResetCreditState(
            lastObservedCount: 3,
            credits: [
                CodexResetCreditExpiry(
                    id: "credit",
                    grantedAt: now,
                    expiresAt: now.addingTimeInterval(CodexResetCreditTracker.inferredLifetime)
                )
            ]
        )
        let snapshot = StateCache.Snapshot(
            codex: ProviderState(provider: .codex, quota: .unavailable(.codex, note: "old"), usage: .empty(.codex)),
            claude: ProviderState(provider: .claude, quota: .unavailable(.claude, note: "old"), usage: .empty(.claude)),
            copilot: ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "old"), usage: .empty(.copilot)),
            codexResetCreditState: state
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(StateCache.Snapshot.self, from: data)

        XCTAssertEqual(decoded.codexResetCreditState, state)
    }

    func testSnapshotWithoutClaudeResetStateDecodesToNoResets() throws {
        let data = try JSONEncoder().encode(StateCache.Snapshot(
            codex: ProviderState(provider: .codex, quota: .unavailable(.codex, note: "old"), usage: .empty(.codex)),
            claude: ProviderState(provider: .claude, quota: .unavailable(.claude, note: "old"), usage: .empty(.claude)),
            copilot: ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "old"), usage: .empty(.copilot))
        ))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "claudeResetState")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StateCache.Snapshot.self, from: oldData)

        XCTAssertEqual(decoded.claudeResetState, ClaudeResetState())
    }

    func testSnapshotPreservesClaudeResetState() throws {
        let state = ClaudeResetState(eligible: true, ineligibleReason: nil, grants: [
            ClaudeResetGrant(id: "launch", resetsLeft: 1,
                             endsAt: Date(timeIntervalSince1970: 1_792_600_000), clears: ["seven_day"]),
            ClaudeResetGrant(id: "open", resetsLeft: 2, endsAt: nil, clears: []),
        ])
        let snapshot = StateCache.Snapshot(
            codex: ProviderState(provider: .codex, quota: .unavailable(.codex, note: "old"), usage: .empty(.codex)),
            claude: ProviderState(provider: .claude, quota: .unavailable(.claude, note: "old"), usage: .empty(.claude)),
            copilot: ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "old"), usage: .empty(.copilot)),
            claudeResetState: state
        )

        let decoded = try JSONDecoder().decode(StateCache.Snapshot.self, from: JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded.claudeResetState, state)
    }
}
