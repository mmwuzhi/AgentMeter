import Foundation
@testable import AgentMeter
import XCTest

final class CodexRolloutReaderTests: XCTestCase {
    /// Regression: Codex ≥0.142 moves older sessions from `~/.codex/sessions`
    /// into `~/.codex/archived_sessions`. The reader used to enumerate only the
    /// live `sessions` dir, so the instant Codex archived an active session the
    /// day's usage/spend collapsed to whatever was still live. `rolloutFiles`
    /// must walk both roots.
    func testRolloutFilesIncludeArchivedSessions() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("codex-reader-\(UUID().uuidString)")
        let live = base.appendingPathComponent("sessions/2026/07/02", isDirectory: true)
        let archived = base.appendingPathComponent("archived_sessions", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let liveFile = live.appendingPathComponent("rollout-2026-07-02T21-00-00-aaaa.jsonl")
        let archivedFile = archived.appendingPathComponent("rollout-2026-07-02T18-00-00-bbbb.jsonl")
        try "{}".write(to: liveFile, atomically: true, encoding: .utf8)
        try "{}".write(to: archivedFile, atomically: true, encoding: .utf8)

        let roots = [base.appendingPathComponent("sessions"), archived]
        let names = CodexRolloutReader.rolloutFiles(in: roots).map(\.lastPathComponent)

        XCTAssertTrue(names.contains("rollout-2026-07-02T18-00-00-bbbb.jsonl"),
                      "archived session must be counted")
        XCTAssertTrue(names.contains("rollout-2026-07-02T21-00-00-aaaa.jsonl"),
                      "live session must be counted")
    }

    /// A session momentarily present in both roots during an archive move must
    /// not be double-counted, or the day would briefly show inflated tokens.
    func testRolloutFilesDedupeSameNameAcrossRoots() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("codex-reader-\(UUID().uuidString)")
        let live = base.appendingPathComponent("sessions", isDirectory: true)
        let archived = base.appendingPathComponent("archived_sessions", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let name = "rollout-2026-07-02T18-00-00-bbbb.jsonl"
        try "{}".write(to: live.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try "{}".write(to: archived.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let files = CodexRolloutReader.rolloutFiles(in: [live, archived])
        XCTAssertEqual(files.filter { $0.lastPathComponent == name }.count, 1,
                       "same rollout name across roots must be deduped")
    }

    /// The production roots must include the archived directory.
    func testSessionRootsIncludeArchived() {
        let names = CodexRolloutReader.sessionRoots.map(\.lastPathComponent)
        XCTAssertTrue(names.contains("sessions"))
        XCTAssertTrue(names.contains("archived_sessions"))
    }
}
