import Darwin
import Foundation
@testable import AgentMeter
import XCTest

/// Everything runs against a temporary directory standing in for
/// `Application Support/AgentMeter` and a throwaway defaults suite, never the
/// real ones.
final class DebugCaptureTests: XCTestCase {
    private var root: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-debug-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "com.shu.agentmeter.tests.debug-capture.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func capture(enabled: Bool, now: @escaping () -> Date = Date.init) -> DebugCapture {
        defaults.set(enabled, forKey: DebugCapture.defaultsKey)
        return DebugCapture(defaults: defaults, supportDirectory: root, now: now)
    }

    private var debugDirectory: URL { root.appendingPathComponent("debug", isDirectory: true) }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    private func names(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func touch(_ url: URL, ageDays: Double, now: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86_400)],
                                              ofItemAtPath: url.path)
    }

    private let enterpriseBody: [String: Any] = [
        "plan_type": "enterprise",
        "extra_usage": ["is_enabled": true, "monthly_limit": 50_000, "used_credits": 1_234,
                        "currency": "USD", "decimal_places": 2] as [String: Any],
    ]

    // MARK: Off by default

    func testDefaultWritesNothingAnywhere() throws {
        let off = capture(enabled: false)
        XCTAssertFalse(DebugCapture(defaults: defaults, supportDirectory: root).isEnabled)

        XCTAssertFalse(off.record(enterpriseBody, as: .claudeOAuthUsage))
        XCTAssertFalse(off.record(responseBody: Data(#"{"credits":[]}"#.utf8), as: .codexResetCredits))
        _ = try ClaudeOAuthFetcher.parseSnapshot(from: enterpriseBody, debugCapture: off)
        CodexResetCreditFetcher.captureUnparsable(Data(#"{"credits":{}}"#.utf8), using: off)
        ClaudeResetGrantFetcher.captureUnparsable(["eligible": "yes"], using: off)

        XCTAssertEqual(names(root), [])
    }

    func testTheSwitchIsTheDocumentedDefaultsKey() {
        XCTAssertEqual(DebugCapture.defaultsKey, "debugCaptureResponses")
        defaults.set(true, forKey: "debugCaptureResponses")
        XCTAssertTrue(DebugCapture(defaults: defaults, supportDirectory: root).isEnabled)
    }

    // MARK: Enabled: where, with what permissions

    func testEnabledWritesOwnerOnlyFileInOwnerOnlyDirectory() throws {
        // A permissive umask must not widen anything.
        let previous = umask(0)
        defer { umask(previous) }

        let on = capture(enabled: true)
        XCTAssertTrue(on.record(enterpriseBody, as: .claudeOAuthUsage))

        XCTAssertEqual(names(root), ["debug"])
        XCTAssertEqual(try permissions(debugDirectory), 0o700)
        XCTAssertEqual(names(debugDirectory), ["claude-oauth-usage.json"])
        let file = debugDirectory.appendingPathComponent("claude-oauth-usage.json")
        XCTAssertEqual(try permissions(file), 0o600)
        let written = try json(file)
        XCTAssertEqual(written["plan_type"] as? String, "enterprise")
        // The amounts are what the capture is for.
        XCTAssertEqual((written["extra_usage"] as? [String: Any])?["monthly_limit"] as? Int, 50_000)
        XCTAssertEqual((written["extra_usage"] as? [String: Any])?["used_credits"] as? Int, 1_234)
    }

    func testAnExistingLooseDirectoryIsTightened() throws {
        let previous = umask(0)
        defer { umask(previous) }
        try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])

        XCTAssertTrue(capture(enabled: true).record(enterpriseBody, as: .claudeOAuthUsage))

        XCTAssertEqual(try permissions(debugDirectory), 0o700)
    }

    func testOneFilePerEndpointOverwritten() throws {
        let on = capture(enabled: true)
        XCTAssertTrue(on.record(["round": 1], as: .claudeResetGrants))
        XCTAssertTrue(on.record(["round": 2], as: .claudeResetGrants))
        XCTAssertTrue(on.record(["round": 3], as: .codexResetCredits))

        XCTAssertEqual(names(debugDirectory), ["claude-reset-grants.json", "codex-reset-credits.json"])
        XCTAssertEqual(try json(debugDirectory.appendingPathComponent("claude-reset-grants.json"))["round"] as? Int, 2)
        XCTAssertEqual(try permissions(debugDirectory.appendingPathComponent("claude-reset-grants.json")), 0o600)
    }

    func testABodyOverTheCapIsNotKept() throws {
        let on = capture(enabled: true)
        let huge = Data(repeating: UInt8(ascii: "x"), count: DebugCapture.maxBytes + 1)

        let manyFields = Dictionary(uniqueKeysWithValues: (0..<20_000).map { ("field\($0)", $0) })
        XCTAssertFalse(on.record(manyFields, as: .claudeOAuthUsage))
        // A huge body leaves only its size.
        XCTAssertTrue(on.record(responseBody: huge, as: .codexResetCredits))

        XCTAssertEqual(names(debugDirectory), ["codex-reset-credits.json"])
        let note = try json(debugDirectory.appendingPathComponent("codex-reset-credits.json"))
        XCTAssertEqual(note["bytes"] as? Int, huge.count)
        XCTAssertEqual(note.count, 2)
    }

    func testABodyThatIsNotJSONLeavesOnlyItsSize() throws {
        let html = Data("<html>Hello dev@example.com sk-ant-api03-abcdefghijklmnop1234</html>".utf8)

        XCTAssertTrue(capture(enabled: true).record(responseBody: html, as: .codexResetCredits))

        let file = debugDirectory.appendingPathComponent("codex-reset-credits.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("example.com"))
        XCTAssertFalse(text.contains("sk-ant"))
        XCTAssertEqual(try json(file)["bytes"] as? Int, html.count)
    }

    // MARK: Redaction

    func testRedactsWhatCouldNameTheAccountAndKeepsTheShape() throws {
        let body: [String: Any] = [
            "plan_type": "enterprise",
            "account": ["uuid": "5b1c9a52-0000-4000-8000-123456789abc", "email": "dev@example.com",
                        "name": "Dev Eloper", "tier": "enterprise"] as [String: Any],
            "organization": ["id": "org_123", "display_name": "Acme", "plan": "enterprise"] as [String: Any],
            "organization_id": "org_456",
            "chatgpt_account_id": "acct_789",
            "access_token": "tok-abc",
            "Authorization": "Bearer abcdef123456",
            "request_signature": "sig-xyz",
            "user": ["id": NSNull(), "full_name": "Dev Eloper"] as [String: Any],
            "limits": [["kind": "weekly_scoped", "percent": 3,
                        "scope": ["model": ["id": NSNull(), "display_name": "Fable"] as [String: Any]] as [String: Any]]],
            "extra_usage": ["is_enabled": true, "monthly_limit": 50_000, "used_credits": 1_234,
                            "currency": "USD"] as [String: Any],
            "note": "mail dev@example.com, Bearer abcdef123456, sk-ant-api03-abcdefghijklmnop1234, eyJhbGciOi.eyJzdWIiOi.sig, ghp_abcdefghijklmnopqrstuv",
            "request": "9f4d2f0e-1111-2222-3333-444455556666",
            "blob": String(repeating: "A1", count: 30),
            "resets_at": "2026-09-30T04:13:36.000000+00:00",
        ]

        XCTAssertTrue(capture(enabled: true).record(body, as: .claudeOAuthUsage))

        let file = debugDirectory.appendingPathComponent("claude-oauth-usage.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        for secret in ["dev@example.com", "Dev Eloper", "5b1c9a52", "org_123", "org_456", "acct_789", "tok-abc",
                       "sig-xyz", "abcdef123456", "sk-ant", "eyJ", "ghp_", "9f4d2f0e", "Acme", "A1A1A1A1"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked into the capture")
        }
        let written = try json(file)
        let account = try XCTUnwrap(written["account"] as? [String: Any])
        XCTAssertEqual(account["uuid"] as? String, DebugCapture.placeholder)
        XCTAssertEqual(account["email"] as? String, DebugCapture.placeholder)
        XCTAssertEqual(account["name"] as? String, DebugCapture.placeholder)
        // The plan beside the identity stays.
        XCTAssertEqual(account["tier"] as? String, "enterprise")
        XCTAssertEqual((written["organization"] as? [String: Any])?["plan"] as? String, "enterprise")
        // A null stays null: the shape is still readable.
        XCTAssertTrue((written["user"] as? [String: Any])?["id"] is NSNull)
        // What the quota parse reads is not touched.
        let model = ((((written["limits"] as? [[String: Any]])?.first?["scope"]) as? [String: Any])?["model"]) as? [String: Any]
        XCTAssertEqual(model?["display_name"] as? String, "Fable")
        XCTAssertEqual(written["plan_type"] as? String, "enterprise")
        XCTAssertEqual(written["resets_at"] as? String, "2026-09-30T04:13:36.000000+00:00")
        XCTAssertEqual((written["extra_usage"] as? [String: Any])?["used_credits"] as? Int, 1_234)
    }

    func testResetGrantGlueKeepsOnlyTheStatusBlockRedacted() throws {
        let on = capture(enabled: true)

        ClaudeResetGrantFetcher.captureUnparsable(
            ["eligible": "yes", "grants": [["id": "launch-2026", "resets_left": 2, "owner_email": "dev@example.com"]]],
            using: on)

        let file = debugDirectory.appendingPathComponent("claude-reset-grants.json")
        let written = try json(file)
        XCTAssertEqual(Set(written.keys), ["cedar_ember"])
        let block = try XCTUnwrap(written["cedar_ember"] as? [String: Any])
        XCTAssertEqual(block["eligible"] as? String, "yes")
        let grant = try XCTUnwrap((block["grants"] as? [[String: Any]])?.first)
        XCTAssertEqual(grant["id"] as? String, "launch-2026")
        XCTAssertEqual(grant["owner_email"] as? String, DebugCapture.placeholder)
        XCTAssertEqual(try permissions(file), 0o600)
    }

    func testNullStatusBlockIsWrittenAsNull() throws {
        ClaudeResetGrantFetcher.captureUnparsable(nil, using: capture(enabled: true))

        let written = try json(debugDirectory.appendingPathComponent("claude-reset-grants.json"))
        XCTAssertTrue(written["cedar_ember"] is NSNull)
    }

    func testCodexGlueRedactsTheCreditsBody() throws {
        let body = Data(#"{"credits":{"id":"c1","user_id":"u-1","expires":"x"},"account_id":"acct_1"}"#.utf8)

        CodexResetCreditFetcher.captureUnparsable(body, using: capture(enabled: true))

        let file = debugDirectory.appendingPathComponent("codex-reset-credits.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("acct_1"))
        XCTAssertFalse(text.contains("u-1"))
        let written = try json(file)
        XCTAssertEqual(written["account_id"] as? String, DebugCapture.placeholder)
        XCTAssertEqual((written["credits"] as? [String: Any])?["expires"] as? String, "x")
        XCTAssertEqual(try permissions(file), 0o600)
    }

    // MARK: Retention

    func testCapturingDeletesCapturesOlderThanSevenDays() throws {
        let now = Date()
        let on = capture(enabled: true, now: { now })
        try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        let stale = debugDirectory.appendingPathComponent("codex-reset-credits.json")
        let fresh = debugDirectory.appendingPathComponent("claude-reset-grants.json")
        try Data("{}".utf8).write(to: stale)
        try Data("{}".utf8).write(to: fresh)
        try touch(stale, ageDays: 7, now: now.addingTimeInterval(-1))
        try touch(fresh, ageDays: 7, now: now.addingTimeInterval(1))

        XCTAssertTrue(on.record(enterpriseBody, as: .claudeOAuthUsage))

        XCTAssertEqual(names(debugDirectory), ["claude-oauth-usage.json", "claude-reset-grants.json"])
    }

    func testLaunchDeletesOldCapturesWhetherOrNotCapturingIsOn() throws {
        for enabled in [false, true] {
            let now = Date()
            let launch = capture(enabled: enabled, now: { now })
            try? FileManager.default.removeItem(at: debugDirectory)
            try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
            let old = debugDirectory.appendingPathComponent("claude-oauth-usage.json")
            let leftover = debugDirectory.appendingPathComponent(".claude-oauth-usage.json.1.ABC.tmp")
            let recent = debugDirectory.appendingPathComponent("codex-reset-credits.json")
            let foreign = debugDirectory.appendingPathComponent("notes.txt")
            for url in [old, leftover, recent, foreign] { try Data("{}".utf8).write(to: url) }
            try touch(old, ageDays: 8, now: now)
            try touch(leftover, ageDays: 8, now: now)
            try touch(recent, ageDays: 6, now: now)
            try touch(foreign, ageDays: 30, now: now)

            launch.cleanUpAtLaunch()

            XCTAssertEqual(names(debugDirectory), ["codex-reset-credits.json", "notes.txt"], "enabled: \(enabled)")
        }
    }

    func testSweepNeverFollowsASymlink() throws {
        let now = Date()
        try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try touch(outside, ageDays: 30, now: now)
        let link = debugDirectory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        capture(enabled: false, now: { now.addingTimeInterval(30 * 86_400) }).cleanUpAtLaunch()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(names(debugDirectory), ["link.json"])
    }

    // MARK: Legacy files

    func testLegacyNamesAreTheOnesEarlierBuildsWrote() {
        XCTAssertEqual(DebugCapture.legacyFileNames, [
            "debug-claude-oauth-usage.json",
            "debug-claude-reset-grants.json",
            "debug-codex-reset-credits.json",
        ])
    }

    private func writeLegacy(_ name: String, _ contents: String = "{\"spend\": 1}", mode: mode_t = 0o644) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, mode), 0)
        return url
    }

    /// The user asked that nothing an earlier build wrote be deleted on
    /// upgrade: the legacy captures stay, owner-only.
    func testLaunchKeepsTheLegacyFilesAndMakesThemOwnerOnly() throws {
        let decoys = ["debug-claude-oauth-usage.json.bak", "debug-other.json", "last-state.json", "pricing.json",
                      "history.sqlite"]
        for name in DebugCapture.legacyFileNames + decoys {
            _ = try writeLegacy(name, "\(name) contents")
        }
        // A directory with a legacy name is left as it is, contents and mode.
        let directory = root.appendingPathComponent("debug-codex-reset-credits.json")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        try Data("keep".utf8).write(to: directory.appendingPathComponent("inside.txt"))

        capture(enabled: false).cleanUpAtLaunch()

        XCTAssertEqual(names(root), (DebugCapture.legacyFileNames + decoys).sorted())
        for name in DebugCapture.legacyFileNames where name != "debug-codex-reset-credits.json" {
            let url = root.appendingPathComponent(name)
            XCTAssertEqual(try permissions(url), 0o600, name)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\(name) contents", "kept as it was")
        }
        for name in decoys {
            XCTAssertEqual(try permissions(root.appendingPathComponent(name)), 0o644, "\(name) is not ours to change")
        }
        XCTAssertEqual(try permissions(directory), 0o755)
        XCTAssertEqual(names(directory), ["inside.txt"])
    }

    func testLaunchWithCapturingOnAlsoTightensAndKeeps() throws {
        let url = try writeLegacy("debug-claude-oauth-usage.json")
        capture(enabled: true).cleanUpAtLaunch()
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLegacySymlinkIsNeverFollowed() throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("debug-capture-elsewhere-\(UUID().uuidString).json")
        try Data("someone else's".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        XCTAssertEqual(chmod(elsewhere.path, 0o644), 0)
        let link = root.appendingPathComponent("debug-claude-reset-grants.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: elsewhere.path)

        XCTAssertEqual(DebugCapture.tightenLegacyFiles(in: root), [])
        XCTAssertEqual(try permissions(elsewhere), 0o644)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), elsewhere.path)
    }

    func testHardLinkedLegacyFileIsLeftAlone() throws {
        let url = try writeLegacy("debug-codex-reset-credits.json")
        let other = root.appendingPathComponent("elsewhere.json")
        try FileManager.default.linkItem(at: url, to: other)
        XCTAssertEqual(DebugCapture.tightenLegacyFiles(in: root), [])
        XCTAssertEqual(try permissions(other), 0o644)
    }

    func testPrivateLegacyFileAndFIFOAreLeftAlone() throws {
        let privateFile = try writeLegacy("debug-claude-oauth-usage.json", mode: 0o400)
        let fifo = root.appendingPathComponent("debug-claude-reset-grants.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0)
        XCTAssertEqual(chmod(fifo.path, 0o644), 0, "whatever the umask")
        XCTAssertEqual(DebugCapture.tightenLegacyFiles(in: root), [], "nothing to change, and no hang on the FIFO")
        XCTAssertEqual(try permissions(privateFile), 0o400)
        XCTAssertEqual(try permissions(fifo), 0o644)
    }

    func testLegacyCleanupToleratesMissingFiles() {
        capture(enabled: false).cleanUpAtLaunch()
        XCTAssertEqual(names(root), [])
    }

    // MARK: Fetching is unaffected

    func testParseResultIsTheSameWithCaptureOnOrOff() throws {
        let off = try ClaudeOAuthFetcher.parseSnapshot(from: enterpriseBody, credentialPlan: "team",
                                                       debugCapture: capture(enabled: false))
        XCTAssertEqual(names(root), [])
        let on = try ClaudeOAuthFetcher.parseSnapshot(from: enterpriseBody, credentialPlan: "team",
                                                      debugCapture: capture(enabled: true))
        XCTAssertEqual(names(debugDirectory), ["claude-oauth-usage.json"])

        XCTAssertEqual(on.windows, off.windows)
        XCTAssertEqual(on.source, off.source)
        XCTAssertEqual(on.planType, off.planType)
        XCTAssertEqual(on.rateLimitTier, off.rateLimitTier)
        XCTAssertEqual(on.extraUsageSpentUSD, off.extraUsageSpentUSD)
        XCTAssertEqual(on.extraUsageSpentUSD ?? 0, 12.34, accuracy: 0.0001)
        XCTAssertEqual(on.note, off.note)
    }

    func testABodyWithWindowsIsNeverCaptured() throws {
        let body: [String: Any] = ["five_hour": ["utilization": 10, "resets_at": "2025-01-15T12:00:00Z"]]

        _ = try ClaudeOAuthFetcher.parseSnapshot(from: body, debugCapture: capture(enabled: true))

        XCTAssertEqual(names(root), [])
    }

    func testAnEmptyBodyStillThrowsWithCaptureOn() {
        XCTAssertThrowsError(try ClaudeOAuthFetcher.parseSnapshot(from: [:], debugCapture: capture(enabled: true))) {
            XCTAssertEqual(($0 as? URLError)?.code, .cannotParseResponse)
        }
        XCTAssertEqual(names(root), [])
    }
}
