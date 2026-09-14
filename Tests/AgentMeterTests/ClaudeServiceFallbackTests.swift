import Foundation
@testable import AgentMeter
import XCTest

/// `ClaudeService.oauthFallback` decides whether a failed OAuth read falls
/// through to the `claude /usage` scrape or keeps the last live reading.
/// Pure decision, no network: the fetcher and the scraper are not exercised.
final class ClaudeServiceFallbackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// `ClaudeOAuthFetcher.responseError` maps 429 and 5xx alike onto this.
    private let transientError = URLError(.badServerResponse)

    private func snapshot(
        age: TimeInterval,
        resetsIn: TimeInterval = 3600,
        source: QuotaSnapshot.SourceKind = .oauth
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 12, resetsAt: now.addingTimeInterval(resetsIn)),
                QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 49, resetsAt: now.addingTimeInterval(resetsIn)),
            ],
            source: source,
            planType: "pro",
            fetchedAt: now.addingTimeInterval(-age),
            note: nil
        )
    }

    func testTransientOAuthErrorKeepsThreeMinuteOldLiveSnapshot() {
        let previous = snapshot(age: 3 * 60)

        XCTAssertEqual(
            ClaudeService.oauthFallback(after: transientError, previous: previous, at: now),
            .keepLastLive
        )

        // What fetchQuota hands back for `.keepLastLive`, and what the merge
        // step then does with it: the live reading returns, source and all.
        let kept = ClaudeService.lastLiveQuota(failedAt: now)
        XCTAssertEqual(kept.source, .unavailable)
        XCTAssertTrue(kept.windows.isEmpty)
        XCTAssertNotNil(
            kept.note?.range(
                of: "^Live quota fetch failed at [0-9]{2}:[0-9]{2} — showing the last live reading$",
                options: .regularExpression
            ),
            "unexpected note: \(kept.note ?? "nil")"
        )
        let state = ProviderState(provider: .claude, quota: kept, usage: .empty(.claude))
        XCTAssertEqual(state.preservingLiveQuota(from: previous, at: now).quota, previous)
    }

    func testTransientOAuthErrorScrapesWhenLiveSnapshotIsTwoHoursOld() {
        XCTAssertEqual(
            ClaudeService.oauthFallback(after: transientError, previous: snapshot(age: 2 * 3600), at: now),
            .scrape
        )
        XCTAssertEqual(
            ClaudeService.oauthFallback(
                after: transientError,
                previous: snapshot(age: ClaudeService.recentLiveQuotaMaxAge),
                at: now
            ),
            .keepLastLive,
            "the bound is inclusive"
        )
    }

    func testAuthenticationErrorAlwaysScrapes() {
        XCTAssertEqual(
            ClaudeService.oauthFallback(
                after: URLError(.userAuthenticationRequired),
                previous: snapshot(age: 3 * 60),
                at: now
            ),
            .scrape,
            "the CLI can refresh a rejected token; AgentMeter cannot"
        )
    }

    func testTransientOAuthErrorScrapesWithoutALivePrevious() {
        XCTAssertEqual(ClaudeService.oauthFallback(after: transientError, previous: nil, at: now), .scrape)
        XCTAssertEqual(
            ClaudeService.oauthFallback(after: transientError, previous: snapshot(age: 60, source: .cli), at: now),
            .scrape,
            "a previous scrape is not a live reading worth keeping"
        )
        XCTAssertEqual(
            ClaudeService.oauthFallback(
                after: transientError,
                previous: .unavailable(.claude, note: "Live quota unavailable — showing usage only"),
                at: now
            ),
            .scrape
        )
    }

    func testTransientOAuthErrorScrapesWhenEveryWindowHasReset() {
        XCTAssertEqual(
            ClaudeService.oauthFallback(after: transientError, previous: snapshot(age: 3 * 60, resetsIn: -60), at: now),
            .scrape,
            "a reading whose windows have all reset says nothing about the current epoch"
        )
    }
}
