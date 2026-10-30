import Darwin
import Foundation

/// Opt-in dumps of a raw provider response, for confirming the field names of
/// an undocumented endpoint when a parse fails or a plan has no windows.
/// Nothing is written unless the `debugCaptureResponses` boolean is set in
/// UserDefaults (`defaults write com.shu.agentmeter debugCaptureResponses
/// -bool true`); the switch is read when a capture is attempted, never cached.
///
/// A capture is the response body only (never a request, header or
/// credential), run through `redact`, written to
/// `Application Support/AgentMeter/debug/<endpoint>.json`: the directory 0700,
/// the file 0600 from the moment it exists (`AtomicFile.replace`: a 0600
/// temporary file, renamed). One file per endpoint, overwritten, so the
/// directory holds at most three; one older than `retention` is deleted by
/// the next capture and at launch. Earlier builds wrote the same bodies
/// unredacted, by default, 0644, into the folder above; `cleanUpAtLaunch`
/// keeps those files (they may be evidence someone wants) but makes them
/// owner-only, whether capturing is on or not. Best effort throughout: a
/// failure is ignored.
///
/// Money amounts (`extra_usage`, credit counts) are kept: the capture exists
/// to read them. The opt-in, the permissions and the retention are what
/// protect them.
struct DebugCapture {
    enum Endpoint: String {
        case claudeOAuthUsage = "claude-oauth-usage"
        case claudeResetGrants = "claude-reset-grants"
        case codexResetCredits = "codex-reset-credits"

        var fileName: String { "\(rawValue).json" }
    }

    static let defaultsKey = "debugCaptureResponses"
    static let directoryName = "debug"
    static let retention: TimeInterval = 7 * 24 * 3600
    /// A legitimate payload is a few KB. A larger body (a misbehaving proxy)
    /// is not kept.
    static let maxBytes = 256 * 1024
    /// What earlier builds left in `Application Support/AgentMeter`. Exactly
    /// these names are tightened, nothing matched by pattern.
    static let legacyFileNames = [
        "debug-claude-oauth-usage.json",
        "debug-claude-reset-grants.json",
        "debug-codex-reset-credits.json",
    ]

    var defaults: UserDefaults = .standard
    var supportDirectory: URL = DebugCapture.defaultSupportDirectory
    var now: () -> Date = Date.init

    static var standard: DebugCapture { DebugCapture() }

    static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.defaultsKey) }
    var directory: URL { supportDirectory.appendingPathComponent(Self.directoryName, isDirectory: true) }

    /// Writes `body` redacted. False when capturing is off or nothing was written.
    @discardableResult
    func record(_ body: Any, as endpoint: Endpoint) -> Bool {
        guard isEnabled else { return false }
        let redacted = Self.redact(body)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              data.count <= Self.maxBytes,
              prepareDirectory() else { return false }
        Self.sweep(directory, now: now())
        return (try? AtomicFile.replace(directory.appendingPathComponent(endpoint.fileName), with: data)) != nil
    }

    /// For a body that was never decoded. A JSON object or array is kept as
    /// `record(_:as:)` keeps one; anything else (HTML from a proxy, an
    /// oversized body) leaves only its size, since text with no structure
    /// cannot be redacted by field.
    @discardableResult
    func record(responseBody data: Data, as endpoint: Endpoint) -> Bool {
        guard isEnabled else { return false }
        if data.count <= Self.maxBytes,
           let object = try? JSONSerialization.jsonObject(with: data),
           object is [String: Any] || object is [Any] {
            return record(object, as: endpoint)
        }
        return record(["note": "not a JSON object or array, body not kept", "bytes": data.count], as: endpoint)
    }

    /// Launch housekeeping. Drops captures past `retention` whatever the
    /// switch says, and makes what earlier builds left owner-only. Nothing an
    /// earlier build wrote is deleted without the user.
    func cleanUpAtLaunch() {
        Self.sweep(directory, now: now())
        Self.tightenLegacyFiles(in: supportDirectory)
    }

    /// Deletes the regular `.json` captures and `.tmp` leftovers of a crashed
    /// write in `directory` whose modification time is older than `maxAge`.
    /// Other files and anything that is not a plain file are left alone.
    static func sweep(_ directory: URL, now: Date, maxAge: TimeInterval = retention) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = now.addingTimeInterval(-maxAge).timeIntervalSince1970
        for name in names where name.hasSuffix(".json") || name.hasSuffix(".tmp") {
            let path = directory.appendingPathComponent(name).path
            var status = stat()
            guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
                  TimeInterval(status.st_mtimespec.tv_sec) < cutoff else { continue }
            unlink(path)
        }
    }

    /// Makes each legacy capture 0600 when it is safe to: opened without
    /// following a symbolic link (or blocking on a FIFO), and changed only
    /// when it is a regular file this user owns with no other hard link and
    /// any group or other permission bit. An ACL entry granting others
    /// access is left as it is; `~/Library` is 0700 anyway. Returns the
    /// names it changed.
    @discardableResult
    static func tightenLegacyFiles(in supportDirectory: URL) -> [String] {
        var tightened: [String] = []
        for name in legacyFileNames {
            let fd = open(supportDirectory.appendingPathComponent(name).path,
                          O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var status = stat()
            guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == getuid(), status.st_nlink == 1,
                  status.st_mode & 0o077 != 0 else { continue }
            if fchmod(fd, 0o600) == 0 { tightened.append(name) }
        }
        return tightened
    }

    private func prepareDirectory() -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            // A directory that already existed keeps the mode it had.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Redaction

    static let placeholder = "[redacted]"

    /// A copy of `value` with what could name the account or open it removed:
    /// - a field whose name says token, secret, password, authorization,
    ///   cookie, API key, credential or signature, or an email, phone, user
    ///   name or an account / organization / user / member / customer /
    ///   subscription / seat / tenant / workspace / team / device / owner id
    ///   or uuid, wherever it sits;
    /// - `id`, `name`, `display_name`, `handle` and `login` inside an object
    ///   named account, organization, user, member, owner, customer,
    ///   workspace, team, seat or subscription (the plan fields beside them
    ///   stay); `scope.model.display_name`, which the quota parse reads, is
    ///   not inside one;
    /// - in every string value: a bearer token, a JWT, an `sk-` / `pk-` /
    ///   `rk-` / `gh?_` key, an email address, a UUID, and any run of 40 or
    ///   more base64 / hex / URL-safe characters.
    /// A null stays null, so the shape is still readable. Field names,
    /// numbers, booleans and dates are kept.
    static func redact(_ value: Any, under ancestors: [String] = []) -> Any {
        switch value {
        case let object as [String: Any]:
            var copy: [String: Any] = [:]
            for (key, child) in object {
                if child is NSNull {
                    copy[key] = child
                } else if isSensitive(key: key, under: ancestors) {
                    copy[key] = placeholder
                } else {
                    copy[key] = redact(child, under: ancestors + [normalized(key)])
                }
            }
            return copy
        case let array as [Any]:
            return array.map { redact($0, under: ancestors) }
        case let text as String:
            return redactText(text)
        default:
            return value
        }
    }

    static func redactText(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in textPatterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    private static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }

    private static func isSensitive(key: String, under ancestors: [String]) -> Bool {
        let name = normalized(key)
        if secretFragments.contains(where: name.contains) || identityFragments.contains(where: name.contains) {
            return true
        }
        return identityLeaves.contains(name) && ancestors.contains(where: identityParents.contains)
    }

    private static let secretFragments = [
        "token", "secret", "password", "passwd", "authorization", "cookie",
        "apikey", "credential", "bearer", "privatekey", "signature",
    ]
    private static let identityFragments = [
        "email", "phone", "username", "fullname", "firstname", "lastname", "uuid",
        "accountid", "organizationid", "orgid", "userid", "memberid", "customerid",
        "subscriptionid", "seatid", "tenantid", "workspaceid", "teamid", "deviceid", "ownerid",
    ]
    private static let identityParents: Set<String> = [
        "account", "organization", "org", "user", "member", "owner", "customer",
        "workspace", "team", "seat", "subscription",
    ]
    private static let identityLeaves: Set<String> = ["id", "name", "displayname", "handle", "login"]

    /// ICU patterns, applied in order. The last has no lookahead on purpose:
    /// one scanning to the end of a long run of such characters would be
    /// quadratic on a 256 KB value.
    private static let textPatterns: [(String, String)] = [
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "[redacted-token]"),
        (#"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#, "[redacted-token]"),
        (#"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"#, "[redacted-token]"),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "[redacted-token]"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#, "[redacted-email]"),
        (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "[redacted-id]"),
        (#"[A-Za-z0-9_+/=.-]{40,}"#, "[redacted-opaque]"),
    ]
}
