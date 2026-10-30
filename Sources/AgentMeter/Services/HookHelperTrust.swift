import Darwin
import Foundation
import Security

/// Whether the hook helper about to be installed is this build's own signed
/// code, and whether the installed copy actually runs.
///
/// The helper ships inside the app bundle, sealed by the app's signature, and
/// Gatekeeper assesses the bundle when the user first opens it. Claude Code,
/// though, runs a copy in the support directory. `ClaudeHookInstaller.refreshManagedCLI`
/// installs that copy only when the bundled helper passes strict signature
/// validation and, for a team-signed app, carries the same team, and writes
/// it from the verified bytes: a file this app creates, so the download's
/// `com.apple.quarantine` is not carried onto it the way a file copy carries
/// it.
///
/// What that does and does not prove: for a Developer ID build that Apple
/// notarized, the helper is part of what the notary service checked, and a
/// copy the trusted app writes is treated like any file it creates. For a
/// build that is not notarized (local and rc builds), the copy runs on the
/// strength of the user's Open Anyway for the app and this signature check,
/// without a Gatekeeper assessment of its own — a documented limitation of
/// those builds (docs/agent/release.md), not a Gatekeeper-approved
/// distribution. Measured 2026-10-30 on macOS 26: a quarantined copy of a
/// non-notarized helper run from zsh, sh or node raised "Not Opened" and hung
/// until killed. `probe` runs the copy's harmless `path` command, so Settings
/// can say when macOS refuses it anyway.
enum HookHelperTrust {
    static let quarantineAttribute = "com.apple.quarantine"

    /// This process's signing team, nil for an ad-hoc or unsigned build.
    static let ownTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }()

    /// Strict validation of `helper`'s signature; with `team`, also the
    /// requirement that an Apple-issued certificate for that team signed it.
    static func isTrusted(_ helper: URL, team: String? = ownTeamIdentifier) -> Bool {
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
