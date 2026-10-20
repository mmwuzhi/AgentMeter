import Darwin
import Foundation

/// Small POSIX file helpers for state files AgentMeter owns: an atomic
/// replace that never exposes the file with looser permissions than asked
/// (`Data.write(options: .atomic)` creates it with the umask's and leaves the
/// tightening to a second call), and an append that reports how the file
/// looked when it wrote.
enum AtomicFile {
    struct Identity: Hashable, Sendable {
        let device: Int64
        let inode: UInt64

        init(_ status: stat) {
            device = Int64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    struct Failure: Error, Equatable {
        let operation: String
        let code: Int32

        /// Content-free, for logs: never a path.
        var logReason: String { "\(operation) errno \(code)" }
    }

    /// Writes `data` to a temporary file next to `url`, created with
    /// `permissions`, flushes it, and renames it over `url`: a reader sees
    /// the old file or the new one, never a mix.
    static func replace(_ url: URL, with data: Data, permissions: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw Failure(operation: "open", code: errno) }
        var renamed = false
        defer {
            if !renamed { unlink(temporary.path) }
        }
        do {
            defer { close(fd) }
            try writeAll(fd, data)
            guard fsync(fd) == 0 else { throw Failure(operation: "fsync", code: errno) }
        }
        guard rename(temporary.path, url.path) == 0 else { throw Failure(operation: "rename", code: errno) }
        renamed = true
    }

    struct Appended {
        /// The file appended to.
        let identity: Identity
        /// Its length before this write.
        let lengthBefore: UInt64
        /// Bytes this call wrote, including a newline it put in front.
        let written: UInt64
    }

    /// Appends `data`, creating the file with `permissions` if needed. When
    /// `startOnNewLine` and the file does not end in a newline (a writer died
    /// mid-line), writes one first so `data` does not join the torn line.
    static func append(_ data: Data, to url: URL, startOnNewLine: Bool, permissions: mode_t = 0o600) throws -> Appended {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw Failure(operation: "open", code: errno) }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw Failure(operation: "fstat", code: errno) }
        var payload = data
        if startOnNewLine, status.st_size > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, status.st_size - 1) == 1, last != 0x0A {
                payload.insert(0x0A, at: payload.startIndex)
            }
        }
        try writeAll(fd, payload)
        return Appended(identity: Identity(status), lengthBefore: UInt64(status.st_size), written: UInt64(payload.count))
    }

    /// The file at `url` from byte `offset` on, with its identity and full
    /// length; nil when there is no file.
    static func read(_ url: URL, from offset: UInt64 = 0) throws -> (identity: Identity, length: UInt64, data: Data)? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure(operation: "open", code: errno)
        }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw Failure(operation: "fstat", code: errno) }
        let length = UInt64(max(0, status.st_size))
        guard length > offset else { return (Identity(status), length, Data()) }
        var data = Data(count: Int(length - offset))
        var filled = 0
        while filled < data.count {
            let n = data.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + filled, buffer.count - filled, off_t(offset) + off_t(filled))
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else {
                if n < 0 { throw Failure(operation: "read", code: errno) }
                break
            }
            filled += n
        }
        data.removeSubrange(filled...)
        return (Identity(status), length, data)
    }

    /// Identity and length of the file at `url`, without opening it.
    static func status(_ url: URL) -> (identity: Identity, length: UInt64)? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return (Identity(status), UInt64(max(0, status.st_size)))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw Failure(operation: "write", code: errno) }
            offset += n
        }
    }
}
