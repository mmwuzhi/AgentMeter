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

    /// `last-state.json` written before scrapes carried the cache time keeps
    /// decoding, as a reading dated by its fetch; a live reading writes no
    /// key at all, so the file an older build reads is unchanged.
    func testQuotaSnapshotCacheTimeIsOptionalAndRoundTrips() throws {
        let old = Data(#"{"provider":"claude","windows":[{"id":"five_hour","label":"5-hour","usedPercent":10}],"source":"cli","planType":"team","fetchedAt":100}"#.utf8)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: old)
        XCTAssertNil(decoded.cachedAt)
        XCTAssertEqual(decoded.readingTime, decoded.fetchedAt)

        let live = QuotaSnapshot(provider: .claude, windows: decoded.windows, source: .oauth,
                                 planType: "team", fetchedAt: Date(timeIntervalSince1970: 100), note: nil)
        let liveJSON = String(decoding: try JSONEncoder().encode(live), as: UTF8.self)
        XCTAssertFalse(liveJSON.contains("cachedAt"))

        let echo = QuotaSnapshot(provider: .claude, windows: decoded.windows, source: .cli, planType: "team",
                                 fetchedAt: Date(timeIntervalSince1970: 200_000), note: nil,
                                 cachedAt: Date(timeIntervalSince1970: 100))
        let roundTripped = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(echo))
        XCTAssertEqual(roundTripped, echo)
        XCTAssertTrue(roundTripped.echoesStaleCache)
    }

    /// Observations written before they carried a source decode as unknown;
    /// a recorded source survives the round trip.
    func testQuotaObservationSourceIsOptionalAndRoundTrips() throws {
        let old = Data(#"{"provider":"claude","windowID":"five_hour","remainingPercent":80,"observedAt":100}"#.utf8)
        let decoded = try JSONDecoder().decode(QuotaObservation.self, from: old)
        XCTAssertNil(decoded.source)
        XCTAssertNil(decoded.resetsAt)

        let observation = QuotaObservation(provider: .claude, windowID: "five_hour", remainingPercent: 80,
                                           observedAt: Date(timeIntervalSince1970: 100), resetsAt: nil, source: .oauth)
        let roundTripped = try JSONDecoder().decode(QuotaObservation.self, from: JSONEncoder().encode(observation))
        XCTAssertEqual(roundTripped, observation)
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
