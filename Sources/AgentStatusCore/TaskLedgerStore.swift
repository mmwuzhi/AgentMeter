import Darwin
import Foundation

/// The turn ledgers on disk: `agent-status/turns/<session>.json`, 0600 in a
/// 0700 directory, replaced atomically. Hook processes of one session can run
/// at once (a subagent's `PostToolUse` beside the main agent's `Stop`), so
/// every read-modify-write holds an exclusive `flock` on `turns/.lock`; a
/// write that cannot get it within `lockTimeout` is dropped rather than
/// stalling Claude Code's hook.
public enum TaskLedgerStore {
    public static let directoryName = "turns"
    public static let maximumRecordBytes = 64 * 1024
    static let lockFileName = ".lock"

    public static var directory: URL {
        AgentStatusStore.directory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func fileURL(forSession sessionID: String, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("\(AgentStatusStore.fileStem(forSession: sessionID)).json", isDirectory: false)
    }

    public enum StoreError: Error, Equatable {
        case lockUnavailable
        case lockFailed(Int32)
        case recordTooLarge
    }

    /// Applies `event` to the session's ledger under the lock. Returns the
    /// ledger written, or nil when the event changed nothing.
    @discardableResult
    public static func apply(
        _ event: TaskLedgerEvent,
        sessionID: String,
        in directory: URL = directory,
        lockTimeout: TimeInterval = 0.5
    ) throws -> TaskLedger? {
        let sessionID = String(sessionID.prefix(256))
        try prepare(directory)
        let lock = try acquireLock(in: directory, timeout: lockTimeout)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let url = fileURL(forSession: sessionID, in: directory)
        let existing = decode(at: url).flatMap { $0.sessionID == sessionID ? $0 : nil }
        guard var ledger = TaskLedgerReducer.apply(event, to: existing, sessionID: sessionID) else { return nil }
        var data = try encode(ledger)
        // Only the launch list grows; shed its oldest half until it fits.
        while data.count > maximumRecordBytes, !ledger.backgroundLaunches.isEmpty {
            ledger.backgroundLaunches.removeFirst(max(1, ledger.backgroundLaunches.count / 2))
            data = try encode(ledger)
        }
        guard data.count <= maximumRecordBytes else { throw StoreError.recordTooLarge }
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        return ledger
    }

    public static func read(sessionID: String, in directory: URL = directory) -> TaskLedger? {
        decode(at: fileURL(forSession: sessionID, in: directory))
    }

    /// Every readable ledger with its file's modification time. A file that
    /// cannot be read or decoded drops itself, not the listing.
    public static func readAll(in directory: URL = directory) -> [(ledger: TaskLedger, modifiedAt: Date)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? maximumRecordBytes + 1) <= maximumRecordBytes,
                  let ledger = decode(at: url) else { return nil }
            return (ledger, values.contentModificationDate ?? ledger.updatedAt)
        }
    }

    @discardableResult
    public static func remove(sessionID: String, in directory: URL = directory) -> Bool {
        (try? FileManager.default.removeItem(at: fileURL(forSession: sessionID, in: directory))) != nil
    }

    static func encode(_ ledger: TaskLedger) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ledger)
    }

    /// Nil for a missing, oversized or undecodable file, and for one written
    /// in a format newer than this build reads.
    static func decode(at url: URL) -> TaskLedger? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? maximumRecordBytes + 1) <= maximumRecordBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let ledger = try? decoder.decode(TaskLedger.self, from: data),
              ledger.version <= TaskLedger.formatVersion else { return nil }
        return ledger
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
    }

    private static func acquireLock(in directory: URL, timeout: TimeInterval) throws -> Int32 {
        let path = directory.appendingPathComponent(lockFileName, isDirectory: false).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.lockFailed(errno) }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK, Date() < deadline else {
                close(fd)
                throw code == EWOULDBLOCK ? StoreError.lockUnavailable : StoreError.lockFailed(code)
            }
            usleep(5_000)
        }
    }
}
