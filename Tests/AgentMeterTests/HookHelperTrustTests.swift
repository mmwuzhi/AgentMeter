@testable import AgentMeter
import Darwin
import Foundation
import Security
import XCTest

/// The shared hook helper on another Mac: the bundle came from a downloaded
/// disk image, so its helper carries `com.apple.quarantine`, and a plain copy
/// handed that to the file Claude Code runs (`HookHelperTrust`).
final class HookHelperTrustTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hook-helper-trust-\(UUID().uuidString)", isDirectory: true)
    /// The value a browser download carries (flags;time;agent;event id).
    private let quarantine = "0083;6721a3f0;Safari;7D5C4A1E-4C3B-4E6F-9A2B-0C1D2E3F4A5B"

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var destination: URL { directory.appendingPathComponent("bin/agentmeter-hook") }

    private func quarantined(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("bundled-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        try setQuarantine(url)
        return url
    }

    private func setQuarantine(_ url: URL) throws {
        let value = Array(quarantine.utf8)
        guard setxattr(url.path, HookHelperTrust.quarantineAttribute, value, value.count, 0, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: Install

    func testInstalledCopyDoesNotInheritTheDownloadsQuarantine() throws {
        let bundled = try quarantined("helper")
        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: bundled,
                                                             ownsHelper: { true }, isTrusted: { _, _ in true }),
                       .installed(replacedOther: false))
        XCTAssertFalse(HookHelperTrust.hasQuarantine(destination))
        XCTAssertTrue(HookHelperTrust.hasQuarantine(bundled), "the bundle itself is left alone")
        XCTAssertEqual(try Data(contentsOf: destination), Data("helper".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testUntrustedHelperIsNeverInstalled() throws {
        let bundled = try quarantined("helper")
        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: bundled,
                                                             ownsHelper: { true }, isTrusted: { _, _ in false }),
                       .untrusted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A byte-identical copy is left as it is, attributes included: nothing
    /// strips or works around a quarantine already on a file. The Settings
    /// probe reports a copy macOS refuses.
    func testByteIdenticalCopyIsLeftAsItIs() throws {
        let bundled = try quarantined("helper")
        try Data("helper".utf8).write(to: destination)
        try setQuarantine(destination)
        let before = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? Int

        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: bundled,
                                                             ownsHelper: { true }, isTrusted: { _, _ in true }),
                       .current)
        XCTAssertTrue(HookHelperTrust.hasQuarantine(destination))
        let after = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after)
    }

    func testCurrentCopyNeedsNoSignatureCheck() throws {
        let bundled = try quarantined("helper")
        try Data("helper".utf8).write(to: destination)
        var checks = 0
        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: bundled, ownsHelper: { true },
                                                             isTrusted: { _, _ in checks += 1; return true }),
                       .current)
        XCTAssertEqual(checks, 0)
    }

    // MARK: Signatures, on real binaries

    func testSignatureCheckAcceptsValidCodeAndRejectsTamperingAndOtherTeams() throws {
        let copy = directory.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        XCTAssertTrue(HookHelperTrust.hasValidSignature(copy, team: nil), "Apple's signature is valid on a copy")
        XCTAssertFalse(HookHelperTrust.hasValidSignature(copy, team: "ABCDE12345"), "not signed by that team")

        var bytes = try Data(contentsOf: copy)
        let offset = try sliceOffset(of: bytes) + 0x200
        bytes[offset] ^= 0xFF
        try bytes.write(to: copy)
        XCTAssertFalse(HookHelperTrust.hasValidSignature(copy, team: nil), "a changed byte breaks it")

        let unsigned = directory.appendingPathComponent("unsigned")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: unsigned)
        XCTAssertFalse(HookHelperTrust.hasValidSignature(unsigned, team: nil))
        XCTAssertFalse(HookHelperTrust.hasValidSignature(directory.appendingPathComponent("missing"), team: nil))
    }

    func testTeamIdentifierWithRequirementSyntaxIsRejected() throws {
        let copy = directory.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        XCTAssertFalse(HookHelperTrust.hasValidSignature(copy, team: "X\" or anchor apple or \"Y"))
    }

    // MARK: Ad-hoc builds, on real ad-hoc signatures

    func testAdHocAppSealsItsHelpersDigest() throws {
        let (app, helper) = try adHocApp()
        let data = try Data(contentsOf: helper)
        let sealed = try XCTUnwrap(sealedDigest(of: app))
        XCTAssertEqual(sealed, HookHelperTrust.sha256Hex(data))
        XCTAssertTrue(HookHelperTrust.isTrusted(data, from: helper, policy: .sealedDigest(sealed)))
        XCTAssertFalse(HookHelperTrust.isTrusted(data, from: helper, policy: .sameTeam("ABCDE12345")),
                       "an ad-hoc helper carries no team")
    }

    /// The old ad-hoc check was a valid signature alone, which any signed
    /// binary has.
    func testSealedDigestRejectsOtherValidlySignedCode() throws {
        let (app, _) = try adHocApp()
        let sealed = try XCTUnwrap(sealedDigest(of: app))
        let other = directory.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: other)
        XCTAssertTrue(HookHelperTrust.hasValidSignature(other, team: nil))
        XCTAssertFalse(HookHelperTrust.isTrusted(try Data(contentsOf: other), from: other,
                                                 policy: .sealedDigest(sealed)))
    }

    func testSealedDigestPolicyWithoutADigestTrustsNothing() throws {
        let (_, helper) = try adHocApp()
        XCTAssertFalse(HookHelperTrust.isTrusted(try Data(contentsOf: helper), from: helper,
                                                 policy: .sealedDigest(nil)))
    }

    func testMatchingDigestStillNeedsAValidSignature() throws {
        let script = directory.appendingPathComponent("unsigned")
        let data = Data("#!/bin/sh\necho hi\n".utf8)
        try data.write(to: script)
        XCTAssertFalse(HookHelperTrust.isTrusted(data, from: script,
                                                 policy: .sealedDigest(HookHelperTrust.sha256Hex(data))))
    }

    /// A helper swapped into the bundle after signing, even one that is
    /// itself validly signed, breaks the app's seal: no digest is read.
    func testSwappedHelperBreaksTheAppsSeal() throws {
        let (app, helper) = try adHocApp()
        try codesign(helper, "--identifier", "com.example.other")
        XCTAssertTrue(HookHelperTrust.hasValidSignature(helper, team: nil))
        XCTAssertNil(sealedDigest(of: app))
    }

    func testEditedDigestBreaksTheAppsSeal() throws {
        let (app, _) = try adHocApp()
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        info[HookHelperTrust.helperDigestKey] = String(repeating: "0", count: 64)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plistURL)
        XCTAssertNil(sealedDigest(of: app))
    }

    func testAppWithoutADigestSealsNone() throws {
        let (app, _) = try adHocApp(digest: { _ in nil })
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(app as CFURL, [], &code), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), SecCSFlags(rawValue: kSecCSStrictValidate), nil),
                       errSecSuccess, "the app itself is intact")
        XCTAssertNil(sealedDigest(of: app))
    }

    /// A minimal app signed the way `Scripts/bundle.sh` signs an ad-hoc
    /// build: the helper, then its SHA-256 into the Info.plist, then the app.
    private func adHocApp(digest: (Data) -> String? = HookHelperTrust.sha256Hex) throws -> (app: URL, helper: URL) {
        let app = directory.appendingPathComponent("Test-\(UUID().uuidString).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let trueURL = URL(fileURLWithPath: "/usr/bin/true")
        try FileManager.default.copyItem(at: trueURL, to: macOS.appendingPathComponent("Test"))
        let helper = helpers.appendingPathComponent("agentmeter-hook")
        try FileManager.default.copyItem(at: trueURL, to: helper)
        try codesign(helper, "--identifier", "com.example.test.hook")
        var info: [String: Any] = [
            "CFBundleIdentifier": "com.example.test",
            "CFBundleExecutable": "Test",
            "CFBundlePackageType": "APPL",
        ]
        info[HookHelperTrust.helperDigestKey] = digest(try Data(contentsOf: helper))
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try codesign(app)
        return (app, helper)
    }

    private func codesign(_ url: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none"] + arguments + [url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private func sealedDigest(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return HookHelperTrust.sealedHelperDigest(in: code)
    }

    /// The first architecture's offset in a universal binary, else 0.
    private func sliceOffset(of bytes: Data) throws -> Int {
        func bigEndian(_ at: Int) -> Int {
            bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        guard bytes.count > 16, bigEndian(0) == 0xCAFEBABE else { return 0 }
        return bigEndian(8 + 8)
    }

    // MARK: Probe

    func testProbeRunsTheHelpersPathCommand() throws {
        let helper = directory.appendingPathComponent("prints-path")
        try Data("#!/bin/sh\n[ \"$1\" = path ] && echo /tmp/agent-status\n".utf8).write(to: helper)
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        XCTAssertEqual(HookHelperTrust.probe(helper), .ran)
    }

    func testProbeSaysWhyTheHelperDidNotRun() throws {
        let failing = directory.appendingPathComponent("fails")
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: failing)
        XCTAssertEqual(chmod(failing.path, 0o755), 0)
        XCTAssertEqual(HookHelperTrust.probe(failing), .failed("it exited with status 3"))
        XCTAssertEqual(HookHelperTrust.probe(directory.appendingPathComponent("missing")),
                       .failed("macOS didn't let it start"))
    }
}
