import Foundation
@testable import AgentMeter
import XCTest

final class RefreshCoordinatorMergeTests: XCTestCase {
    func testUpdateOverwritesMatchingProvider() {
        let existing: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .operational, description: "All Systems Operational")
        ]
        let update: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .outage, description: "Major outage")
        ]

        let merged = RefreshCoordinator.mergeProviderStatus(existing, with: update)

        XCTAssertEqual(merged[.codex]?.level, .outage)
    }

    /// The bug this pins: a partial `update` (e.g. one provider's poll timed out this
    /// cycle) must not erase providers that were NOT included in the update — a wholesale
    /// `viewModel.providerStatus = update` would silently regress them to "unknown".
    func testPartialUpdatePreservesProvidersMissingFromTheUpdate() {
        let existing: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .operational, description: nil),
            .claude: ProviderStatusResult(level: .operational, description: nil),
            .copilot: ProviderStatusResult(level: .outage, description: "GitHub Copilot outage")
        ]
        // Simulates this cycle's Copilot poll timing out: only codex/claude came back.
        let update: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .operational, description: nil),
            .claude: ProviderStatusResult(level: .degraded, description: "Partial degradation")
        ]

        let merged = RefreshCoordinator.mergeProviderStatus(existing, with: update)

        XCTAssertEqual(merged[.claude]?.level, .degraded, "claude should reflect this cycle's fresh result")
        XCTAssertEqual(merged[.copilot]?.level, .outage,
                        "copilot's last known outage must survive a cycle where its own poll didn't come back")
    }

    func testEmptyExistingMapAcceptsFirstUpdate() {
        let update: [Provider: ProviderStatusResult] = [
            .codex: ProviderStatusResult(level: .operational, description: "All Systems Operational")
        ]

        let merged = RefreshCoordinator.mergeProviderStatus([:], with: update)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[.codex]?.level, .operational)
    }
}
