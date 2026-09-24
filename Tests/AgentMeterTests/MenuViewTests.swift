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
}
