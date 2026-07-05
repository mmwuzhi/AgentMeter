import Foundation

enum JSONLLineReader {
    static func forEachLine(in url: URL, _ body: (String) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            try drainCompleteLines(from: &buffer, body)
        }

        if !buffer.isEmpty, let line = String(data: trimmedCarriageReturn(buffer), encoding: .utf8) {
            try autoreleasepool {
                try body(line)
            }
        }
    }

    private static func drainCompleteLines(
        from buffer: inout Data,
        _ body: (String) throws -> Void
    ) throws {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = trimmedCarriageReturn(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8) else { continue }
            try autoreleasepool {
                try body(line)
            }
        }
    }

    private static func trimmedCarriageReturn(_ data: Data) -> Data {
        guard data.last == 0x0D else { return data }
        return data.dropLast()
    }
}
