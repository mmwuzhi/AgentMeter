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
}
