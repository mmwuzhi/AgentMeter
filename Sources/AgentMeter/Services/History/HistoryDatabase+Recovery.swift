import Foundation
import SQLite3

extension HistoryDatabase {
    static let sidecarSuffixes = ["", "-wal", "-shm", "-journal"]

    /// Moves `history.sqlite`, `-wal`, `-shm` and `-journal` TOGETHER to
    /// `history.corrupt-<yyyyMMdd'T'HHmmss'Z'>[-<n>].sqlite[-wal|-shm|-journal]`
    /// and keeps the newest `maxQuarantined`. `<n>` is one more than the
    /// highest sequence number of any quarantined file present (none for the
    /// first): the retention orders by it, never by the stamp. Moving together
    /// matters: the dangerous combination is an older main file next to a
    /// newer `-wal`. Falls back to deleting only when the rename fails, and
    /// gives up with `.unrecoverable` if even that does.
    @discardableResult
    static func quarantine(_ config: HistoryDatabaseConfiguration) throws -> URL? {
        let fm = FileManager.default
        let url = config.url
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        // For a human reading the directory only: the wall clock can be set
        // back (or have run ahead), so the stamp says nothing about order.
        let stamp = formatter.string(from: config.clock())

        // The sequence continues from the highest number present, whatever its
        // stamp: the new file is then the newest in the retention order even
        // after the clock went back, and a name freed by pruning is never reused.
        let prefix = "\(stem).corrupt-"
        let highest = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(ext) }
            .map { quarantineKey($0, prefix: prefix, ext: ext).counter }
            .max()
        var counter = highest.map { $0 + 1 } ?? 0
        func candidate() -> URL {
            dir.appendingPathComponent("\(stem).corrupt-\(stamp)\(counter == 0 ? "" : "-\(counter)")\(ext)")
        }
        while fm.fileExists(atPath: candidate().path) { counter += 1 }
        let dest = candidate()
        var movedMain: URL?
        for suffix in sidecarSuffixes {
            let src = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: dest.path + suffix)
            do {
                try fm.moveItem(at: src, to: dst)
                if suffix.isEmpty { movedMain = dst }
            } catch {
                // Could not move (permissions?): delete, so the fresh database does not inherit it.
                do { try fm.removeItem(at: src) } catch {
                    throw HistoryStoreError.unrecoverable(SQLiteError(
                        code: SQLITE_CANTOPEN, message: "cannot quarantine \(src.lastPathComponent): \(error)", context: "quarantine"))
                }
            }
        }
        prune(dir: dir, stem: stem, ext: ext, keep: config.maxQuarantined, sparing: dest.lastPathComponent)
        return movedMain
    }

    /// Deletes all but the newest `keep` quarantined databases and their
    /// sidecars, newest by sequence number. `sparing` (the file the caller has
    /// just moved aside, the one `.rebuilt` points at) is never deleted and
    /// counts as one of the `keep`.
    static func prune(dir: URL, stem: String, ext: String, keep: Int, sparing: String? = nil) {
        let fm = FileManager.default
        let prefix = "\(stem).corrupt-"
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(ext) }
            .sorted {
                let a = quarantineKey($0, prefix: prefix, ext: ext), b = quarantineKey($1, prefix: prefix, ext: ext)
                return (a.counter, a.stamp) < (b.counter, b.stamp)
            }
        let spared = sparing.map(names.contains) ?? false
        let others = names.filter { $0 != sparing }
        for old in others.dropLast(max(keep - (spared ? 1 : 0), 0)) {
            for suffix in sidecarSuffixes { try? fm.removeItem(atPath: dir.appendingPathComponent(old).path + suffix) }
        }
    }

    /// The UTC stamp and the sequence number of a quarantined file name
    /// (`history.corrupt-<stamp>[-<n>].sqlite`; no suffix = 0). A plain string
    /// sort would put `...Z-1.sqlite` before `...Z.sqlite` (`-` sorts below
    /// `.`) although it is the newer one.
    private static func quarantineKey(_ name: String, prefix: String, ext: String) -> (stamp: String, counter: Int) {
        let body = String(name.dropFirst(prefix.count).dropLast(ext.count))
        let parts = body.split(separator: "-", maxSplits: 1)
        return (parts.first.map(String.init) ?? body, parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    }
}

/// Advisory `flock` on a sidecar file, held for the life of the database. The
/// kernel releases it when the descriptor closes or the process dies, so there
/// is no stale-lock cleanup, and the file is left on disk on purpose.
///
/// It is advisory: a process that ignores it can still open the SQLite file
/// (readers may; the lock exists to protect quarantine and migration, which
/// only the holder may do).
final class HistoryProcessLock {
    private let fd: Int32

    init(path: String) throws {
        var f: Int32
        repeat { f = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) } while f < 0 && errno == EINTR
        guard f >= 0 else { throw Self.failure(.lockFile, errno: errno) }
        var rc: Int32
        repeat { rc = flock(f, LOCK_EX | LOCK_NB) } while rc != 0 && errno == EINTR
        if rc != 0 {
            let code = errno        // before close(), which may overwrite it
            close(f)
            throw Self.failure(.flock, errno: code)
        }
        fd = f
    }

    /// Only `flock`'s EWOULDBLOCK means another holder. Everything else (no
    /// space or descriptors, no permission, a volume without `flock`) is
    /// `.lockUnavailable` with the errno, so the status names the real cause
    /// and the store retries it instead of claiming a second instance or
    /// latching for good.
    static func failure(_ step: HistoryLockStep, errno code: Int32) -> HistoryStoreError {
        if step == .flock && (code == EWOULDBLOCK || code == EAGAIN) { return .lockedByAnotherInstance }
        return .lockUnavailable(step: step, errno: code)
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
