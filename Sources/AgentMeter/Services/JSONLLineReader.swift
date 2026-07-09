import Foundation

enum JSONLLineReader {
    /// Reads every line, including a trailing line with no final newline. Used by
    /// one-shot readers (quota, active-agent session parsing) that always start at
    /// the top of the file.
    static func forEachLine(in url: URL, _ body: (String) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            _ = try drainCompleteLines(from: &buffer, body)
        }

        if !buffer.isEmpty, let line = String(data: trimmedCarriageReturn(buffer), encoding: .utf8) {
            try autoreleasepool {
                try body(line)
            }
        }
    }

    struct IncrementalResult {
        /// Absolute byte offset immediately after the last newline consumed — the
        /// safe resume point for the next incremental pass. Always a line boundary,
        /// never mid-record.
        let consumed: Int64
        /// Bytes after the last newline (a record not yet terminated), if any. The
        /// caller may fold this into the value it shows now, but must NOT cache it:
        /// the next pass re-reads it from `consumed` once it's complete, so caching
        /// it would double-count (or, for a torn read, prevent self-healing).
        let trailing: String?
    }

    /// Reads from `fromOffset` to EOF, delivering only newline-terminated lines to
    /// `body`, and returns the resume offset plus any trailing partial line.
    static func forEachCompleteLine(
        in url: URL,
        fromOffset: Int64,
        _ body: (String) throws -> Void
    ) throws -> IncrementalResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if fromOffset > 0 {
            try handle.seek(toOffset: UInt64(fromOffset))
        }

        var consumed = fromOffset
        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            consumed += Int64(try drainCompleteLines(from: &buffer, body))
        }
        let trailing = buffer.isEmpty ? nil : String(data: trimmedCarriageReturn(buffer), encoding: .utf8)
        return IncrementalResult(consumed: consumed, trailing: trailing)
    }

    /// Delivers each newline-terminated line in `buffer` and drops them from the
    /// front in a single `removeSubrange`, returning the byte count consumed.
    /// Advancing a cursor (rather than removing per line) keeps this O(n) per
    /// chunk instead of O(n²) from repeated front-shifting.
    @discardableResult
    private static func drainCompleteLines(
        from buffer: inout Data,
        _ body: (String) throws -> Void
    ) throws -> Int {
        var lineStart = buffer.startIndex
        var searchStart = lineStart
        while let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
            let lineData = trimmedCarriageReturn(buffer.subdata(in: lineStart..<newline))
            if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                try autoreleasepool {
                    try body(line)
                }
            }
            lineStart = buffer.index(after: newline)
            searchStart = lineStart
        }
        let consumed = lineStart - buffer.startIndex
        if consumed > 0 {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
        return consumed
    }

    private static func trimmedCarriageReturn(_ data: Data) -> Data {
        guard data.last == 0x0D else { return data }
        return data.dropLast()
    }
}
