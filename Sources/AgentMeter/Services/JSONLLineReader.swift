import Foundation

enum JSONLLineReader {
    private static let chunkSize = 64 * 1024

    // Each read is wrapped in its own `autoreleasepool`: `FileHandle.read` hands
    // back an autoreleased `NSData`, and a Swift-concurrency cooperative thread
    // drains no pool mid-task, so without one every chunk of the file stays live
    // until the whole scan returns — a 1.2 GB log then costs 1.2 GB of footprint
    // to read 64 KB at a time.

    /// One JSONL record, still as raw bytes, valid only for the duration of the
    /// call that delivers it.
    ///
    /// Both steps a scanner performs per line used to route through `String`:
    /// `String(data:encoding:)` validated every byte of the corpus, and
    /// `String.contains` resolved to Foundation's locale-aware `range(of:)`,
    /// which materializes a `Substring` per candidate position. On a multi-GB
    /// log corpus those two cost roughly 25x the JSON parse they exist to avoid.
    struct LogLine {
        let bytes: UnsafeRawBufferPointer

        var isEmpty: Bool { bytes.isEmpty }

        /// Byte-wise substring search — no Unicode normalization, which is what
        /// an ASCII JSON key wants anyway.
        func contains(_ marker: Marker) -> Bool {
            guard !marker.bytes.isEmpty,
                  let base = bytes.baseAddress,
                  bytes.count >= marker.bytes.count else { return false }
            return marker.bytes.withUnsafeBufferPointer { needle in
                memmem(base, bytes.count, needle.baseAddress, needle.count)
            } != nil
        }

        /// `contains` over the first `limit` bytes only: for a key that,
        /// when present, sits near the start of its record, so a miss costs
        /// a few hundred bytes instead of the whole line.
        func contains(_ marker: Marker, withinFirst limit: Int) -> Bool {
            let span = min(bytes.count, limit)
            guard !marker.bytes.isEmpty, let base = bytes.baseAddress, span >= marker.bytes.count else { return false }
            return marker.bytes.withUnsafeBufferPointer { needle in
                memmem(base, span, needle.baseAddress, needle.count)
            } != nil
        }

        /// Whether the record starts with `marker`'s bytes: O(1) in the line.
        func hasPrefix(_ marker: Marker) -> Bool {
            guard !marker.bytes.isEmpty, let base = bytes.baseAddress, bytes.count >= marker.bytes.count else { return false }
            return marker.bytes.withUnsafeBufferPointer { memcmp(base, $0.baseAddress!, $0.count) == 0 }
        }

        /// Parses the record without building an intermediate `String`.
        func jsonObject() -> [String: Any]? {
            guard !bytes.isEmpty,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(bytes)) else { return nil }
            return parsed as? [String: Any]
        }

        /// Text of the record, for callers that need it. Nil on invalid UTF-8,
        /// matching what the previous String-based reader silently skipped.
        var string: String? { String(data: Data(bytes), encoding: .utf8) }
    }

    /// A UTF-8 needle for `LogLine.contains`. Build these once as static
    /// constants; rebuilding one per line would give the cost right back.
    struct Marker {
        let bytes: [UInt8]

        init(_ text: String) {
            bytes = Array(text.utf8)
        }
    }

    /// Reads every line, including a trailing line with no final newline. Used by
    /// one-shot readers (quota, active-agent session parsing) that always start at
    /// the top of the file.
    static func forEachLine(in url: URL, _ body: (LogLine) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var splitter = LineSplitter()
        var atEOF = false
        while !atEOF {
            try autoreleasepool {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { atEOF = true; return }
                splitter.append(chunk)
                _ = try splitter.drain(body)
            }
        }
        try splitter.withTrailing(body)
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
        /// Owned, unlike a `LogLine`, because it outlives the read.
        let trailing: Data?
    }

    /// Reads from `fromOffset` to EOF — or to `limit` when given, so a reader
    /// that fingerprinted the file first sees exactly the bytes it
    /// fingerprinted even if the file grows meanwhile — delivering only
    /// newline-terminated lines to `body`, and returns the resume offset plus
    /// any trailing partial line.
    static func forEachCompleteLine(
        in url: URL,
        fromOffset: Int64,
        upTo limit: Int64? = nil,
        _ body: (LogLine) throws -> Void
    ) throws -> IncrementalResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if fromOffset > 0 {
            try handle.seek(toOffset: UInt64(fromOffset))
        }

        var consumed = fromOffset
        var position = fromOffset
        var splitter = LineSplitter()
        var atEOF = false
        while !atEOF {
            try autoreleasepool {
                var want = chunkSize
                if let limit {
                    guard position < limit else { atEOF = true; return }
                    want = Int(min(Int64(chunkSize), limit - position))
                }
                let chunk = try handle.read(upToCount: want) ?? Data()
                if chunk.isEmpty { atEOF = true; return }
                position += Int64(chunk.count)
                splitter.append(chunk)
                consumed += Int64(try splitter.drain(body))
            }
        }
        return IncrementalResult(consumed: consumed, trailing: splitter.trailingBytes())
    }

    /// Views an owned record (typically `IncrementalResult.trailing`) as a
    /// `LogLine`, so a caller has one parsing path for both.
    static func withLine<R>(_ data: Data, _ body: (LogLine) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { try body(LogLine(bytes: $0)) }
    }

    /// Accumulates chunks and hands out newline-terminated records.
    private struct LineSplitter {
        private var buffer: [UInt8] = []
        /// Bytes at the front of `buffer` already searched for a newline and
        /// found not to contain one. Carried across chunks: without it a record
        /// larger than one chunk is re-scanned from the front for every chunk
        /// appended to it, which is quadratic in the record's size — and these
        /// logs contain single records of several megabytes.
        private var searched = 0

        mutating func append(_ chunk: Data) {
            buffer.append(contentsOf: chunk)
        }

        /// Delivers each newline-terminated line, drops them from the front in a
        /// single `removeFirst`, and returns the byte count consumed.
        mutating func drain(_ body: (LogLine) throws -> Void) throws -> Int {
            var lineStart = 0
            var cursor = searched
            while let newline = Self.indexOfNewline(in: buffer, from: cursor) {
                try Self.deliver(buffer, from: lineStart, to: newline, into: body)
                lineStart = newline + 1
                cursor = lineStart
            }
            searched = buffer.count - lineStart
            if lineStart > 0 {
                buffer.removeFirst(lineStart)
            }
            return lineStart
        }

        /// Delivers the unterminated tail, if any.
        func withTrailing(_ body: (LogLine) throws -> Void) throws {
            try Self.deliver(buffer, from: 0, to: buffer.count, into: body)
        }

        /// Bytes after the last newline, as an owned copy.
        func trailingBytes() -> Data? {
            let end = Self.trimmedEnd(buffer, from: 0, to: buffer.count)
            guard end > 0 else { return nil }
            return Data(buffer[0..<end])
        }

        private static func indexOfNewline(in buffer: [UInt8], from: Int) -> Int? {
            guard from < buffer.count else { return nil }
            return buffer.withUnsafeBufferPointer { buf -> Int? in
                guard let base = buf.baseAddress,
                      let hit = memchr(base + from, 0x0A, buf.count - from) else { return nil }
                return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            }
        }

        private static func trimmedEnd(_ buffer: [UInt8], from: Int, to end: Int) -> Int {
            guard end > from, buffer[end - 1] == 0x0D else { return end }
            return end - 1
        }

        private static func deliver(
            _ buffer: [UInt8],
            from start: Int,
            to end: Int,
            into body: (LogLine) throws -> Void
        ) throws {
            let stop = trimmedEnd(buffer, from: start, to: end)
            guard stop > start else { return }
            try buffer.withUnsafeBytes { raw in
                try autoreleasepool {
                    try body(LogLine(bytes: UnsafeRawBufferPointer(rebasing: raw[start..<stop])))
                }
            }
        }
    }
}
