import Foundation

/// Obtains the Codex CLI's OAuth access token + ChatGPT account id from the
/// plaintext `~/.codex/auth.json` that `codex login` writes and the CLI itself
/// keeps refreshed. Unlike Claude Code, the Codex CLI does not mirror this into
/// the macOS Keychain, so there is no Keychain fallback here.
enum CodexCredentials {
    struct Token: Sendable {
        let accessToken: String
        let accountID: String?
    }

    /// In-process cache so a 20-minute reset-credits refresh cycle doesn't reopen
    /// the file every time; `invalidate()` drops it after a 401 so the next call
    /// rereads in case the CLI rotated the token in the meantime.
    private actor Cache {
        private var token: Token?
        func get() -> Token? { token }
        func store(_ token: Token?) { self.token = token }
    }
    private static let cache = Cache()

    static func load() async -> Token? {
        if let cached = await cache.get() { return cached }
        let fresh = loadUncached()
        await cache.store(fresh)
        return fresh
    }

    static func invalidate() async {
        await cache.store(nil)
    }

    private static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    /// Shape: { "tokens": { "access_token", "account_id", ... }, ... }
    private static func loadUncached() -> Token? {
        guard let data = try? Data(contentsOf: authFileURL) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokens = (obj["tokens"] as? [String: Any]) ?? obj
        guard let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        let accountID = (tokens["account_id"] as? String) ?? (obj["account_id"] as? String)
        return Token(accessToken: access, accountID: accountID)
    }
}
