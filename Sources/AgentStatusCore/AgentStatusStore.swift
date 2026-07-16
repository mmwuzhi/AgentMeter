import Foundation

public enum AgentStatusStore {
    public static let appSupportDirectoryName = "AgentMeter"
    public static let statusDirectoryName = "agent-status"
    private static let maximumRecordBytes = 64 * 1024

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(statusDirectoryName, isDirectory: true)
    }

    public static func fileURL(forSession sessionID: String) -> URL {
        directory.appendingPathComponent("\(sanitized(sessionID)).json", isDirectory: false)
    }

    @discardableResult
    public static func write(_ payload: AgentStatusPayload) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let normalized = AgentStatusPayload(
            state: payload.state,
            sessionID: String(payload.sessionID.prefix(256)),
            message: payload.message.map { String($0.prefix(512)) },
            cwd: payload.cwd.map { String($0.prefix(4096)) },
            processAncestry: payload.processAncestry.map { Array($0.prefix(32)) },
            updatedAt: payload.updatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        guard data.count <= maximumRecordBytes else { throw StoreError.recordTooLarge }

        let url = fileURL(forSession: normalized.sessionID)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public static func read(sessionID: String) -> AgentStatusPayload? {
        decode(at: fileURL(forSession: sessionID))
    }

    public static func readAll() -> [AgentStatusPayload] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? maximumRecordBytes + 1) <= maximumRecordBytes else { return nil }
            return decode(at: url)
        }
    }

    @discardableResult
    public static func remove(sessionID: String) -> Bool {
        let url = fileURL(forSession: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    public static func sweepStale(olderThan maxAge: TimeInterval, now: Date = Date()) {
        guard maxAge >= 0 else { return }
        for payload in readAll() where now.timeIntervalSince(payload.updatedAt) > maxAge {
            remove(sessionID: payload.sessionID)
        }
    }

    private static func decode(at url: URL) -> AgentStatusPayload? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? maximumRecordBytes + 1) <= maximumRecordBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentStatusPayload.self, from: data)
    }

    private static func sanitized(_ sessionID: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let cleaned = String(sessionID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "unknown" : String(cleaned.prefix(128))
    }

    public enum StoreError: Error {
        case recordTooLarge
    }
}
