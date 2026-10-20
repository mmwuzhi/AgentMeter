import Foundation
@testable import AgentMeter
import XCTest

final class AgentAppActivatorTests: XCTestCase {
    func testParentPIDResolvesForCurrentProcess() {
        let parent = AgentAppActivator.parentPID(of: getpid())
        XCTAssertNotNil(parent)
        XCTAssertGreaterThan(parent ?? -1, 0)
    }

    func testParentPIDReturnsNilForBogusPID() {
        XCTAssertNil(AgentAppActivator.parentPID(of: -2))
    }

    func testFocusScriptsEscapeInterpolatedValues() {
        let escaped = AgentAppActivator.appleScriptEscaped("a\"b\\c")
        XCTAssertEqual(escaped, "a\\\"b\\\\c")
        XCTAssertTrue(AgentAppActivator.iTermFocusScript(tty: "/dev/ttys003").contains("tty of aSession"))
        XCTAssertTrue(AgentAppActivator.terminalFocusScript(tty: "/dev/ttys004").contains("tty of aTab"))
    }

    /// A click never opens an editor or session URL: `vscode://file/<folder>`
    /// can replace another window's workspace, and Claude Code's session URI
    /// can resume the session in a second process. Only app activation and
    /// terminal-tab selection remain.
    func testNoSourceOpensAnEditorOrSessionURL() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        let forbidden = ["\"vscode\"", "\"vscode-insiders\"", "\"vscodium\"", "\"cursor\"", "\"code-oss\"",
                         "vscode://", "anthropic.claude-code/open", "--resume"]
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
        }
    }
}
