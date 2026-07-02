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
}
