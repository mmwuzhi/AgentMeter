import Foundation
@testable import AgentMeter
import XCTest

/// What `ClaudeOAuthFetcher.parseSnapshot` records about a window beyond its
/// percentage (`QuotaWindowDetail`) for the history store, and that none of it
/// changes a window, id, order, value or label the screen shows.
///
/// The bodies are JSON text decoded with `JSONSerialization`, the path a real
/// response takes, so booleans and numbers have the types a live body gives
/// them. `severity`, `weekly_scoped_shares` and `locked_reason` have no live
/// capture in the repo: their shape is the one the investigation reported
/// (`{limit_index: 2, used_percent_of_weekly: 24, allowance_percent_of_weekly:
/// 50}` against a Fable limit at 46%); the values below are test data.
final class ClaudeOAuthDetailParseTests: XCTestCase {
    private func body(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("fixture is not a JSON object", file: file, line: line)
            return [:]
        }
        return object
    }

    private func parse(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> QuotaSnapshot {
        try ClaudeOAuthFetcher.parseSnapshot(from: body(json, file: file, line: line))
    }

    private func window(_ id: String, in snapshot: QuotaSnapshot, file: StaticString = #filePath, line: UInt = #line) throws -> QuotaWindow {
        try XCTUnwrap(snapshot.windows.first { $0.id == id }, "no window \(id)", file: file, line: line)
    }

    private static let session = #"{"kind":"session","group":"session","percent":74,"resets_at":"2025-01-03T10:00:00.123456+00:00","is_active":true}"#
    private static let weeklyAll = #"{"kind":"weekly_all","group":"weekly","percent":42,"resets_at":"2025-01-07T12:00:00.123457+00:00","is_active":false}"#

    private static func scoped(_ name: String, percent: Int = 48, extra: String = "") -> String {
        #"{"kind":"weekly_scoped","group":"weekly","percent":\#(percent),"resets_at":"2025-01-07T12:00:00.123458+00:00","scope":{"model":{"id":null,"display_name":"\#(name)"},"surface":null},"is_active":false\#(extra)}"#
    }

    // MARK: - limits[] metadata and shares

    func testLimitsMetadataSeverityAndSharesLandOnTheWindowsTheyDescribe() throws {
        let snapshot = try parse("""
        {
          "five_hour": {"utilization": 74.0, "resets_at": "2025-01-03T10:00:00.123456+00:00"},
          "seven_day": {"utilization": 42.0, "resets_at": "2025-01-07T12:00:00.123457+00:00"},
          "seven_day_opus": null,
          "limits": [
            {"kind":"session","group":"session","percent":74,"resets_at":"2025-01-03T10:00:00.123456+00:00","is_active":true,"severity":"warning"},
            {"kind":"weekly_all","group":"weekly","percent":42,"resets_at":"2025-01-07T12:00:00.123457+00:00","is_active":false,"severity":"normal"},
            \(Self.scoped("Fable", extra: #","severity":"normal""#))
          ],
          "weekly_scoped_shares": [
            {"limit_index": 2, "used_percent_of_weekly": 24, "allowance_percent_of_weekly": 50}
          ]
        }
        """)

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        let five = try window("five_hour", in: snapshot).detail
        XCTAssertEqual(five?.isActive, true)
        XCTAssertEqual(five?.severity, "warning")
        XCTAssertEqual(five?.utilizationStated, true)
        XCTAssertNil(five?.scopeName)
        XCTAssertNil(five?.shareUsedOfWeekly)

        let weekly = try window("seven_day", in: snapshot).detail
        XCTAssertEqual(weekly?.isActive, false)
        XCTAssertEqual(weekly?.severity, "normal")

        let fable = try window("seven_day_fable", in: snapshot)
        XCTAssertEqual(fable.detail?.isActive, false)
        XCTAssertEqual(fable.detail?.severity, "normal")
        XCTAssertEqual(fable.detail?.scopeName, "Fable")
        XCTAssertEqual(fable.detail?.shareUsedOfWeekly, 24)
        XCTAssertEqual(fable.detail?.shareAllowanceOfWeekly, 50)
        XCTAssertEqual(fable.detail?.utilizationStated, true)
        XCTAssertEqual(fable.usedPercent, 48)
        XCTAssertEqual(fable.isModelScoped, true)
    }

    /// The named window stays authoritative for its numbers, the limit only adds
    /// what it knows about the window.
    func testLimitsMetadataIsMergedIntoNamedFiveHourAndSevenDayWithoutChangingThem() throws {
        let snapshot = try parse("""
        {
          "five_hour": {"utilization": 74.0, "resets_at": "2025-01-03T10:00:00.123456+00:00"},
          "seven_day": {"utilization": 42.0},
          "limits": [
            {"kind":"session","percent":99,"is_active":true,"severity":"critical"},
            {"kind":"weekly_all","percent":99,"is_active":false}
          ]
        }
        """)

        let five = try window("five_hour", in: snapshot)
        XCTAssertEqual(five.usedPercent, 74, "the named key's value stands")
        XCTAssertNotNil(five.resetsAt, "so does its reset time")
        XCTAssertEqual(five.detail?.isActive, true)
        XCTAssertEqual(five.detail?.severity, "critical")
        XCTAssertEqual(five.detail?.utilizationStated, true)
        let seven = try window("seven_day", in: snapshot)
        XCTAssertEqual(seven.usedPercent, 42)
        XCTAssertEqual(seven.detail?.isActive, false)
        XCTAssertNil(seven.detail?.severity, "absent stays nil")
    }

    func testOnlyTheFirstLimitOfAnIdAddsItsMetadata() throws {
        let snapshot = try parse("""
        {
          "five_hour": {"utilization": 10},
          "limits": [
            {"kind":"session","percent":10,"is_active":true,"severity":"first"},
            {"kind":"session","percent":10,"is_active":false,"severity":"second"},
            \(Self.scoped("Fable", percent: 48, extra: #","severity":"alpha""#)),
            \(Self.scoped("Fable", percent: 80, extra: #","severity":"beta""#))
          ],
          "weekly_scoped_shares": [
            {"limit_index": 3, "used_percent_of_weekly": 99, "allowance_percent_of_weekly": 99},
            {"limit_index": 2, "used_percent_of_weekly": 20, "allowance_percent_of_weekly": 50}
          ]
        }
        """)

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day_fable"])
        XCTAssertEqual(try window("five_hour", in: snapshot).detail?.severity, "first")
        let fable = try window("seven_day_fable", in: snapshot)
        XCTAssertEqual(fable.usedPercent, 48, "the first scoped limit built the window, as before")
        XCTAssertEqual(fable.detail?.severity, "alpha")
        XCTAssertEqual(fable.detail?.shareUsedOfWeekly, 20, "a share naming the skipped duplicate (index 3) is dropped")
    }

    /// `limit_index` counts the ORIGINAL array. An unknown kind in front shifts
    /// every index after it, and a share aimed at a limit that built no window
    /// attaches to nothing.
    func testSharesIndexTheOriginalLimitsArrayIncludingSkippedEntries() throws {
        let snapshot = try parse("""
        {
          "limits": [
            {"kind":"monthly_mystery","percent":50},
            \(Self.session),
            \(Self.weeklyAll),
            {"kind":"weekly_scoped","percent":10,"scope":{"model":{"id":null,"display_name":null}}},
            \(Self.scoped("Fable"))
          ],
          "weekly_scoped_shares": [
            {"limit_index": 4, "used_percent_of_weekly": 24, "allowance_percent_of_weekly": 50},
            {"limit_index": 0, "used_percent_of_weekly": 5, "allowance_percent_of_weekly": 5},
            {"limit_index": 3, "used_percent_of_weekly": 6, "allowance_percent_of_weekly": 6},
            {"limit_index": 5, "used_percent_of_weekly": 7, "allowance_percent_of_weekly": 7},
            {"limit_index": 99, "used_percent_of_weekly": 8, "allowance_percent_of_weekly": 8}
          ]
        }
        """)

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        let fable = try window("seven_day_fable", in: snapshot).detail
        XCTAssertEqual(fable?.shareUsedOfWeekly, 24)
        XCTAssertEqual(fable?.shareAllowanceOfWeekly, 50)
        XCTAssertNil(try window("five_hour", in: snapshot).detail?.shareUsedOfWeekly, "index 0 was the unknown kind")
        XCTAssertNil(try window("seven_day", in: snapshot).detail?.shareUsedOfWeekly)
    }

    /// A scoped limit whose id a named key already built: the share follows the
    /// limit to that named window.
    func testAShareFollowsALimitThatMergedIntoANamedWindow() throws {
        let snapshot = try parse("""
        {
          "seven_day": {"utilization": 42.0},
          "seven_day_opus": {"utilization": 20.0},
          "limits": [
            \(Self.weeklyAll),
            \(Self.scoped("Opus", percent: 21))
          ],
          "weekly_scoped_shares": [
            {"limit_index": 1, "used_percent_of_weekly": 10, "allowance_percent_of_weekly": 30}
          ]
        }
        """)

        XCTAssertEqual(snapshot.windows.map(\.id), ["seven_day", "seven_day_opus"])
        let opus = try window("seven_day_opus", in: snapshot)
        XCTAssertEqual(opus.usedPercent, 20, "the named key's number stands")
        XCTAssertNil(opus.isModelScoped, "and so does what the screen reads from it")
        XCTAssertEqual(opus.detail?.shareUsedOfWeekly, 10)
        XCTAssertEqual(opus.detail?.shareAllowanceOfWeekly, 30)
        XCTAssertEqual(opus.detail?.scopeName, "Opus")
        XCTAssertEqual(opus.detail?.isActive, false)
    }

    func testAbsentOrUnusableSharesLeaveNoShare() throws {
        let limits = #""limits": [\#(Self.session), \#(Self.weeklyAll), \#(Self.scoped("Fable"))]"#
        let bodies = [
            "{\(limits)}",
            "{\(limits), \"weekly_scoped_shares\": []}",
            "{\(limits), \"weekly_scoped_shares\": null}",
            "{\(limits), \"weekly_scoped_shares\": {\"limit_index\": 2, \"used_percent_of_weekly\": 24}}",
            "{\(limits), \"weekly_scoped_shares\": \"2\"}",
            "{\(limits), \"weekly_scoped_shares\": [7, \"x\", null, [1]]}",
            // limit_index of the wrong type or out of range
            "{\(limits), \"weekly_scoped_shares\": [{\"limit_index\": \"2\", \"used_percent_of_weekly\": 24, \"allowance_percent_of_weekly\": 50}]}",
            "{\(limits), \"weekly_scoped_shares\": [{\"limit_index\": true, \"used_percent_of_weekly\": 24, \"allowance_percent_of_weekly\": 50}]}",
            "{\(limits), \"weekly_scoped_shares\": [{\"limit_index\": 2.5, \"used_percent_of_weekly\": 24, \"allowance_percent_of_weekly\": 50}]}",
            "{\(limits), \"weekly_scoped_shares\": [{\"limit_index\": -1, \"used_percent_of_weekly\": 24, \"allowance_percent_of_weekly\": 50}]}",
            "{\(limits), \"weekly_scoped_shares\": [{\"used_percent_of_weekly\": 24, \"allowance_percent_of_weekly\": 50}]}",
            // figures of the wrong type, negative or absurd
            "{\(limits), \"weekly_scoped_shares\": [{\"limit_index\": 2, \"used_percent_of_weekly\": \"24\", \"allowance_percent_of_weekly\": \"50\"}]}",
            "{\(limits), \"weekly_scoped_shares\": [{\"limit_index\": 2, \"used_percent_of_weekly\": -4, \"allowance_percent_of_weekly\": 1001}]}",
            "{\(limits), \"weekly_scoped_shares\": [{\"limit_index\": 2, \"used_percent_of_weekly\": true, \"allowance_percent_of_weekly\": null}]}",
        ]
        for (number, json) in bodies.enumerated() {
            let snapshot = try parse(json)
            XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"], "body \(number)")
            for window in snapshot.windows {
                XCTAssertNil(window.detail?.shareUsedOfWeekly, "body \(number) \(window.id)")
                XCTAssertNil(window.detail?.shareAllowanceOfWeekly, "body \(number) \(window.id)")
            }
        }
    }

    func testOneUsableShareFigureIsKeptWhenTheOtherIsNot() throws {
        let snapshot = try parse("""
        {
          "limits": [\(Self.scoped("Fable"))],
          "weekly_scoped_shares": [
            {"limit_index": 0, "used_percent_of_weekly": 24.25, "allowance_percent_of_weekly": "50"}
          ]
        }
        """)

        let fable = try window("seven_day_fable", in: snapshot).detail
        XCTAssertEqual(fable?.shareUsedOfWeekly, 24.25, "fractions are kept")
        XCTAssertNil(fable?.shareAllowanceOfWeekly)
    }

    func testFractionalPercentsAreKeptAsStated() throws {
        let snapshot = try parse("""
        {
          "five_hour": {"utilization": 41.5},
          "limits": [
            {"kind":"weekly_all","percent":12.5},
            \(Self.scoped("Fable", percent: 7))
          ]
        }
        """)

        XCTAssertEqual(try window("five_hour", in: snapshot).usedPercent, 41.5)
        XCTAssertEqual(try window("seven_day", in: snapshot).usedPercent, 12.5)
        XCTAssertEqual(try window("seven_day", in: snapshot).detail?.utilizationStated, true)
    }

    // MARK: - locked_reason

    func testLockedReasonIsReadFromFiveHourAndSevenDayWhenItIsAString() throws {
        let snapshot = try parse("""
        {
          "five_hour": {"utilization": 100, "resets_at": "2025-01-03T10:00:00.123456+00:00", "locked_reason": "plan_limit"},
          "seven_day": {"utilization": 42, "locked_reason": null}
        }
        """)

        XCTAssertEqual(try window("five_hour", in: snapshot).detail?.lockedReason, "plan_limit")
        XCTAssertNil(try window("seven_day", in: snapshot).detail?.lockedReason, "null is not a reason")
        XCTAssertEqual(try window("five_hour", in: snapshot).usedPercent, 100)
    }

    func testLockedReasonOfTheWrongTypeOrShapeIsNil() throws {
        let values = ["42", "true", "[\"x\"]", "{\"a\": 1}", "\"\"", "\"   \"",
                      "\"\(String(repeating: "x", count: 65))\"", "\"two\\nlines\"", "\"tab\\there\"",
                      "\"bidi\\u202Eoverride\"", "\"nul\\u0000byte\"", "\"zero\\u200Bwidth\""]
        for value in values {
            let snapshot = try parse(#"{"five_hour": {"utilization": 5, "locked_reason": \#(value)}}"#)
            XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour"], value)
            XCTAssertNil(try window("five_hour", in: snapshot).detail?.lockedReason, value)
            XCTAssertEqual(try window("five_hour", in: snapshot).usedPercent, 5, value)
        }
    }

    func testLockedReasonOf64ScalarsIsKeptAndIsTrimmed() throws {
        let sixtyFour = String(repeating: "a", count: 64)
        let snapshot = try parse(#"{"five_hour": {"utilization": 5, "locked_reason": " \#(sixtyFour) "}}"#)
        XCTAssertEqual(try window("five_hour", in: snapshot).detail?.lockedReason, sixtyFour)
    }

    /// Only the two windows the response has been seen to carry it in are read.
    func testLockedReasonIsNotReadFromOtherNamedWindows() throws {
        let snapshot = try parse("""
        {"seven_day": {"utilization": 1}, "seven_day_opus": {"utilization": 2, "locked_reason": "x"},
         "cinder_cove": {"utilization": 3, "locked_reason": "y"}}
        """)
        XCTAssertNil(try window("seven_day_opus", in: snapshot).detail?.lockedReason)
        XCTAssertNil(try window("cinder_cove", in: snapshot).detail?.lockedReason)
    }

    // MARK: - A window without utilization

    func testAWindowWithoutUtilizationKeepsTheZeroPlaceholderAndSaysSo() throws {
        let snapshot = try parse("""
        {
          "five_hour": {"resets_at": "2025-01-03T10:00:00.123456+00:00", "locked_reason": "plan_limit"},
          "seven_day": {"utilization": null},
          "seven_day_opus": {"utilization": "50"},
          "seven_day_sonnet": {"utilization": 0}
        }
        """)

        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])
        for id in ["five_hour", "seven_day", "seven_day_opus"] {
            let window = try window(id, in: snapshot)
            XCTAssertEqual(window.usedPercent, 0, "\(id): the screen keeps today's placeholder")
            XCTAssertEqual(window.detail?.utilizationStated, false, id)
        }
        XCTAssertEqual(try window("five_hour", in: snapshot).detail?.lockedReason, "plan_limit")
        XCTAssertNotNil(try window("five_hour", in: snapshot).resetsAt)
        let stated = try window("seven_day_sonnet", in: snapshot)
        XCTAssertEqual(stated.usedPercent, 0)
        XCTAssertEqual(stated.detail?.utilizationStated, true, "a stated 0 is a reading")
    }

    func testABooleanUtilizationIsNotAStatedValue() throws {
        let snapshot = try parse(#"{"five_hour": {"utilization": true}}"#)
        XCTAssertEqual(try window("five_hour", in: snapshot).detail?.utilizationStated, false)
    }

    // MARK: - Odd strings and flags

    func testSeverityAndScopeNameThatFailValidationAreNil() throws {
        let long = String(repeating: "s", count: 65)
        let snapshot = try parse("""
        {
          "limits": [
            {"kind":"session","percent":1,"severity":"\(long)","is_active":"true"},
            {"kind":"weekly_all","percent":2,"severity":"hi\\u202Egh","is_active":1},
            {"kind":"weekly_scoped","percent":3,"severity":7,"is_active":null,
             "scope":{"model":{"id":null,"display_name":"Fa\\tble"}}},
            {"kind":"weekly_scoped","percent":4,"severity":"  ok  ",
             "scope":{"model":{"id":null,"display_name":"\(long)"}}}
          ]
        }
        """)

        XCTAssertEqual(snapshot.windows.count, 4, "no window is dropped for an odd string")
        let five = try window("five_hour", in: snapshot).detail
        XCTAssertNil(five?.severity, "65 scalars")
        XCTAssertNil(five?.isActive, "a string is not a boolean")
        let weekly = try window("seven_day", in: snapshot).detail
        XCTAssertNil(weekly?.severity, "bidi override")
        XCTAssertNil(weekly?.isActive, "an integer is not a boolean")
        let tabbed = snapshot.windows[2]
        XCTAssertNil(tabbed.detail?.severity, "a number is not text")
        XCTAssertNil(tabbed.detail?.scopeName, "a tab is not printable")
        XCTAssertNil(tabbed.detail?.isActive)
        let overlong = snapshot.windows[3]
        XCTAssertEqual(overlong.detail?.severity, "ok", "trimmed")
        XCTAssertNil(overlong.detail?.scopeName, "65 scalars")
    }

    /// The id and label the screen uses are built from the display name exactly
    /// as before; only the stored raw name is validated.
    func testWindowIDsFromDisplayNamesAreUnchanged() throws {
        let names: [(String, String)] = [
            ("Fable", "seven_day_fable"), ("Opus", "seven_day_opus"), ("Sonnet", "seven_day_sonnet"),
            ("Opus 4.8", "seven_day_opus_4.8"), ("  Fable  ", "seven_day_fable")
        ]
        for (name, id) in names {
            let snapshot = try parse(#"{"limits": [\#(Self.scoped(name))]}"#)
            XCTAssertEqual(snapshot.windows.map(\.id), [id], name)
            XCTAssertEqual(snapshot.windows.first?.label, "Weekly (\(name.trimmingCharacters(in: .whitespaces)))")
            XCTAssertEqual(snapshot.windows.first?.detail?.scopeName, name.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The id is the shared `QuotaWindowID.scopedWeekly`, so the parser and the
    /// transcript's usage report name one window the same way; a missing or
    /// empty name builds no window.
    func testScopedWeeklyIDsComeFromTheSharedRuleAndMissingNamesBuildNoWindow() throws {
        for name in ["Fable", "Opus 4.8", "Claude Opus 5", "  Sonnet  ", "モデル"] {
            let snapshot = try parse(#"{"limits": [\#(Self.scoped(name))]}"#)
            XCTAssertEqual(snapshot.windows.map(\.id), [QuotaWindowID.scopedWeekly(displayName: name)].compactMap { $0 }, name)
            XCTAssertEqual(snapshot.windows.count, 1, name)
        }
        XCTAssertEqual(QuotaWindowID.scopedWeekly(displayName: "Fable"), "seven_day_fable")
        XCTAssertEqual(QuotaWindowID.scopedWeekly(displayName: "Opus 4.8"), "seven_day_opus_4.8")
        XCTAssertNil(QuotaWindowID.scopedWeekly(displayName: "   "))
        XCTAssertNil(QuotaWindowID.scopedWeekly(displayName: nil))

        for scope in [#""scope": {"model": {"id": null, "display_name": "   "}}"#,
                      #""scope": {"model": {"id": null, "display_name": ""}}"#,
                      #""scope": {"model": {"id": null, "display_name": 7}}"#,
                      #""scope": {"model": {"id": null}}"#, #""scope": {}"#, #""scope": null"#, ""] {
            let comma = scope.isEmpty ? "" : ","
            let snapshot = try parse(#"{"limits": [{"kind":"weekly_scoped","percent":5\#(comma)\#(scope)}]}"#)
            XCTAssertTrue(snapshot.windows.isEmpty, scope)
        }
    }

    // MARK: - Nothing the screen shows moves

    /// The same response with and without every new field gives the same
    /// windows as far as anything but `detail` goes.
    func testTheNewFieldsDoNotChangeWhatTheScreenShows() throws {
        let plain = try parse("""
        {
          "five_hour": {"utilization": 74.0, "resets_at": "2025-01-03T10:00:00.123456+00:00"},
          "seven_day": {"utilization": 42.0, "resets_at": "2025-01-07T12:00:00.123457+00:00"},
          "seven_day_opus": null,
          "cinder_cove": {"utilization": 1.5, "resets_at": "2025-01-15T12:00:00.123456+00:00"},
          "limits": [
            {"kind":"session","percent":74,"resets_at":"2025-01-03T10:00:00.123456+00:00"},
            {"kind":"weekly_all","percent":42,"resets_at":"2025-01-07T12:00:00.123457+00:00"},
            {"kind":"monthly_mystery","percent":3},
            \(Self.scoped("Fable"))
          ]
        }
        """)
        let enriched = try parse("""
        {
          "five_hour": {"utilization": 74.0, "resets_at": "2025-01-03T10:00:00.123456+00:00", "locked_reason": "x"},
          "seven_day": {"utilization": 42.0, "resets_at": "2025-01-07T12:00:00.123457+00:00", "locked_reason": null},
          "seven_day_opus": null,
          "cinder_cove": {"utilization": 1.5, "resets_at": "2025-01-15T12:00:00.123456+00:00"},
          "limits": [
            {"kind":"session","percent":74,"resets_at":"2025-01-03T10:00:00.123456+00:00","is_active":true,"severity":"warning"},
            {"kind":"weekly_all","percent":42,"resets_at":"2025-01-07T12:00:00.123457+00:00","is_active":false,"severity":"normal"},
            {"kind":"monthly_mystery","percent":3,"severity":"odd"},
            \(Self.scoped("Fable", extra: #","severity":"normal""#))
          ],
          "weekly_scoped_shares": [{"limit_index": 3, "used_percent_of_weekly": 24, "allowance_percent_of_weekly": 50}]
        }
        """)

        func shown(_ snapshot: QuotaSnapshot) -> [String] {
            snapshot.windows.map {
                "\($0.id)|\($0.label)|\($0.usedPercent)|\(String(describing: $0.resetsAt))|\(String(describing: $0.isModelScoped))|\(String(describing: $0.isOneTimeCredit))|\(String(describing: $0.cycle))"
            }
        }
        XCTAssertEqual(plain.windows.map(\.id), ["five_hour", "seven_day", "cinder_cove", "seven_day_fable"])
        XCTAssertEqual(shown(enriched), shown(plain))
        XCTAssertEqual(enriched.planType, plain.planType)
        XCTAssertEqual(enriched.extraUsageSpentUSD, plain.extraUsageSpentUSD)
        XCTAssertEqual(enriched.note, plain.note)
        XCTAssertEqual(try window("cinder_cove", in: enriched).detail?.utilizationStated, true)
    }

    // MARK: - The readers

    func testStrictReadersTellABooleanFromANumber() throws {
        let parsed = body(#"{"t": true, "f": false, "one": 1, "zero": 0, "half": 0.5, "s": "1", "n": null}"#)
        XCTAssertEqual(ClaudeOAuthFetcher.strictBool(parsed["t"]), true)
        XCTAssertEqual(ClaudeOAuthFetcher.strictBool(parsed["f"]), false)
        XCTAssertNil(ClaudeOAuthFetcher.strictBool(parsed["one"]))
        XCTAssertNil(ClaudeOAuthFetcher.strictBool(parsed["zero"]))
        XCTAssertNil(ClaudeOAuthFetcher.strictBool(parsed["s"]))
        XCTAssertNil(ClaudeOAuthFetcher.strictBool(parsed["n"]))
        XCTAssertNil(ClaudeOAuthFetcher.strictBool(nil))

        XCTAssertEqual(ClaudeOAuthFetcher.strictNumber(parsed["one"]), 1)
        XCTAssertEqual(ClaudeOAuthFetcher.strictNumber(parsed["zero"]), 0)
        XCTAssertEqual(ClaudeOAuthFetcher.strictNumber(parsed["half"]), 0.5)
        XCTAssertNil(ClaudeOAuthFetcher.strictNumber(parsed["t"]))
        XCTAssertNil(ClaudeOAuthFetcher.strictNumber(parsed["s"]))
        XCTAssertNil(ClaudeOAuthFetcher.strictNumber(parsed["n"]))
    }

    func testBoundedTextAcceptsShortPrintableAndNothingElse() {
        XCTAssertEqual(ClaudeOAuthFetcher.boundedText("Opus 4.8"), "Opus 4.8")
        XCTAssertEqual(ClaudeOAuthFetcher.boundedText("  limit_reached "), "limit_reached")
        XCTAssertEqual(ClaudeOAuthFetcher.boundedText("モデル"), "モデル", "non-ASCII letters are printable")
        XCTAssertEqual(ClaudeOAuthFetcher.boundedText(String(repeating: "a", count: 64))?.count, 64)
        XCTAssertNil(ClaudeOAuthFetcher.boundedText(String(repeating: "a", count: 65)))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText(""))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText(" \n "))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText("a\u{0}b"))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText("a\u{7}b"))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText("a\nb"))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText("a\u{202E}b"))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText("a\u{200B}b"))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText("a\u{00A0}b"), "only the ASCII space separates words")
        XCTAssertNil(ClaudeOAuthFetcher.boundedText("a\u{E000}b"))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText(5))
        XCTAssertNil(ClaudeOAuthFetcher.boundedText(nil))
        // 64 scalars is the cap even when they form fewer characters.
        XCTAssertNil(ClaudeOAuthFetcher.boundedText("e" + String(repeating: "\u{0301}", count: 64)))
    }
}
