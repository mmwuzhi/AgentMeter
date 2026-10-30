@testable import AgentMeter
import Foundation
import XCTest

/// A release candidate (`UPDATE_CHANNEL=rc` in `Scripts/bundle.sh`) must not
/// start Sparkle or offer "Check Now"; a release build keeps working as before.
final class UpdatePolicyTests: XCTestCase {
    private let feed = "https://github.com/mmwuzhi/AgentMeter/releases/latest/download/appcast.xml"
    private let key = "gqRMHXb01NMIo4Nu3uxkKmt/WO0aYMb5RPjCty8TKYw="

    func testReleaseWithFeedAndKeyStartsSparkle() {
        XCTAssertEqual(UpdatePolicy.decide(from: ["SUFeedURL": feed, "SUPublicEDKey": key]), .sparkle)
        XCTAssertEqual(UpdatePolicy.decide(from: ["SUFeedURL": feed, "SUPublicEDKey": key,
                                                  UpdatePolicy.channelKey: "release"]), .sparkle)
    }

    func testReleaseWithoutUsableFeedOrKeyIsNotConfigured() {
        XCTAssertEqual(UpdatePolicy.decide(from: nil), .notConfigured)
        XCTAssertEqual(UpdatePolicy.decide(from: [:]), .notConfigured)
        XCTAssertEqual(UpdatePolicy.decide(from: ["SUPublicEDKey": key]), .notConfigured)
        XCTAssertEqual(UpdatePolicy.decide(from: ["SUFeedURL": feed]), .notConfigured)
        XCTAssertEqual(UpdatePolicy.decide(from: ["SUFeedURL": feed, "SUPublicEDKey": "REPLACE_ME"]), .notConfigured)
        XCTAssertEqual(UpdatePolicy.decide(from: ["SUFeedURL": "file:///appcast.xml", "SUPublicEDKey": key]), .notConfigured)
    }

    func testReleaseCandidateNeverStartsSparkle() {
        XCTAssertEqual(UpdatePolicy.decide(from: [UpdatePolicy.channelKey: "rc"]), .offInTestBuild)
        XCTAssertEqual(UpdatePolicy.decide(from: [UpdatePolicy.channelKey: "rc", "SUPublicEDKey": key]), .offInTestBuild)
        XCTAssertEqual(UpdatePolicy.decide(from: [UpdatePolicy.channelKey: "rc", "SUFeedURL": feed, "SUPublicEDKey": key]),
                       .offInTestBuild, "the channel wins even if a feed was left in the plist")
    }

    func testVersionLabel() {
        XCTAssertEqual(UpdatePolicy.versionLabel(from: ["CFBundleShortVersionString": "0.8.2", "CFBundleVersion": "19"]),
                       "0.8.2 (19)")
        XCTAssertEqual(UpdatePolicy.versionLabel(from: ["CFBundleShortVersionString": "0.9.0",
                                                        "CFBundleVersion": "202610302130",
                                                        UpdatePolicy.channelKey: "rc"]),
                       "0.9.0 RC (202610302130)")
        XCTAssertEqual(UpdatePolicy.versionLabel(from: ["CFBundleShortVersionString": "0.9.0"]), "0.9.0")
        XCTAssertEqual(UpdatePolicy.versionLabel(from: ["CFBundleShortVersionString": "0.9.0", UpdatePolicy.channelKey: "rc"]),
                       "0.9.0 RC")
        XCTAssertEqual(UpdatePolicy.versionLabel(from: nil), "—")
    }

    /// The template `Scripts/bundle.sh` fills in is the release channel: it
    /// carries the public feed and key and no channel marker.
    func testInfoPlistTemplateIsTheReleaseChannel() throws {
        let template = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: template) as? [String: Any])
        XCTAssertNil(info[UpdatePolicy.channelKey])
        XCTAssertEqual(UpdatePolicy.decide(from: info), .sparkle)
    }
}
