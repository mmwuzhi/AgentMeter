import Darwin
import Foundation

/// Reads the end of a Claude transcript to see whether its last turn was
/// interrupted. Claude Code writes the marker as a user message
/// (`[Request interrupted by user]`, or `… for tool use]` when a tool was
/// running) and then keeps appending bookkeeping records (`cost-state`,
/// `last-prompt`, `file-history-snapshot`, …; C3), so the answer is the last
/// user or assistant message, not the last line. Only the verdict leaves this
/// type; no text is kept or logged.
enum TranscriptTailClassifier {
    static let tailBytes = 64 * 1024
    static let marker = "[Request interrupted by user"

    static func verdict(atPath path: String?) -> TaskTranscriptVerdict {
        guard let path, path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return .unavailable }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return .unavailable }
        let length = Int64(status.st_size)
        let offset = max(0, length - Int64(tailBytes))
        var data = Data(count: Int(length - offset))
        let read = data.withUnsafeMutableBytes { buffer in
            pread(fd, buffer.baseAddress, buffer.count, off_t(offset))
        }
        guard read >= 0 else { return .unavailable }
        data.removeSubrange(read...)
        return verdict(tail: data, startsMidFile: offset > 0)
    }

    /// `tail` is the file's last bytes; when it starts mid-file its first
    /// line is partial and skipped.
    static func verdict(tail: Data, startsMidFile: Bool) -> TaskTranscriptVerdict {
        var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidFile, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true
            else { continue }
            guard type == "user" else { return .other }
            return isMarker(object["message"]) ? .interrupted : .other
        }
        return .other
    }

    private static func isMarker(_ message: Any?) -> Bool {
        guard let message = message as? [String: Any] else { return false }
        if let text = message["content"] as? String { return text.hasPrefix(marker) }
        guard let parts = message["content"] as? [[String: Any]] else { return false }
        return parts.contains { part in
            part["type"] as? String == "text" && (part["text"] as? String)?.hasPrefix(marker) == true
        }
    }
}
