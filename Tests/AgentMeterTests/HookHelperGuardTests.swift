@testable import AgentMeter
import Foundation
import XCTest

/// The shared hook helper stays the newest running build's
/// (`HookHelperOwnership`, `ClaudeHookInstaller.refreshManagedCLI`,
/// `HookHelperGuard`). 2026-10-30: a banner click opened a stale copy from a
/// backup folder, its launch put its 10-16 helper back, and the running
/// build announced no task from then on.
final class HookHelperGuardTests: XCTestCase {
    private typealias Instance = HookHelperOwnership.Instance

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hook-helper-guard-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var destination: URL { directory.appendingPathComponent("bin/agentmeter-hook") }

    private func bundled(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("bundled-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// What another build's launch does: a temporary file renamed over it.
    private func overwriteAsAnotherBuild(_ contents: String) throws {
        let temporary = directory.appendingPathComponent("bin/agentmeter-hook.\(UUID().uuidString).tmp")
        try Data(contents.utf8).write(to: temporary)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    private func installed() -> String? {
        (try? Data(contentsOf: destination)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Ownership

    func testNewestBuildOwnsTheHelperWhicheverStartedLast() {
        let installed = Instance(pid: 3394, build: "202610301031", launchedAt: Date(timeIntervalSince1970: 100))
        let stale = Instance(pid: 11325, build: "202610162111", launchedAt: Date(timeIntervalSince1970: 460))
        XCTAssertEqual(HookHelperOwnership.owner(of: [installed, stale]), installed)
        XCTAssertEqual(HookHelperOwnership.owner(of: [stale, installed]), installed)
        XCTAssertEqual(HookHelperOwnership.owner(of: [stale]), stale, "left alone (a rollback), the older build installs its own")
        let unreadable = Instance(pid: 9, build: nil, launchedAt: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(HookHelperOwnership.owner(of: [unreadable, stale]), stale)
        XCTAssertEqual(HookHelperOwnership.owner(of: [Instance(pid: 1, build: "999"), Instance(pid: 2, build: "1000")])?.pid, 2,
                       "builds compare as numbers")
    }

    /// Equal builds (one bundle in two places): the last launched, as before,
    /// and a pid when even that ties. Never two owners, so never a tug of war.
    func testEqualBuildsHaveExactlyOneOwner() {
        let first = Instance(pid: 50, build: "202610301031", launchedAt: Date(timeIntervalSince1970: 100))
        let second = Instance(pid: 40, build: "202610301031", launchedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(HookHelperOwnership.owner(of: [first, second]), second)
        let tie = Instance(pid: 60, build: "202610301031", launchedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(HookHelperOwnership.owner(of: [tie, second]), tie)
        XCTAssertEqual(HookHelperOwnership.owner(of: [second, tie]), tie)
    }

    /// Review finding: a release is numbered by its CI run, a local build by
    /// its time. The version decides first; builds compare only within one
    /// numbering, otherwise the last launched owns it.
    func testVersionFirstAndBuildsOnlyWithinOneNumbering() {
        let release = Instance(pid: 1, version: "0.4.3", build: "58", launchedAt: Date(timeIntervalSince1970: 100))
        let staleLocal = Instance(pid: 2, version: "0.4.2", build: "202610162111", launchedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(HookHelperOwnership.owner(of: [release, staleLocal]), release, "newer version wins over a bigger build number")
        let sameVersionRelease = Instance(pid: 3, version: "0.4.2", build: "57", launchedAt: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(HookHelperOwnership.owner(of: [staleLocal, sameVersionRelease]), sameVersionRelease,
                       "numberings differ: the last launched")
        XCTAssertEqual(HookHelperOwnership.compareBuilds("202610162111", "202610301031"), .orderedAscending)
        XCTAssertEqual(HookHelperOwnership.compareBuilds("57", "58"), .orderedAscending)
        XCTAssertEqual(HookHelperOwnership.compareBuilds("57", "202610301031"), .orderedSame)
        XCTAssertEqual(HookHelperOwnership.compareBuilds(nil, "57"), .orderedAscending)
    }

    // MARK: Refresh

    func testRefreshInstallsReplacesAndLeavesItsOwnAlone() throws {
        let mine = try bundled("helper 202610301031")
        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: mine, ownsHelper: { true }, isTrusted: { _, _ in true }),
                       .installed(replacedOther: false))
        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: mine, ownsHelper: { true }, isTrusted: { _, _ in true }), .current)
        try overwriteAsAnotherBuild("helper 202610162111")
        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: mine, ownsHelper: { true }, isTrusted: { _, _ in true }),
                       .installed(replacedOther: true))
        XCTAssertEqual(installed(), "helper 202610301031")
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    /// A copy a newer build outranks writes nothing, not even its own launch
    /// install.
    func testOutrankedCopyNeverWritesTheHelper() throws {
        try overwriteAsAnotherBuild("helper newer")
        let older = try bundled("helper older")
        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: older, ownsHelper: { false }, isTrusted: { _, _ in true }),
                       .ownedByNewerInstance)
        XCTAssertEqual(installed(), "helper newer")
        XCTAssertEqual(ClaudeHookInstaller.refreshManagedCLI(at: destination, from: nil, ownsHelper: { true }, isTrusted: { _, _ in true }), .noBundledCopy)
    }

    // MARK: Guard

    /// The incident, replayed: while the owner runs, another copy's launch
    /// install is undone within the debounce, without a relaunch.
    @MainActor
    func testGuardRestoresTheHelperAnotherCopyReplaced() throws {
        let mine = try bundled("helper 202610301031")
        let destination = destination
        let guardian = HookHelperGuard(directory: destination.deletingLastPathComponent(), enabled: { true },
                                       refresh: { ClaudeHookInstaller.refreshManagedCLI(at: destination, from: mine, ownsHelper: { true }, isTrusted: { _, _ in true }) })
        guardian.start()
        defer { guardian.stop() }
        XCTAssertEqual(installed(), "helper 202610301031", "at start")

        try overwriteAsAnotherBuild("helper 202610162111")
        XCTAssertEqual(installed(), "helper 202610162111")
        // The watch and the debounce run on the main queue.
        let deadline = Date().addingTimeInterval(5)
        while installed() != "helper 202610301031", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(installed(), "helper 202610301031", "restored while running")
    }

    /// Review finding: two copies that each take themselves for the owner
    /// (a bundle replaced under a running copy) would rewrite the helper in
    /// turn forever, each write firing the other's watch. The brake leaves
    /// one restore each, then waits for the timer.
    @MainActor
    func testTwoGuardsThatBothOwnTheHelperStopRewritingIt() throws {
        let a = try bundled("helper A")
        let b = try bundled("helper B")
        let destination = destination
        var restores = 0
        func guardian(_ bundled: URL) -> HookHelperGuard {
            HookHelperGuard(directory: destination.deletingLastPathComponent(), enabled: { true }, refresh: {
                let result = ClaudeHookInstaller.refreshManagedCLI(at: destination, from: bundled, ownsHelper: { true }, isTrusted: { _, _ in true })
                if result == .installed(replacedOther: true) { restores += 1 }
                return result
            })
        }
        let first = guardian(a), second = guardian(b)
        first.start()
        second.start()
        defer { first.stop(); second.stop() }
        let until = Date().addingTimeInterval(3)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertLessThanOrEqual(restores, 2, "one restore each, then the brake")
    }

    @MainActor
    func testGuardDoesNothingWithTheHooksOff() throws {
        var refreshes = 0
        let guardian = HookHelperGuard(directory: destination.deletingLastPathComponent(), enabled: { false },
                                       refresh: { refreshes += 1; return .current })
        guardian.start()
        guardian.check()
        guardian.stop()
        XCTAssertEqual(refreshes, 0)
    }
}
