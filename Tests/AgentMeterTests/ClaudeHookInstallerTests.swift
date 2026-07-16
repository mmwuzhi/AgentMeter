import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeHookInstallerTests: XCTestCase {
    private let cli = "'/Users/me/Library/Application Support/AgentMeter/bin/agentmeter-hook'"

    private func commands(in root: [String: Any]) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        return hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
    }

    func testMergeIntoEmptyInstallsAllEventsAndIsIdempotent() {
        let (once, changed) = ClaudeHookInstaller.mergedHooks(into: [:], cliQuoted: cli)
        XCTAssertTrue(changed)
        XCTAssertEqual(commands(in: once).count, 8)
        let (_, changedAgain) = ClaudeHookInstaller.mergedHooks(into: once, cliQuoted: cli)
        XCTAssertFalse(changedAgain)
    }

    func testMergeAndRemovePreserveUserCommandInSameMatcherGroup() {
        let mixedGroup: [String: Any] = [
            "matcher": "*",
            "hooks": [
                ["type": "command", "command": "echo user-hook"],
                ["type": "command", "command": "'/old/path/agentmeter-hook' idle"],
            ],
            "custom": true,
        ]
        let root: [String: Any] = ["hooks": ["Stop": [mixedGroup]]]

        let (merged, _) = ClaudeHookInstaller.mergedHooks(into: root, cliQuoted: cli)
        XCTAssertTrue(commands(in: merged).contains("echo user-hook"))
        XCTAssertEqual(commands(in: merged).filter(ClaudeHookInstaller.isManagedCommand).count, 8)

        let (cleaned, changed) = ClaudeHookInstaller.removedHooks(from: merged)
        XCTAssertTrue(changed)
        XCTAssertEqual(commands(in: cleaned), ["echo user-hook"])
        let stop = ((cleaned["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first
        XCTAssertEqual(stop?["custom"] as? Bool, true)
    }

    func testMarkerTextInUnrelatedCommandIsNotOwned() {
        XCTAssertFalse(ClaudeHookInstaller.isManagedCommand("echo agentmeter-hook"))
        XCTAssertFalse(ClaudeHookInstaller.isManagedCommand("/tmp/agentmeter-hook-wrapper idle"))
        XCTAssertTrue(ClaudeHookInstaller.isManagedCommand("\"/tmp/agentmeter-hook\" idle"))
    }

    func testShellQuotedPathWithApostropheStillRecognizesManagedExecutable() {
        let command = ClaudeHookInstaller.shellQuoted("/Users/O'Brien/bin/agentmeter-hook") + " idle"
        XCTAssertTrue(ClaudeHookInstaller.isManagedCommand(command))
    }

    func testHookCommandsReadOfficialJSONFromStandardInput() {
        let commands = ClaudeHookInstaller.hookEntries(cliQuoted: cli).map(\.command)
        XCTAssertTrue(commands.allSatisfy { !$0.contains("$CLAUDE_SESSION_ID") && !$0.contains("$PWD") })
    }
}
