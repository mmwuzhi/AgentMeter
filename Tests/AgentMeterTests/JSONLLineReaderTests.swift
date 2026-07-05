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
}
