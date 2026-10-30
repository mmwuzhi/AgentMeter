import Darwin
import Foundation

/// `~/.claude/settings.json` as AgentMeter reads and rewrites it for its hooks.
///
/// The path may be a symbolic link into a dotfiles checkout. It was one on the
/// developer's Mac until a 2026-07-13 hook install wrote a plain file over the
/// link, and the dotfile silently stopped applying. Every write now goes to
/// the regular file the link leads to, replaced atomically inside that file's
/// own directory, so the link stays a link. A link that leads nowhere, loops,
/// or leads to anything but a regular file is refused, never overwritten, and
/// so is a file AgentMeter could not replace without splitting hard links or
/// against its permissions.
///
/// The bytes a write replaces are kept in AgentMeter's own support directory
/// (`backupDirectory`), never next to the settings file where they would
/// litter a dotfiles repository: a new copy only when they differ from the
/// newest one, and only the newest `backupsKept`.
struct ClaudeSettingsFile {
    struct Document {
        let root: [String: Any]
        /// What was read; nil when there was no file yet.
        let originalData: Data?
    }

    enum Failure: LocalizedError, Equatable {
        case invalidJSON
        case changedMeanwhile
        case danglingLink(destination: String)
        case linkLoop
        case notARegularFile
        case multipleHardLinks
        case notWritable(path: String)
        case writeFailed(path: String, reason: String)
        case backupFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "the existing Claude settings file is not valid JSON"
            case .changedMeanwhile:
                return "Claude settings changed while AgentMeter was updating them; try again"
            case .danglingLink(let destination):
                return "~/.claude/settings.json links to \(destination), which doesn't exist; fix the link first"
            case .linkLoop:
                return "~/.claude/settings.json is a symbolic link that loops back on itself"
            case .notARegularFile:
                return "~/.claude/settings.json doesn't lead to a regular file"
            case .multipleHardLinks:
                return "~/.claude/settings.json has other hard links, which replacing it would break"
            case .notWritable(let path):
                return "AgentMeter can't write \(Self.abbreviated(path))"
            case .writeFailed(let path, let reason):
                return "writing \(Self.abbreviated(path)) failed: \(reason)"
            case .backupFailed(let reason):
                return "AgentMeter couldn't back up the settings file first: \(reason)"
            }
        }

        private static func abbreviated(_ path: String) -> String {
            (path as NSString).abbreviatingWithTildeInPath
        }
    }

    static let backupPrefix = "settings.json."

    let url: URL
    let backupDirectory: URL
    var backupsKept = 5

    func read() throws -> Document {
        guard let target = try existingTarget() else {
            return Document(root: [:], originalData: nil)
        }
        let data = try Data(contentsOf: target)
        guard !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.invalidJSON
        }
        return Document(root: root, originalData: data)
    }

    func write(_ root: [String: Any], replacing document: Document) throws {
        let fileManager = FileManager.default
        let target = try existingTarget()
        // Claude Code writes this file too; never write over a change made
        // after it was read.
        if let originalData = document.originalData {
            guard let target, (try? Data(contentsOf: target)) == originalData else {
                throw Failure.changedMeanwhile
            }
        } else if target != nil {
            throw Failure.changedMeanwhile
        }

        let destination = target ?? url
        let directory = destination.deletingLastPathComponent()
        if target == nil {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw Failure.writeFailed(path: directory.path, reason: error.localizedDescription)
            }
        }
        // The replacement is renamed into the target's directory, so both
        // must be writable; a read-only settings file is the user's choice.
        guard access(directory.path, W_OK) == 0 else { throw Failure.notWritable(path: directory.path) }
        if target != nil, access(destination.path, W_OK) != 0 {
            throw Failure.notWritable(path: destination.path)
        }

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if let originalData = document.originalData {
            try backUp(originalData)
        }

        do {
            // Into the target's own directory, so the rename never touches a link.
            try AtomicFile.replace(destination, with: data, permissions: 0o600, metadataFrom: target)
        } catch let failure as AtomicFile.Failure {
            throw Failure.writeFailed(path: destination.path,
                                      reason: "\(failure.operation): \(String(cString: strerror(failure.code)))")
        }
    }

    /// The regular file a read or write must use: `url` itself, or what its
    /// symbolic links lead to. Nil when nothing is there yet.
    func existingTarget() throws -> URL? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.writeFailed(path: url.path, reason: String(cString: strerror(errno)))
        }
        var target = url
        if info.st_mode & S_IFMT == S_IFLNK {
            guard let resolved = realpath(url.path, nil) else {
                switch errno {
                case ELOOP: throw Failure.linkLoop
                case ENOENT, ENOTDIR: throw Failure.danglingLink(destination: linkDestination() ?? "?")
                default: throw Failure.writeFailed(path: url.path, reason: String(cString: strerror(errno)))
                }
            }
            target = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
            guard stat(target.path, &info) == 0 else {
                throw Failure.danglingLink(destination: linkDestination() ?? target.path)
            }
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notARegularFile }
        guard info.st_nlink <= 1 else { throw Failure.multipleHardLinks }
        return target
    }

    private func linkDestination() -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Keeps `data` unless the newest backup already holds it, then drops
    /// all but the newest `backupsKept`. Names sort by time.
    private func backUp(_ data: Data) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var backups = existingBackups()
            if let newest = backups.last, (try? Data(contentsOf: newest)) == data { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
            let name = Self.backupPrefix + formatter.string(from: Date())
                + "-" + UUID().uuidString.prefix(8) + ".json"
            let backup = backupDirectory.appendingPathComponent(name)
            try AtomicFile.replace(backup, with: data)
            backups.append(backup)
            for stale in backups.dropLast(max(backupsKept, 1)) {
                try? fileManager.removeItem(at: stale)
            }
        } catch let failure as AtomicFile.Failure {
            throw Failure.backupFailed(reason: "\(failure.operation): \(String(cString: strerror(failure.code)))")
        } catch {
            throw Failure.backupFailed(reason: error.localizedDescription)
        }
    }

    func existingBackups() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.backupPrefix) && $0.hasSuffix(".json") }
            .sorted()
            .map { backupDirectory.appendingPathComponent($0) }
    }
}
