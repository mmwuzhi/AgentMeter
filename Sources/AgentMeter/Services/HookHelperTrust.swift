import CryptoKit
import Darwin
import Foundation
import os
import Security

/// Whether the hook helper about to be installed is this build's own helper,
/// and whether the installed copy actually runs.
///
/// The helper ships inside the app bundle, sealed by the app's signature, and
/// Gatekeeper assesses the bundle when the user first opens it. Claude Code,
/// though, runs a copy in the support directory. `ClaudeHookInstaller.refreshManagedCLI`
/// installs that copy only when the bundled helper passes the check that fits
/// how this build is signed (`Policy`), and writes it from the bytes it read
/// (for an ad-hoc build, the very bytes the digest covered): a file this app
/// creates, so the download's `com.apple.quarantine` is not carried onto it
/// the way a file copy carries it.
///
/// What that does and does not prove: for a Developer ID build that Apple
/// notarized, the helper is part of what the notary service checked, and a
/// copy the trusted app writes is treated like any file it creates. For a
/// build that is not notarized (local, rc and ad-hoc builds), the copy runs on
/// the strength of the user's Open Anyway for the app (or of having built it)
/// and this check, without a Gatekeeper assessment of its own — a documented
/// limitation of those builds (docs/agent/release.md), not a
/// Gatekeeper-approved distribution. Measured 2026-10-30 on macOS 26: a
/// quarantined copy of a non-notarized helper run from zsh, sh or node raised
/// "Not Opened" and hung until killed. `probe` runs the copy's harmless `path`
/// command, so Settings can say when macOS refuses it anyway.
///
/// Re-signing the whole bundle (for example `codesign --force --deep -s -`)
/// re-signs the helper too, so its bytes no longer match the digest and an
/// ad-hoc app refuses it. Rebuild instead.
enum HookHelperTrust {
    static let quarantineAttribute = "com.apple.quarantine"

    /// Info.plist key `Scripts/bundle.sh` sets to the signed helper's
    /// SHA-256 (lowercase hex) before it signs the app, so the app's
    /// signature seals it.
    static let helperDigestKey = "AgentMeterHookSHA256"

    /// How a build checks the helper it installs, decided by its own signature.
    enum Policy: Equatable, Sendable {
        /// A team-signed build: the helper must pass strict validation and be
        /// signed by an Apple-issued certificate of the same team. This is a
        /// developer identity check.
        case sameTeam(String)
        /// A build without a Team ID (ad-hoc) has no identity to check. The
        /// helper must pass strict validation and its bytes must have the
        /// SHA-256 sealed into this app's Info.plist (nil: the app did not
        /// validate or holds no digest). That proves the helper is the one
        /// built into this app; it says nothing about who built the app.
        case sealedDigest(String?)
    }

    /// This process's signing team, nil for an ad-hoc or unsigned build.
    static let ownTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }()

    static var ownPolicy: Policy {
        ownTeamIdentifier.map(Policy.sameTeam) ?? .sealedDigest(ownSealedHelperDigest)
    }

    /// The helper digest this app's signature seals, read only after the app
    /// on disk validates strictly and is the code that is running (an ad-hoc
    /// build's only anchor is the app the user opened). Kept once read; a
    /// failure is logged and tried again on the next check. A bundle replaced
    /// on disk later is not trusted by this process; its own process
    /// installs its helper.
    private static var ownSealedHelperDigest: String? {
        if let digest = sealedDigestCache.withLock({ $0 }) { return digest }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        let status = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else {
            logger.error("ad-hoc build: this app did not validate (OSStatus \(status)); not installing the hook helper")
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        // The running-code check above passed with a helper swapped into the
        // bundle (measured 2026-11-02); the bundle's own seal is what fails.
        let sealStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard sealStatus == errSecSuccess else {
            logger.error("ad-hoc build: this app's bundle no longer matches its signature (OSStatus \(sealStatus)); not installing the hook helper")
            return nil
        }
        guard let digest = sealedHelperDigest(in: staticCode) else {
            logger.error("ad-hoc build: no \(helperDigestKey, privacy: .public) in this app's Info.plist; not installing the hook helper")
            return nil
        }
        sealedDigestCache.withLock { $0 = digest }
        return digest
    }

    private static let sealedDigestCache = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let logger = Logger(subsystem: "com.shu.agentmeter", category: "hooks")

    /// Whether `data`, the bytes read from `helper` to be installed, may be
    /// installed under `policy`.
    static func isTrusted(_ data: Data, from helper: URL, policy: Policy = ownPolicy) -> Bool {
        switch policy {
        case .sameTeam(let team):
            return hasValidSignature(helper, team: team)
        case .sealedDigest(let expected):
            guard let expected else { return false }
            guard sha256Hex(data) == expected else {
                logger.error("ad-hoc build: the bundled hook helper does not match the digest this app seals; not installing it")
                return false
            }
            return hasValidSignature(helper, team: nil)
        }
    }

    /// Strict validation of `helper`'s signature; with `team`, also the
    /// requirement that an Apple-issued certificate for that team signed it.
    static func hasValidSignature(_ helper: URL, team: String?) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var requirement: SecRequirement?
        if let team {
            guard team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                return false
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    /// The helper digest in the Info.plist bound to `code`'s signature, after
    /// strict validation of the whole bundle (so the Info.plist and the
    /// bundled helper are both what was signed); nil when it does not
    /// validate or holds no well-formed digest.
    static func sealedHelperDigest(in code: SecStaticCode) -> String? {
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let plist = (info as? [String: Any])?[kSecCodeInfoPList as String] as? [String: Any],
              let digest = plist[helperDigestKey] as? String,
              digest.utf8.count == 64, digest.allSatisfy(\.isHexDigit)
        else { return nil }
        return digest.lowercased()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    enum Probe: Equatable, Sendable {
        case ran
        case failed(String)
    }

    /// Runs `helper path`, which only prints the status directory. Blocks
    /// for at most `timeout`; never call it on the main thread.
    static func probe(_ helper: URL, timeout: TimeInterval = 5) -> Probe {
        switch KeychainToolReader.run(executable: helper, arguments: ["path"], timeout: timeout, outputLimit: 16 * 1024) {
        case .data:
            return .ran
        case .unavailable:
            return .failed("macOS didn't let it start")
        case .failed(.uncaughtSignal(let signal)):
            return .failed(signal == SIGKILL ? "macOS stopped it" : "it stopped on signal \(signal)")
        case .failed(.exit(let status)):
            return .failed("it exited with status \(status)")
        case .failed(.timedOut):
            return .failed("it didn't finish")
        case .failed(.emptyOutput), .failed(.outputTooLarge):
            return .failed("it printed something unexpected")
        }
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }
}
