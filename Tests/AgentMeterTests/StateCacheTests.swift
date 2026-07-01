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
    }
}
