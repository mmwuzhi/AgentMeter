import Foundation
import Security

/// Obtains the Claude Code OAuth access token, plaintext file first (no prompt),
/// then macOS Keychain (`Claude Code-credentials`, one-time access prompt).
enum ClaudeCredentials {
    struct Token: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt.addingTimeInterval(-60)
        }
    }

    static let keychainService = "Claude Code-credentials"

    /// In-process token cache. On macOS the token usually lives only in the
    /// Keychain (no `~/.claude/.credentials.json`), so an uncached read hits the
    /// Keychain. Whenever Claude Code rotates its OAuth token it rewrites the
    /// Keychain item, which invalidates any prior one-time "Allow" grant and
    /// makes the next read re-prompt. Reusing a loaded token until it nears
    /// expiry keeps us off the Keychain between rotations (was: one read per
    /// 60s refresh, ~1440/day).
    private actor Cache {
        private var token: Token?
        /// Returns the cached token only while it is still comfortably valid.
        func valid() -> Token? {
            guard let token, !token.isExpired else { return nil }
            return token
        }
        func store(_ token: Token?) { self.token = token }
        func clear() { token = nil }
    }
    private static let cache = Cache()

    /// Returns a still-valid cached token, otherwise reads from disk/Keychain
    /// and caches the result.
    static func load() async -> Token? {
        if let cached = await cache.valid() { return cached }
        let fresh = loadUncached()
        await cache.store(fresh)
        return fresh
    }

    /// Drops the cached token so the next `load()` re-reads from disk/Keychain.
    /// Call this when the token is rejected (auth failure) to recover before its
    /// nominal expiry.
    static func invalidate() async {
        await cache.clear()
    }

    private static func loadUncached() -> Token? {
        if let t = loadFromFile() { return t }
        return loadFromKeychain()
    }

    // MARK: - Plaintext file

    private static var credentialsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    private static func loadFromFile() -> Token? {
        guard let data = try? Data(contentsOf: credentialsFileURL) else { return nil }
        return parse(data)
    }

    // MARK: - Keychain

    private static func loadFromKeychain() -> Token? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return parse(data)
    }

    // MARK: - Parse

    /// Shape: { "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt" (ms epoch) } }
    private static func parse(_ data: Data) -> Token? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000.0)
        }
        return Token(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }
}
