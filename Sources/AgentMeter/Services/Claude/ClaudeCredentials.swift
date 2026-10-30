import Foundation
import os
import Security

/// Obtains the Claude Code OAuth access token, plaintext file first, then the
/// macOS Keychain item `Claude Code-credentials` through `/usr/bin/security`
/// (`KeychainToolReader`), which reads it without a prompt.
enum ClaudeCredentials {
    struct Token: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        /// Plan Claude Code recorded at login: "pro", "max", "team", or
        /// "enterprise", lowercased. `/api/oauth/usage` carries no plan key, so
        /// this is the authoritative value for the plan badge. Nil when the
        /// credential omits it or the value is not fit to display
        /// (`PlanLabel`).
        var subscriptionType: String? = nil
        /// Claude Code's rate-limit tier for this login, e.g.
        /// `default_claude_max_5x` / `default_claude_max_20x`. Together with
        /// `subscriptionType` it is how Claude Code itself tells a Team premium
        /// seat apart: nothing in the credential spells "premium". Nil when the
        /// credential omits it or the value fails `rateLimitTierPattern`.
        var rateLimitTier: String? = nil

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt.addingTimeInterval(-60)
        }
    }

    static let keychainService = "Claude Code-credentials"

    /// In-process token cache. On macOS the token usually lives only in the
    /// Keychain (no `~/.claude/.credentials.json`), so an uncached read hits the
    /// Keychain. Reusing a loaded token until it nears expiry keeps us off the
    /// Keychain between rotations (was: one read per 60s refresh, ~1440/day);
    /// it also spared prompts while reads went through the Security API.
    private actor Cache {
        private var token: Token?
        private var loading: Task<Token?, Never>?

        /// Coalesces cache misses so overlapping refreshes cannot queue several
        /// Keychain prompts while the user is responding to the first one.
        func load(using loader: @escaping @Sendable () -> Token?) async -> Token? {
            if let token, !token.isExpired { return token }
            if let loading { return await loading.value }

            let task = Task.detached(priority: .utility) { loader() }
            loading = task
            let fresh = await task.value
            loading = nil
            token = fresh
            return fresh
        }

        func clear() { token = nil }

        func peek() -> Token? {
            guard let token, !token.isExpired else { return nil }
            return token
        }
    }
    private static let cache = Cache()

    /// Returns a still-valid cached token, otherwise reads from disk/Keychain
    /// and caches the result.
    static func load(
        using loader: @escaping @Sendable () -> Token? = { loadUncached() }
    ) async -> Token? {
        await cache.load(using: loader)
    }

    /// The cached token if it is still valid, never reading disk or the
    /// Keychain: for secondary reads that must not cost a prompt of their own.
    static func cachedToken() async -> Token? {
        await cache.peek()
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

    /// After a failed read, the next one waits this long. A failure other
    /// than "no such item" may have been a dialog of the tool's own (a locked
    /// keychain, an item that stopped trusting the tool), cancelled, denied or
    /// timed out: a refresh a minute must not keep bringing it back.
    static let failureBackoff: Duration = .seconds(5 * 60)
    private static let lastFailure = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    private static func loadFromKeychain() -> Token? {
        keychainToken(
            toolAvailable: KeychainToolReader.isAvailable,
            read: { KeychainToolReader.readGenericPassword(service: keychainService, account: keychainAccount()) },
            readWithSecurityAPI: loadWithSecurityAPI,
            now: .now)
    }

    /// Reads through the tool; only on a system without it is the item read
    /// in process, as before 2026-10-30, at the cost of a prompt after each
    /// token refresh. A failed read is no token, never a second, prompting
    /// try.
    static func keychainToken(
        toolAvailable: Bool,
        read: () -> KeychainToolReader.Result,
        readWithSecurityAPI: () -> Token?,
        now: ContinuousClock.Instant
    ) -> Token? {
        guard toolAvailable else { return readWithSecurityAPI() }
        if keychainReadsHeldOff(now: now) { return nil }
        switch read() {
        case let .data(data):
            return parse(data)
        case .failed(.exit(KeychainToolReader.itemNotFoundStatus)):
            return nil
        case .failed, .unavailable:
            lastFailure.withLock { $0 = now }
            return nil
        }
    }

    /// True while reads wait after a failure. `claude /usage` reads the same
    /// item through the same tool, so the scrape waits too.
    static func keychainReadsHeldOff(now: ContinuousClock.Instant = .now) -> Bool {
        guard let last = lastFailure.withLock({ $0 }) else { return false }
        return now < last.advanced(by: failureBackoff)
    }

    static func resetKeychainBackoff() {
        lastFailure.withLock { $0 = nil }
    }

    /// The account Claude Code stores the item under: `USER`, else the login
    /// name, and `claude-code-user` for anything that is not a plain name
    /// (Claude Code 2.1.301's own rule). Read as Claude Code reads it, so a
    /// stray item with the same service under another account is not used.
    static func keychainAccount(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName()
    ) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? userName
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
        return plain ? name : "claude-code-user"
    }

    private static func loadWithSecurityAPI() -> Token? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return parse(data)
    }

    // MARK: - Parse

    /// Shape: { "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt" (ms epoch), "subscriptionType", "rateLimitTier" } }
    /// `security -w` prints a value that is not plain text as hex; that is
    /// decoded first.
    static func parse(_ data: Data) -> Token? {
        let data = hexDecoded(data) ?? data
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String
        var expires: Date?
        // Claude Code may persist 0 as an "unknown expiry" sentinel. Treating
        // it as the Unix epoch makes the in-process cache miss every refresh,
        // which repeatedly asks macOS to authorize this Keychain item.
        if let ms = oauth["expiresAt"] as? Double, ms.isFinite, ms > 0 {
            expires = Date(timeIntervalSince1970: ms / 1000.0)
        }
        // The plan is rendered uppercased in the popover badge, so treat it as
        // untrusted display text: `PlanLabel` keeps only an ASCII name.
        let subscription = (oauth["subscriptionType"] as? String).flatMap(PlanLabel.normalized)
        // The tier is a bare identifier Claude Code validates with this same
        // pattern before trusting it, and it can reach a tooltip, so anything
        // that does not match is dropped rather than shown.
        var rateLimitTier: String?
        if let raw = oauth["rateLimitTier"] as? String {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if PlanLabel.wholeMatch(normalized, rateLimitTierPattern) {
                rateLimitTier = normalized
            }
        }
        return Token(accessToken: access, refreshToken: refresh, expiresAt: expires,
                     subscriptionType: subscription, rateLimitTier: rateLimitTier)
    }

    /// What a `rateLimitTier` may look like — Claude Code's own check for the
    /// field. Anchored, and `parse` also requires the match to span the whole
    /// value, so a partial hit never gets through.
    static let rateLimitTierPattern = "^[a-z][a-z0-9_]{0,63}$"

    /// The bytes an even-length run of hex digits stands for; nil for anything
    /// else (a JSON document never is one).
    static func hexDecoded(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        var result = Data(capacity: data.count / 2)
        var high: UInt8?
        for byte in data {
            guard let value = nibble(byte) else { return nil }
            if let h = high {
                result.append(h << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return result
    }
}
