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

    /// A click never opens Claude Code's session URI, which opens a new
    /// conversation, or resumes this one in a second process, in whichever
    /// window was focused last; nor a bare `vscode://file/<folder>`, which
    /// replaces the last active window's workspace when no window holds
    /// exactly that folder. The one URL is the editor's folder URL with
    /// `windowId=_blank`, built in `EditorWindowLocator.swift` alone and sent
    /// from `AgentAppActivator` alone.
    func testNoSourceOpensAnEditorOrSessionURL() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        let forbidden = ["vscode://", "cursor://", "anthropic.claude-code/open", "open?session", "--resume"]
        let schemes = ["\"vscode\"", "\"vscode-insiders\"", "\"vscodium\"", "\"cursor\"", "\"code-oss\""]
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
            if file.lastPathComponent == "EditorWindowLocator.swift" {
                XCTAssertTrue(code.contains("URLQueryItem(name: \"windowId\", value: \"_blank\")"))
            } else {
                for token in schemes + ["host = \"file\""] {
                    XCTAssertFalse(code.contains(token), "\(file.lastPathComponent) builds an editor URL: \(token)")
                }
            }
            if file.lastPathComponent != "AgentAppActivator.swift" {
                XCTAssertFalse(code.contains("withApplicationAt"), "\(file.lastPathComponent) hands something to an app")
            }
        }
    }
}
