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

    func testEditorURLSchemeMapping() {
        XCTAssertEqual(AgentAppActivator.editorURLScheme(for: "com.microsoft.VSCode"), "vscode")
        XCTAssertEqual(AgentAppActivator.editorURLScheme(for: "com.todesktop.230313mzl4w4u92"), "cursor")
        XCTAssertNil(AgentAppActivator.editorURLScheme(for: "com.apple.Terminal"))
    }

    func testEditorURLPercentEncodesReservedPathCharacters() {
        let url = AgentAppActivator.editorURL(
            bundleID: "com.microsoft.VSCode",
            cwd: "/Users/me/project #1?"
        )
        XCTAssertEqual(url?.absoluteString, "vscode://file/Users/me/project%20%231%3F")
    }
}
