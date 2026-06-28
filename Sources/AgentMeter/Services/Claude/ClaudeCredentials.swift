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

    static func load() -> Token? {
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
