import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeResetGrantFetcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-15

    private func parse(_ json: String) throws -> ClaudeResetState? {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return ClaudeResetGrantFetcher.parseState(from: obj, at: now)
    }

    /// Shape taken from Claude Code 2.1.292's `cedar_ember` schema.
    func testParsesAnEligibleBlockWithGrants() throws {
        let state = try XCTUnwrap(parse("""
        {"five_hour": {"utilization": 15}, "cedar_ember": {
          "eligible": true, "ineligible_reason": null, "at_limit": false, "exhausted": [],
          "next_grant_id": "launch-2026-09",
          "grants": [
            {"id": "launch-2026-09", "label": "Launch reset", "resets_total": 1, "resets_left": 1,
             "starts_at": "2026-09-22T00:00:00Z", "ends_at": "2026-10-22T07:00:00Z",
             "clears": ["seven_day"], "paused": false, "usable_now": true,
             "use_requires_limit": false, "percent_used": {"seven_day": 59}, "blocking": []}
          ]}}
        """))

        XCTAssertEqual(state.eligible, true)
        XCTAssertNil(state.ineligibleReason)
        XCTAssertEqual(state.grants, [ClaudeResetGrant(
            id: "launch-2026-09", resetsLeft: 1,
            endsAt: CodexRolloutReader.parseISO("2026-10-22T07:00:00Z"), clears: ["seven_day"])])
    }

    func testNullOrMissingGrantsMeanNone() throws {
        XCTAssertEqual(try parse(#"{"cedar_ember": {"eligible": true, "grants": null}}"#),
                       ClaudeResetState(eligible: true))
        XCTAssertEqual(try parse(#"{"cedar_ember": {"eligible": true}}"#), ClaudeResetState(eligible: true))
    }

    /// Claude Code's schema catches a non-string `ends_at` to null, so such a
    /// grant stays, with no deadline.
    func testNonStringDeadlineReadsAsNone() throws {
        let state = try XCTUnwrap(parse(
            #"{"cedar_ember": {"eligible": true, "grants": [{"id": "g", "resets_left": 1, "ends_at": 1792600000}]}}"#))

        XCTAssertEqual(state.grants.map(\.id), ["g"])
        XCTAssertNil(state.grants.first?.endsAt)
    }

    func testNullOrMissingBlockMeansNoResets() throws {
        XCTAssertEqual(try parse(#"{"five_hour": {"utilization": 15}, "cedar_ember": null}"#), ClaudeResetState())
        XCTAssertEqual(try parse(#"{"five_hour": {"utilization": 15}}"#), ClaudeResetState())
    }

    func testIneligibleBlockKeepsTheReasonAndNoGrants() throws {
        let state = try XCTUnwrap(parse("""
        {"cedar_ember": {"eligible": false, "ineligible_reason": "seat",
          "grants": [{"id": "g", "resets_left": 1, "clears": ["five_hour"]}]}}
        """))

        XCTAssertEqual(state, ClaudeResetState(eligible: false, ineligibleReason: "seat"))
    }

    func testUnknownIneligibleReasonReadsAsUnknown() throws {
        let state = try XCTUnwrap(parse(#"{"cedar_ember": {"eligible": false, "ineligible_reason": "<b>new</b>"}}"#))

        XCTAssertEqual(state.ineligibleReason, "unknown")
    }

    func testMalformedBlockIsNilSoTheCallerKeepsWhatItHad() throws {
        XCTAssertNil(try parse(#"{"cedar_ember": ["eligible"]}"#))
        XCTAssertNil(try parse(#"{"cedar_ember": "on"}"#))
        XCTAssertNil(try parse(#"{"cedar_ember": {"grants": []}}"#))
        XCTAssertNil(try parse(#"{"cedar_ember": {"eligible": 1}}"#))
        XCTAssertNil(try parse(#"{"cedar_ember": {"eligible": true, "grants": {"items": []}}}"#))
    }

    func testDropsGrantsThatBreakClaudeCodesRules() throws {
        let state = try XCTUnwrap(parse("""
        {"cedar_ember": {"eligible": true, "grants": [
          {"id": "Bad ID", "resets_left": 1, "clears": ["five_hour"]},
          {"id": "negative", "resets_left": -1, "clears": ["five_hour"]},
          {"id": "fraction", "resets_left": 1.5, "clears": ["five_hour"]},
          {"id": "boolean", "resets_left": true, "clears": ["five_hour"]},
          {"id": "missing-left", "clears": ["five_hour"]},
          {"id": "spent", "resets_left": 0, "clears": ["five_hour"]},
          {"id": "expired", "resets_left": 1, "ends_at": "2026-10-01T00:00:00Z", "clears": ["five_hour"]},
          "not an object",
          {"id": "kept", "resets_left": 2, "ends_at": "2026-10-20T00:00:00Z", "clears": ["five_hour"]}
        ]}}
        """))

        XCTAssertEqual(state.grants.map(\.id), ["kept"])
        XCTAssertEqual(state.grants.first?.resetsLeft, 2)
    }

    func testClearsKeepsOnlyKnownLimitIDsAndANullDeadlineSortsLast() throws {
        let state = try XCTUnwrap(parse("""
        {"cedar_ember": {"eligible": true, "grants": [
          {"id": "open", "resets_left": 1, "ends_at": null, "clears": ["five_hour", "made_up", 7]},
          {"id": "dated", "resets_left": 1, "ends_at": "2026-10-20T00:00:00Z", "clears": "seven_day"}
        ]}}
        """))

        XCTAssertEqual(state.grants.map(\.id), ["dated", "open"])
        XCTAssertEqual(state.grants[0].clears, [])
        XCTAssertNil(state.grants[1].endsAt)
        XCTAssertEqual(state.grants[1].clears, ["five_hour"])
    }

    func testGrantsAreCapped() throws {
        let entries = (0..<50).map { #"{"id": "g\#($0)", "resets_left": 1}"# }.joined(separator: ",")
        let state = try XCTUnwrap(parse(#"{"cedar_ember": {"eligible": true, "grants": [\#(entries)]}}"#))

        XCTAssertEqual(state.grants.count, ClaudeResetGrantFetcher.maxStoredGrants)
    }

    func testRefillLabelNamesTheWindowsAsTheirRowsDo() {
        XCTAssertEqual(ClaudeResetGrantFetcher.refillLabel(for: ["seven_day"]), "Weekly")
        XCTAssertEqual(ClaudeResetGrantFetcher.refillLabel(for: ["five_hour", "seven_day"]), "5-hour + Weekly")
        XCTAssertNil(ClaudeResetGrantFetcher.refillLabel(for: ["seven_day_cowork"]))
        XCTAssertNil(ClaudeResetGrantFetcher.refillLabel(for: []))
    }

    /// The reset read must never be the one to touch the Keychain.
    func testCachedTokenReturnsOnlyWhatIsAlreadyCached() async {
        await ClaudeCredentials.invalidate()
        let before = await ClaudeCredentials.cachedToken()
        XCTAssertNil(before)

        _ = await ClaudeCredentials.load(using: {
            ClaudeCredentials.Token(accessToken: "cached", refreshToken: nil, expiresAt: nil)
        })
        let after = await ClaudeCredentials.cachedToken()
        XCTAssertEqual(after?.accessToken, "cached")

        await ClaudeCredentials.invalidate()
    }
}
