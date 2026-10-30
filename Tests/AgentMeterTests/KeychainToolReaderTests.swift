@testable import AgentMeter
import Darwin
import Foundation
import XCTest

/// `KeychainToolReader` against stand-in tools (shell scripts), and how
/// `ClaudeCredentials` acts on each answer. Nothing here reads a real
/// Keychain item.
final class KeychainToolReaderTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("keychain-tool-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ClaudeCredentials.resetKeychainBackoff()
    }

    override func tearDownWithError() throws {
        ClaudeCredentials.resetKeychainBackoff()
        try? FileManager.default.removeItem(at: directory)
    }

    private func tool(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("tool-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func run(_ body: String, timeout: TimeInterval = 5, limit: Int = 1024) throws -> KeychainToolReader.Result {
        KeychainToolReader.run(executable: try tool(body), arguments: [], timeout: timeout, outputLimit: limit)
    }

    // MARK: Reader

    func testOutputWithoutTheTrailingNewline() throws {
        XCTAssertEqual(try run(#"printf '{"claudeAiOauth":{}}\n'"#), .data(Data(#"{"claudeAiOauth":{}}"#.utf8)))
    }

    func testFailuresCarryTheExitStatus() throws {
        XCTAssertEqual(try run("exit 44"), .failed(.exit(44)), "security: item not found")
        XCTAssertEqual(try run("printf 'partial'; exit 1"), .failed(.exit(1)), "output of a failed read is dropped")
        XCTAssertEqual(try run("printf '\\n'"), .failed(.emptyOutput))
        XCTAssertEqual(try run("kill -9 $$"), .failed(.uncaughtSignal(SIGKILL)))
    }

    func testStdinIsClosed() throws {
        // A tool that reads stdin gets EOF at once instead of waiting forever.
        XCTAssertEqual(try run("cat; printf 'ok'", timeout: 5), .data(Data("ok".utf8)))
    }

    func testTimeoutEndsTheTool() throws {
        let started = Date()
        let pidFile = directory.appendingPathComponent("pid")
        // Long enough for the script to start even with the whole suite running.
        XCTAssertEqual(try run("echo $$ > '\(pidFile.path)'; exec sleep 30", timeout: 2), .failed(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        let pid = try XCTUnwrap(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(kill(pid, 0), 0, "the tool is gone")
    }

    func testATermIgnoringToolIsKilled() throws {
        let started = Date()
        let pidFile = directory.appendingPathComponent("pid")
        XCTAssertEqual(try run("trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do sleep 0.05; done", timeout: 2),
                       .failed(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 7)
        let pid = try XCTUnwrap(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(kill(pid, 0), 0, "the tool is gone")
    }

    /// Far more than the pipe holds: drained while it runs, so the tool
    /// finishes, and the answer is refused rather than cut.
    func testOutputPastTheLimitIsRefused() throws {
        XCTAssertEqual(try run("head -c 300000 /dev/zero | tr '\\0' 'a'", timeout: 5, limit: 64 * 1024),
                       .failed(.outputTooLarge))
        XCTAssertEqual(try run("head -c 1024 /dev/zero | tr '\\0' 'a'", limit: 1024), .data(Data(repeating: 0x61, count: 1024)))
    }

    func testAToolThatCannotStartIsUnavailable() {
        let missing = directory.appendingPathComponent("no-such-tool")
        XCTAssertEqual(KeychainToolReader.run(executable: missing, arguments: [], timeout: 1, outputLimit: 1024), .unavailable)
    }

    /// Output already written is kept when something the tool started still
    /// holds the pipe after it exits (review finding: a whole-chunk read
    /// lost it).
    func testOutputIsKeptWhenAChildHoldsThePipe() throws {
        XCTAssertEqual(try run("(sleep 3) & printf 'ok'"), .data(Data("ok".utf8)))
    }

    /// The production call: Apple's tool by absolute path, Claude Code's
    /// account and service, `-w`; nothing secret on the command line.
    func testTheRealReadIsFixed() {
        XCTAssertEqual(KeychainToolReader.securityTool.path, "/usr/bin/security")
        XCTAssertTrue(KeychainToolReader.isAvailable)
        XCTAssertEqual(KeychainToolReader.arguments(service: "Claude Code-credentials", account: "dev"),
                       ["find-generic-password", "-a", "dev", "-s", "Claude Code-credentials", "-w"])
        XCTAssertEqual(KeychainToolReader.outputLimit, 64 * 1024)
    }

    /// Claude Code 2.1.301's rule: `USER`, else the login name, and
    /// `claude-code-user` for anything outside `^[a-zA-Z0-9._-]+$`.
    func testTheAccountFollowsClaudeCode() {
        XCTAssertEqual(ClaudeCredentials.keychainAccount(environment: ["USER": "a.b-c_1"], userName: "x"), "a.b-c_1")
        XCTAssertEqual(ClaudeCredentials.keychainAccount(environment: [:], userName: "dev"), "dev")
        XCTAssertEqual(ClaudeCredentials.keychainAccount(environment: ["USER": ""], userName: "dev"), "dev")
        XCTAssertEqual(ClaudeCredentials.keychainAccount(environment: ["USER": "DOMAIN\\dev"], userName: "dev"), "claude-code-user")
        XCTAssertEqual(ClaudeCredentials.keychainAccount(environment: ["USER": "dëv"], userName: "dev"), "claude-code-user")
        XCTAssertEqual(ClaudeCredentials.keychainAccount(environment: [:], userName: ""), "claude-code-user")
    }

    // MARK: ClaudeCredentials

    private let credential = Data(#"{"claudeAiOauth":{"accessToken":"a","expiresAt":1893456000000}}"#.utf8)

    /// Only a system without the tool reads in process; a failed read never
    /// tries the prompting path, whatever went wrong.
    func testOnlyAMissingToolFallsBackToTheSecurityAPI() {
        var apiReads = 0
        let api: () -> ClaudeCredentials.Token? = { apiReads += 1; return nil }
        let now = ContinuousClock.now
        XCTAssertEqual(ClaudeCredentials.keychainToken(toolAvailable: true, read: { .data(self.credential) },
                                                       readWithSecurityAPI: api, now: now)?.accessToken, "a")
        let failures: [KeychainToolReader.Result] = [
            .failed(.exit(44)), .failed(.exit(51)), .failed(.exit(128)), .failed(.uncaughtSignal(9)),
            .failed(.timedOut), .failed(.outputTooLarge), .failed(.emptyOutput), .unavailable,
        ]
        for failure in failures {
            ClaudeCredentials.resetKeychainBackoff()
            XCTAssertNil(ClaudeCredentials.keychainToken(toolAvailable: true, read: { failure }, readWithSecurityAPI: api, now: now))
        }
        XCTAssertEqual(apiReads, 0, "a failed read never tries the prompting path")
        _ = ClaudeCredentials.keychainToken(toolAvailable: false, read: { XCTFail("no tool to run"); return .unavailable },
                                            readWithSecurityAPI: api, now: now)
        XCTAssertEqual(apiReads, 1)
    }

    /// Review finding: a cancelled (128) or denied (51) dialog came back on
    /// every refresh. Any failure but "no such item" holds reads off.
    func testAFailureHoldsOffTheNextReadsButNoItemDoesNot() {
        let start = ContinuousClock.now
        var reads = 0
        XCTAssertNil(ClaudeCredentials.keychainToken(toolAvailable: true, read: { reads += 1; return .failed(.exit(44)) },
                                                     readWithSecurityAPI: { nil }, now: start))
        XCTAssertFalse(ClaudeCredentials.keychainReadsHeldOff(now: start), "not signed in yet: keep looking")

        for failure: KeychainToolReader.Failure in [.exit(128), .exit(51), .timedOut] {
            ClaudeCredentials.resetKeychainBackoff()
            reads = 0
            XCTAssertNil(ClaudeCredentials.keychainToken(toolAvailable: true, read: { reads += 1; return .failed(failure) },
                                                         readWithSecurityAPI: { nil }, now: start))
            XCTAssertTrue(ClaudeCredentials.keychainReadsHeldOff(now: start.advanced(by: .seconds(60))))
            XCTAssertNil(ClaudeCredentials.keychainToken(toolAvailable: true, read: { reads += 1; return .data(self.credential) },
                                                         readWithSecurityAPI: { nil }, now: start.advanced(by: .seconds(60))))
            XCTAssertEqual(reads, 1, "held off after \(failure)")
            let later = start.advanced(by: ClaudeCredentials.failureBackoff)
            XCTAssertFalse(ClaudeCredentials.keychainReadsHeldOff(now: later))
            XCTAssertEqual(ClaudeCredentials.keychainToken(toolAvailable: true, read: { reads += 1; return .data(self.credential) },
                                                           readWithSecurityAPI: { nil }, now: later)?.accessToken, "a")
            XCTAssertEqual(reads, 2)
        }
    }

    func testHexOutputIsDecoded() throws {
        let hex = credential.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ClaudeCredentials.parse(Data(hex.utf8))?.accessToken, "a")
        XCTAssertEqual(ClaudeCredentials.parse(Data(hex.uppercased().utf8))?.accessToken, "a")
        XCTAssertNil(ClaudeCredentials.hexDecoded(Data("{}".utf8)))
        XCTAssertNil(ClaudeCredentials.hexDecoded(Data("abc".utf8)), "odd length")
        XCTAssertEqual(ClaudeCredentials.parse(credential)?.accessToken, "a", "JSON as it is")
    }
}
