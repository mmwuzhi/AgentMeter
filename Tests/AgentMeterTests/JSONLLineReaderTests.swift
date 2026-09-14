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
            lines.append(line.string ?? "<invalid>")
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
        let result = try JSONLLineReader.forEachCompleteLine(in: url, fromOffset: 0) {
            lines.append($0.string ?? "<invalid>")
        }

        XCTAssertEqual(lines, ["a", "b"], "trailing partial must not be delivered to body")
        XCTAssertEqual(result.consumed, 4, "resume offset must sit just after the last newline")
        XCTAssertEqual(result.trailing.flatMap { String(data: $0, encoding: .utf8) }, "c",
                       "the unterminated tail must be reported, not swallowed")
    }

    /// A record can be several megabytes — far past the 64 KB read chunk — so
    /// the splitter must stitch it back together, and must not rescan the
    /// accumulated buffer from the front for every chunk it appends.
    func testDeliversARecordThatSpansManyReadChunks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-bigline-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let huge = String(repeating: "x", count: 5 * 64 * 1024 + 7)
        try "before\n\(huge)\nafter\n".write(to: url, atomically: true, encoding: .utf8)

        var lines: [String] = []
        try JSONLLineReader.forEachLine(in: url) { lines.append($0.string ?? "<invalid>") }

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "before")
        XCTAssertEqual(lines[1].count, huge.count)
        XCTAssertEqual(lines.last, "after")
    }

    func testMarkerMatchesOnRawBytesAndRejectsMisses() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-marker-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"message":{"usage":{"input_tokens":5}}}"# .appending("\n{\"other\":1}\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let marker = JSONLLineReader.Marker("\"usage\"")

        var hits = 0
        var parsedInput: Int?
        try JSONLLineReader.forEachLine(in: url) { line in
            guard line.contains(marker) else { return }
            hits += 1
            let message = line.jsonObject()?["message"] as? [String: Any]
            let usage = message?["usage"] as? [String: Any]
            parsedInput = usage?["input_tokens"] as? Int
        }

        XCTAssertEqual(hits, 1, "the non-usage record must be filtered out by the byte search")
        XCTAssertEqual(parsedInput, 5)
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
        let result = try JSONLLineReader.forEachCompleteLine(in: url, fromOffset: first.consumed) {
            lines.append($0.string ?? "<invalid>")
        }
        XCTAssertEqual(lines, ["c", "d"], "resume must not re-read already-consumed lines")
        XCTAssertEqual(result.consumed, 8)
        XCTAssertNil(result.trailing)
    }
}
