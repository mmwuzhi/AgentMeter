@testable import AgentMeter
import Darwin
import Foundation
import XCTest

/// `ClaudeSettingsFile` on real files, links and permissions in a temporary
/// directory. 2026-07-13: a hook install wrote a plain file over the
/// developer's symlinked `~/.claude/settings.json`, and the dotfile it led to
/// silently stopped applying.
final class ClaudeSettingsFileTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-settings-file-\(UUID().uuidString)", isDirectory: true)
    private let cli = URL(fileURLWithPath: "/Users/me/Library/Application Support/AgentMeter/bin/agentmeter-hook")

    private var claudeDirectory: URL { root.appendingPathComponent("home/.claude", isDirectory: true) }
    private var dotfiles: URL { root.appendingPathComponent("dotfiles", isDirectory: true) }
    private var backups: URL { root.appendingPathComponent("support/settings-backups", isDirectory: true) }
    private var settings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    private var file: ClaudeSettingsFile { ClaudeSettingsFile(url: settings, backupDirectory: backups) }

    private let original = Data("{\n  \"theme\": \"light\",\n  \"env\": {\"HTTPS_PROXY\": \"http://proxy.example:8080\"}\n}\n".utf8)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Undo the permission tests before cleaning up.
        _ = chmod(dotfiles.path, 0o755)
        _ = chmod(claudeDirectory.path, 0o755)
        if FileManager.default.fileExists(atPath: settings.path) { try? chmodACL(["-N"], on: settings) }
        try? FileManager.default.removeItem(at: root)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func managedCommands(at url: URL) throws -> [String] {
        let hooks = try json(at: url)["hooks"] as? [String: Any] ?? [:]
        return hooks.values
            .compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }.flatMap { $0 }
            .compactMap { $0["command"] as? String }
            .filter(ClaudeHookInstaller.isManagedCommand)
    }

    private func linkDestination(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Where a write lands: links resolved, `/var` as `/private/var`.
    private func real(_ url: URL) throws -> String {
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// `/bin/chmod` with an ACL argument (`+a "…"` or `-N`).
    private func chmodACL(_ arguments: [String], on url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments + [url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: Links

    func testInstallAndRemoveWriteThroughAnAbsoluteLinkAndKeepIt() throws {
        let target = dotfiles.appendingPathComponent("global-settings.json")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: target.path)

        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        XCTAssertEqual(linkDestination(settings), target.path, "still the same link")
        XCTAssertEqual(try managedCommands(at: target).count, 8)
        XCTAssertEqual(try json(at: target)["theme"] as? String, "light")
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(in: file))

        XCTAssertTrue(try ClaudeHookInstaller.remove(from: file))
        XCTAssertEqual(linkDestination(settings), target.path)
        XCTAssertEqual(try managedCommands(at: target), [])
        XCTAssertEqual(names(in: claudeDirectory), ["settings.json"], "nothing left next to the link")
        XCTAssertEqual(names(in: dotfiles), ["global-settings.json"], "nothing left next to the target")
    }

    func testRelativeLinkChainIsFollowedToTheFile() throws {
        let real = dotfiles.appendingPathComponent("real.json")
        try original.write(to: real)
        try FileManager.default.createSymbolicLink(atPath: dotfiles.appendingPathComponent("link.json").path,
                                                   withDestinationPath: "real.json")
        try FileManager.default.createSymbolicLink(atPath: settings.path,
                                                   withDestinationPath: "../../dotfiles/link.json")

        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        XCTAssertEqual(linkDestination(settings), "../../dotfiles/link.json")
        XCTAssertEqual(linkDestination(dotfiles.appendingPathComponent("link.json")), "real.json")
        XCTAssertEqual(try managedCommands(at: real).count, 8)
    }

    func testDanglingLinkIsRefusedAndLeftAsItWas() throws {
        let missing = dotfiles.appendingPathComponent("missing.json")
        try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: missing.path)

        XCTAssertThrowsError(try ClaudeHookInstaller.installHooks(running: cli, in: file)) { error in
            XCTAssertEqual(error as? ClaudeSettingsFile.Failure, .danglingLink(destination: missing.path))
        }
        XCTAssertEqual(linkDestination(settings), missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "the target is not created")
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(in: file))
    }

    func testLinkLoopIsRefused() throws {
        let other = dotfiles.appendingPathComponent("other.json")
        try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: other.path)
        try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: settings.path)

        XCTAssertThrowsError(try ClaudeHookInstaller.installHooks(running: cli, in: file)) { error in
            XCTAssertEqual(error as? ClaudeSettingsFile.Failure, .linkLoop)
        }
        XCTAssertEqual(linkDestination(settings), other.path)
    }

    func testLinkToADirectoryIsRefused() throws {
        try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: dotfiles.path)
        XCTAssertThrowsError(try ClaudeHookInstaller.installHooks(running: cli, in: file)) { error in
            XCTAssertEqual(error as? ClaudeSettingsFile.Failure, .notARegularFile)
        }
    }

    // MARK: Permissions and links of the file itself

    func testReadOnlyTargetIsRefusedAndUnchanged() throws {
        let target = dotfiles.appendingPathComponent("global-settings.json")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: target.path)
        XCTAssertEqual(chmod(target.path, 0o444), 0)

        XCTAssertThrowsError(try ClaudeHookInstaller.installHooks(running: cli, in: file)) { error in
            XCTAssertEqual(error as? ClaudeSettingsFile.Failure, .notWritable(path: try! self.real(target)))
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try mode(target), 0o444)
    }

    func testUnwritableTargetDirectoryIsRefusedAndUnchanged() throws {
        let target = dotfiles.appendingPathComponent("global-settings.json")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: target.path)
        XCTAssertEqual(chmod(dotfiles.path, 0o555), 0)

        XCTAssertThrowsError(try ClaudeHookInstaller.installHooks(running: cli, in: file)) { error in
            XCTAssertEqual(error as? ClaudeSettingsFile.Failure, .notWritable(path: try! self.real(self.dotfiles)))
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(linkDestination(settings), target.path)
    }

    func testHardLinkedFileIsReadButNeverReplaced() throws {
        try original.write(to: settings)
        try FileManager.default.linkItem(at: settings, to: dotfiles.appendingPathComponent("hard.json"))
        XCTAssertEqual(try file.read().originalData, original, "reading and isInstalled still work")
        XCTAssertThrowsError(try ClaudeHookInstaller.installHooks(running: cli, in: file)) { error in
            XCTAssertEqual(error as? ClaudeSettingsFile.Failure, .multipleHardLinks)
        }
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    // MARK: Writes

    func testPlainFileKeepsItsModeAndLeavesNoTemporaryFile() throws {
        try original.write(to: settings)
        XCTAssertEqual(chmod(settings.path, 0o755), 0)

        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        XCTAssertEqual(try mode(settings), 0o755)
        XCTAssertEqual(names(in: claudeDirectory), ["settings.json"])
        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(text.contains("http://proxy.example:8080"), "slashes are not escaped")
    }

    /// Review finding: the replacement took the old file's timestamps too,
    /// so a watcher comparing modification times could miss the write.
    func testRewriteLooksChangedAndKeepsModeAndExtendedAttributes() throws {
        try original.write(to: settings)
        XCTAssertEqual(chmod(settings.path, 0o640), 0)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: settings.path)
        let tag = Array("kept".utf8)
        XCTAssertEqual(setxattr(settings.path, "com.example.tag", tag, tag.count, 0, 0), 0)

        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertGreaterThan(modified, Date().addingTimeInterval(-60))
        XCTAssertEqual(try mode(settings), 0o640)
        XCTAssertGreaterThanOrEqual(getxattr(settings.path, "com.example.tag", nil, 0, 0, 0), 0)
    }

    /// Review finding: a "deny delete" ACL copied onto the temporary file
    /// made the failed rename leave it behind, one more each launch.
    func testRefusedRenameLeavesNoTemporaryFileEvenWithADenyDeleteACL() throws {
        try original.write(to: settings)
        try chmodACL(["+a", "everyone deny delete"], on: settings)

        XCTAssertThrowsError(try ClaudeHookInstaller.installHooks(running: cli, in: file)) { error in
            guard case .writeFailed = error as? ClaudeSettingsFile.Failure else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(names(in: claudeDirectory), ["settings.json"])
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    func testReplaceNeverOverwritesAFileThatAppearedMeanwhile() throws {
        let url = claudeDirectory.appendingPathComponent("state.json")
        let theirs = Data("theirs".utf8)
        XCTAssertThrowsError(try AtomicFile.replace(url, with: Data("mine".utf8), onlyIfAbsent: true,
                                                    beforeRename: { try theirs.write(to: url) })) { error in
            XCTAssertEqual((error as? AtomicFile.Failure)?.code, EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: url), theirs)
        XCTAssertEqual(names(in: claudeDirectory), ["state.json"])
    }

    func testReplaceStoppedRightBeforeTheRenameLeavesEverythingAsItWas() throws {
        try original.write(to: settings)
        struct Stop: Error {}
        XCTAssertThrowsError(try AtomicFile.replace(settings, with: Data("mine".utf8), metadataFrom: settings,
                                                    beforeRename: { throw Stop() }))
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertEqual(names(in: claudeDirectory), ["settings.json"])
    }

    func testMissingFileIsCreatedPrivateWithoutABackup() throws {
        try FileManager.default.removeItem(at: claudeDirectory)
        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        XCTAssertEqual(try managedCommands(at: settings).count, 8)
        XCTAssertEqual(try mode(settings), 0o600)
        XCTAssertEqual(file.existingBackups(), [])
    }

    func testUnchangedHooksWriteNothing() throws {
        try original.write(to: settings)
        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        let written = try Data(contentsOf: settings)
        XCTAssertFalse(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        XCTAssertEqual(try Data(contentsOf: settings), written)
        XCTAssertEqual(file.existingBackups().count, 1)
    }

    func testChangeMadeAfterTheReadIsNeverOverwritten() throws {
        try original.write(to: settings)
        let document = try file.read()
        let theirs = Data("{\"theme\": \"dark\"}".utf8)
        try theirs.write(to: settings)

        XCTAssertThrowsError(try file.write(["theme": "mine"], replacing: document)) { error in
            XCTAssertEqual(error as? ClaudeSettingsFile.Failure, .changedMeanwhile)
        }
        XCTAssertEqual(try Data(contentsOf: settings), theirs)
    }

    /// Review finding: a failed or untrusted helper refresh fell back to the
    /// bundle's own file, quarantine and all, at every launch.
    func testNoHelperMeansNoHooksRatherThanTheBundlesFile() throws {
        try original.write(to: settings)
        XCTAssertThrowsError(try ClaudeHookInstaller.install(managedCLI: { nil }, into: file)) { error in
            guard case .helperUnavailable = error as? ClaudeHookInstaller.InstallError else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    func testInvalidJSONIsRefused() throws {
        try Data("{ // comment\n}".utf8).write(to: settings)
        XCTAssertThrowsError(try file.read()) { error in
            XCTAssertEqual(error as? ClaudeSettingsFile.Failure, .invalidJSON)
        }
    }

    // MARK: Backups

    func testBackupHoldsTheReplacedBytesPrivately() throws {
        try original.write(to: settings)
        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))

        let saved = file.existingBackups()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.first)), original)
        XCTAssertEqual(try mode(XCTUnwrap(saved.first)), 0o600)
        XCTAssertEqual(try mode(backups), 0o700)
    }

    func testIdenticalBytesAreNotBackedUpTwice() throws {
        try original.write(to: settings)
        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        // The user puts the old file back; installing again replaces the
        // same bytes the newest backup already holds.
        try FileManager.default.removeItem(at: settings)
        try original.write(to: settings)
        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: file))
        XCTAssertEqual(file.existingBackups().count, 1)
    }

    /// Review finding: a clock that once ran ahead left a name that sorts
    /// after every new one, and the backup just written was pruned at once.
    func testTheBackupJustWrittenIsNeverPruned() throws {
        var limited = file
        limited.backupsKept = 2
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let future = backups.appendingPathComponent("settings.json.29991231T000000.000000000Z-ffffffff.json")
        try Data("{\"theme\": \"future\"}".utf8).write(to: future)
        try original.write(to: settings)

        XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: limited))
        let kept = limited.existingBackups()
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(try kept.contains { try Data(contentsOf: $0) == original }, "the new backup is kept")
    }

    func testOnlyTheNewestBackupsAreKept() throws {
        var limited = file
        limited.backupsKept = 2
        for theme in ["a", "b", "c"] {
            let bytes = Data("{\"theme\": \"\(theme)\"}".utf8)
            try? FileManager.default.removeItem(at: settings)
            try bytes.write(to: settings)
            XCTAssertTrue(try ClaudeHookInstaller.installHooks(running: cli, in: limited))
        }
        let kept = try limited.existingBackups().map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(kept, ["{\"theme\": \"b\"}", "{\"theme\": \"c\"}"])
    }
}
