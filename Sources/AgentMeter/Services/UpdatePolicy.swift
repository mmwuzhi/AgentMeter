import Foundation

/// How this build updates itself, decided from its Info.plist alone.
///
/// A release build (no channel key) runs Sparkle against the feed in
/// `SUFeedURL`. A release candidate (`Scripts/bundle.sh` with
/// `UPDATE_CHANNEL=rc`) is a test build: it has no feed, and it must not
/// start Sparkle, offer "Check Now" or point at the public feed.
enum UpdatePolicy: Equatable {
    /// Start Sparkle with the feed and key from Info.plist.
    case sparkle
    /// A test build: updates are off.
    case offInTestBuild
    /// A release build without a usable feed and key (a fresh checkout).
    case notConfigured

    /// Info.plist key `Scripts/bundle.sh` sets to `rc` for a test build.
    static let channelKey = "AgentMeterUpdateChannel"

    static let testBuildNotice = "Updates are off in this test build. It will not update itself from the public feed."

    static func decide(from info: [String: Any]?) -> UpdatePolicy {
        if info?[channelKey] as? String == "rc" { return .offInTestBuild }
        let feed = (info?["SUFeedURL"] as? String) ?? ""
        let key = (info?["SUPublicEDKey"] as? String) ?? ""
        let configured = feed.hasPrefix("http") && !key.isEmpty && !key.contains("REPLACE")
        return configured ? .sparkle : .notConfigured
    }

    /// e.g. "1.4.2 (37)", or "0.9.0 RC (202610302130)" for a test build;
    /// without a build number just the version, and "—" without either.
    static func versionLabel(from info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let marker = info?[channelKey] as? String == "rc" ? " RC" : ""
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short)\(marker) (\($0))" } ?? "\(short)\(marker)"
    }
}
