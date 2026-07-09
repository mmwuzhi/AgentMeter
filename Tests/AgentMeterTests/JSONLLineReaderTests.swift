import Foundation
@testable import AgentMeter
import XCTest

final class JSONLLineReaderTests: XCTestCase {
    func testReadsNewlineDelimitedFileWithoutLoadingWholeFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-reader-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try "one\ntwo\r\nthree".write(to: url, atomically: true, encoding: .utf8)

        var lines: [String] = []
        try JSONLLineReader.forEachLine(in: url) { line in
            lines.append(line)
        }

        XCTAssertEqual(lines, ["one", "two", "three"])
    }

    func testForEachCompleteLineDeliversOnlyTerminatedLinesAndReportsTrailing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-complete-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // "a\nb\nc" — five bytes; "c" has no terminating newline.
        try "a\nb\nc".write(to: url, atomically: true, encoding: .utf8)

        var lines: [String] = []
        let result = try JSONLLineReader.forEachCompleteLine(in: url, fromOffset: 0) { lines.append($0) }

        XCTAssertEqual(lines, ["a", "b"], "trailing partial must not be delivered to body")
        XCTAssertEqual(result.consumed, 4, "resume offset must sit just after the last newline")
        XCTAssertEqual(result.trailing, "c", "the unterminated tail must be reported, not swallowed")
    }

    func testForEachCompleteLineResumesFromOffsetWithoutRereading() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-resume-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
        let first = try JSONLLineReader.forEachCompleteLine(in: url, fromOffset: 0) { _ in }
        XCTAssertEqual(first.consumed, 4)

        // Append and resume from the previous boundary: only the new line is seen.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("c\nd\n".utf8))
        try handle.close()

        var lines: [String] = []
        let result = try JSONLLineReader.forEachCompleteLine(in: url, fromOffset: first.consumed) { lines.append($0) }
        XCTAssertEqual(lines, ["c", "d"], "resume must not re-read already-consumed lines")
        XCTAssertEqual(result.consumed, 8)
        XCTAssertNil(result.trailing)
    }
}
