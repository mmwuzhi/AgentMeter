import Foundation
import SQLite3
import XCTest
@testable import AgentMeter

/// Migration 1: the whole Phase 0B schema. Pins the shape (tables,
/// STRICT, WITHOUT ROWID, columns, indexes) and the rules the database
/// itself enforces (CHECK, UNIQUE, NOT NULL, foreign keys), so a later edit
/// to the DDL cannot loosen one without a test failing.
final class HistorySchemaTests: XCTestCase {
    // SQLite extended result codes (compound macros are not imported into Swift).
    private let checkFailed: Int32 = 275          // SQLITE_CONSTRAINT_CHECK
    private let notNullFailed: Int32 = 1299       // SQLITE_CONSTRAINT_NOTNULL
    private let primaryKeyFailed: Int32 = 1555    // SQLITE_CONSTRAINT_PRIMARYKEY
    private let uniqueFailed: Int32 = 2067        // SQLITE_CONSTRAINT_UNIQUE
    private let foreignKeyFailed: Int32 = 787     // SQLITE_CONSTRAINT_FOREIGNKEY
    private let dataTypeFailed: Int32 = 3091      // SQLITE_CONSTRAINT_DATATYPE (a STRICT table refused the type)

    private func openDB() throws -> HistoryDatabase {
        try HistoryDatabase.open(historyConfig(historyTempDirectory()))
    }

    private func assertRejected(_ db: HistoryDatabase, _ sql: String, _ extended: Int32,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try db.conn.exec(sql), file: file, line: line) { error in
            guard let e = error as? SQLiteError else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertEqual(e.extendedCode, extended, "\(e)", file: file, line: line)
        }
    }

    /// One parent session, one parent file, and a helper that inserts a valid request row with overrides.
    private func seedParents(_ db: HistoryDatabase) throws {
        try db.conn.exec("INSERT INTO session(session_ref, session_id) VALUES (1, 'session-1')")
        try db.conn.exec("""
            INSERT INTO source_file(file_ref, path, class, session_ref, parser_version)
            VALUES (1, '/p/session-1.jsonl', 0, 1, 3)
            """)
    }

    private func requestSQL(key: String = "X'00112233445566778899AABBCCDDEEFF'", iteration: Int = 0,
                            overrides: [String: String] = [:]) -> String {
        var values: [(String, String)] = [
            ("key", key), ("iteration_idx", "\(iteration)"), ("model_ref", "1"),
            ("input", "10"), ("output", "20"), ("cache_write_5m", "0"), ("cache_write_1h", "0"), ("cache_read", "5"),
            ("finality", "2"), ("parts", "1"), ("output_total", "20"), ("rec_sig", "-7"), ("ingest_version", "3"),
            ("owner_file_ref", "1"), ("session_ref", "1"), ("class", "0"),
        ]
        for (column, literal) in overrides {
            if let i = values.firstIndex(where: { $0.0 == column }) { values[i].1 = literal } else { values.append((column, literal)) }
        }
        return "INSERT INTO request(\(values.map(\.0).joined(separator: ","))) VALUES (\(values.map(\.1).joined(separator: ",")))"
    }

    // MARK: Shape

    func testEveryTableExistsIsStrictAndRowidnessMatchesTheDesign() throws {
        let db = try openDB()
        var strict: [String: Bool] = [:]
        var withoutRowid: Set<String> = []
        try db.conn.withTemporaryStatement(
            "SELECT name, strict, wr FROM pragma_table_list WHERE schema = 'main' AND name NOT LIKE 'sqlite_%' AND type = 'table'"
        ) { s in
            while try s.step() {
                let name = s.text(0) ?? ""
                strict[name] = s.int64(1) == 1
                if s.int64(2) == 1 { withoutRowid.insert(name) }
            }
        }
        XCTAssertEqual(Set(strict.keys), Set(HistorySchema.tableNames))
        XCTAssertEqual(strict.filter { !$0.value }.keys.sorted(), [], "every table is STRICT")
        XCTAssertEqual(withoutRowid, [
            "meta", "request_occurrence", "limit_event", "usage_report_sample", "usage_report_limit",
            "cost_state_sample", "cost_state_model", "compact_event", "reset_grant_sample", "reset_event",
        ], "request, session, source_file, dict, quota_sample and ingest_scan stay rowid tables")
    }

    func testColumnsAreTheDesignsColumnsInOrder() throws {
        let db = try openDB()
        let expected: [String: [String]] = [
            "meta": ["key", "value"],
            "dict": ["id", "kind", "value"],
            "session": ["session_ref", "session_id", "first_cwd", "first_cwd_ms", "entrypoint_ref", "cc_version_ref"],
            "source_file": ["file_ref", "path", "class", "session_ref", "agent_id", "run_id", "birth_ms", "file_id", "volume_id",
                            "size", "mtime", "parsed_bytes", "boundary_digest", "parser_version", "ingested_ms"],
            "request": ["key", "iteration_idx", "model_ref", "input", "output", "cache_write_5m", "cache_write_1h", "cache_read",
                        "thinking", "finality", "parts", "output_total", "rec_sig", "ingest_version", "final_ms",
                        "first_seen_ms", "last_seen_ms", "acct_day", "owner_file_ref", "session_ref", "class",
                        "cc_version_ref", "effort_ref", "entrypoint_ref", "flags"],
            "request_occurrence": ["key", "file_ref", "first_ms", "last_ms", "ingest_version", "att_fin", "att_out",
                                   "att_sig", "cc_version_ref", "effort_ref", "entrypoint_ref", "flags"],
            "ingest_scan": ["scan_id", "started_ms", "landed_ms", "complete", "files", "files_written"],
            "quota_sample": ["sample_id", "provider", "window_id", "source", "reading_ms", "fetched_ms", "cached_ms", "recorded_ms",
                             "used_percent", "resets_at_ms", "reset_epoch_s", "cycle_s", "scoped", "one_time", "is_active",
                             "severity", "locked_reason", "scope_name", "share_used", "share_allowance", "plan_ref", "tier_ref", "flags"],
            "limit_event": ["event_key", "uuid", "request_id", "session_ref", "agent_id", "class", "ts_ms", "window_id", "status",
                            "resets_at_ms", "reset_epoch_s", "overage_status", "overage_disabled_reason", "is_using_overage",
                            "fallback_available", "source", "api_error", "cc_version_ref", "file_ref"],
            "usage_report_sample": ["report_key", "uuid", "session_ref", "ts_ms", "cc_version_ref", "has_limits",
                                    "extra_enabled", "extra_monthly_limit", "extra_used_credits", "file_ref"],
            "usage_report_limit": ["report_key", "idx", "window_id", "kind", "grp", "percent", "severity", "is_active",
                                   "resets_at_ms", "reset_epoch_s", "scope_model"],
            "cost_state_sample": ["session_ref", "start_time_ms", "total_duration_ms", "total_api_duration_ms", "total_cost_usd",
                                  "has_unknown_model_cost", "after_ts_ms"],
            "cost_state_model": ["session_ref", "start_time_ms", "total_duration_ms", "model_key", "input", "output", "cache_read",
                                 "cache_creation", "thinking", "web_search", "cost_usd"],
            "compact_event": ["event_key", "session_ref", "ts_ms", "trigger", "pre_tokens", "post_tokens", "file_ref"],
            "reset_grant_sample": ["recorded_ms", "grant_id", "resets_left", "ends_at_ms", "clears"],
            "reset_event": ["provider", "window_id", "kind", "detected_ms", "prev_sample_ms", "prev_percent", "new_percent",
                            "prev_epoch_s", "new_epoch_s", "detector_version"],
        ]
        XCTAssertEqual(Set(expected.keys), Set(HistorySchema.tableNames))
        for (table, columns) in expected {
            XCTAssertEqual(try db.conn.queryTexts("SELECT name FROM pragma_table_info('\(table)') ORDER BY cid"), columns, table)
        }
    }

    func testTheIndexesCoverTheDesignedColumns() throws {
        let db = try openDB()
        func columns(of index: String) throws -> [String] {
            try db.conn.queryTexts("SELECT name FROM pragma_index_info('\(index)') ORDER BY seqno")
        }
        XCTAssertEqual(try columns(of: "request_first_seen"), ["first_seen_ms"])
        XCTAssertEqual(try columns(of: "request_session"), ["session_ref", "first_seen_ms"])
        XCTAssertEqual(try columns(of: "limit_event_window"), ["window_id", "resets_at_ms", "ts_ms"])
        // the UNIQUE(key, iteration_idx) index is automatic and has to exist exactly once on request
        let uniques = try db.conn.queryTexts("SELECT name FROM pragma_index_list('request') WHERE origin = 'u'")
        XCTAssertEqual(uniques.count, 1)
        XCTAssertEqual(try columns(of: uniques[0]), ["key", "iteration_idx"])
    }

    // MARK: Enforced rules

    func testStrictRejectsAValueOfTheWrongTypeInsteadOfConvertingIt() throws {
        let db = try openDB()
        assertRejected(db, "INSERT INTO dict(kind, value) VALUES ('seven', 'x')", dataTypeFailed)
        assertRejected(db, "INSERT INTO dict(kind, value) VALUES (X'01', 'x')", dataTypeFailed)
        // a lossless conversion (the text '7' into an INTEGER column) is still allowed in STRICT mode
        XCTAssertNoThrow(try db.conn.exec("INSERT INTO dict(kind, value) VALUES ('7', 'x')"))
        XCTAssertEqual(try db.conn.queryText("SELECT typeof(kind) FROM dict"), "integer")
    }

    func testMetaKeepsEachValueInItsOwnType() throws {
        let db = try openDB()
        try db.conn.exec("INSERT INTO meta VALUES ('acct_tz', 'Asia/Tokyo'), ('created_ms', 1760000000000), ('ratio', 0.5)")
        XCTAssertEqual(try db.conn.queryTexts("SELECT typeof(value) FROM meta ORDER BY key"), ["text", "integer", "real"])
        assertRejected(db, "INSERT INTO meta VALUES ('acct_tz', 'again')", primaryKeyFailed)
    }

    func testCheckConstraintsRejectBadRows() throws {
        let db = try openDB()
        try seedParents(db)
        try db.conn.exec(requestSQL())      // the baseline row is valid
        assertRejected(db, "INSERT INTO source_file(path, class, session_ref, parser_version) VALUES ('/x', 4, 1, 3)", checkFailed)
        assertRejected(db, "INSERT INTO source_file(path, class, session_ref, parser_version) VALUES ('/y', -1, 1, 3)", checkFailed)
        let key2 = "X'0A0B0C0D0E0F101112131415161718AA'"
        assertRejected(db, requestSQL(key: key2, iteration: -1), checkFailed)
        for column in ["input", "output", "cache_write_5m", "cache_write_1h", "cache_read"] {
            assertRejected(db, requestSQL(key: key2, overrides: [column: "-1"]), checkFailed)
        }
        assertRejected(db, requestSQL(key: key2, overrides: ["finality": "3"]), checkFailed)
        assertRejected(db, requestSQL(key: key2, overrides: ["finality": "-1"]), checkFailed)
        assertRejected(db, requestSQL(key: key2, overrides: ["parts": "0"]), checkFailed)
        assertRejected(db, "INSERT INTO ingest_scan VALUES (1, 1, 1, 2, 0, 0)", checkFailed)
        assertRejected(db, """
            INSERT INTO quota_sample(provider, window_id, source, reading_ms, recorded_ms) VALUES ('claude', 'five_hour', 'bogus', 1, 1)
            """, checkFailed)
        for finality in [0, 1, 2] { XCTAssertNoThrow(try db.conn.exec(requestSQL(key: key2, iteration: finality, overrides: ["finality": "\(finality)"]))) }
        for source in ["oauth", "cli", "appServer", "rolloutFile", "unknown"] {
            XCTAssertNoThrow(try db.conn.exec("""
                INSERT INTO quota_sample(provider, window_id, source, reading_ms, recorded_ms) VALUES ('claude', 'five_hour', '\(source)', 1, 1)
                """))
        }
        XCTAssertEqual(try db.conn.queryInt("SELECT count(*) FROM request"), 4, "no rejected row left anything behind")
    }

    func testNotNullColumnsRejectNULL() throws {
        let db = try openDB()
        try seedParents(db)
        for column in ["key", "iteration_idx", "model_ref", "input", "output", "finality", "parts", "output_total", "rec_sig",
                       "ingest_version", "owner_file_ref", "session_ref", "class"] {
            assertRejected(db, requestSQL(overrides: [column: "NULL"]), notNullFailed)
        }
        assertRejected(db, "INSERT INTO quota_sample(provider, window_id, source, reading_ms) VALUES ('claude', 'w', 'oauth', 1)", notNullFailed)
        XCTAssertNoThrow(try db.conn.exec(requestSQL(overrides: ["thinking": "NULL", "final_ms": "NULL", "first_seen_ms": "NULL"])))
    }

    /// `att_sig` is required and a signed 64-bit INTEGER (`Int64(bitPattern:)`
    /// of the digest prefix, so both extremes occur).
    func testTheAttributeSignatureIsARequiredSignedInteger() throws {
        let db = try openDB()
        try seedParents(db)
        let columns = "key, file_ref, ingest_version, att_fin, att_out"
        assertRejected(db, "INSERT INTO request_occurrence(\(columns)) VALUES (X'01', 1, 3, 2, 5)", notNullFailed)
        assertRejected(db, "INSERT INTO request_occurrence(\(columns), att_sig) VALUES (X'01', 1, 3, 2, 5, 'x')", dataTypeFailed)
        assertRejected(db, "INSERT INTO request_occurrence(\(columns), att_sig) VALUES (X'01', 1, 3, 2, 5, 0.5)", dataTypeFailed)
        try db.conn.exec("INSERT INTO request_occurrence(\(columns), att_sig) VALUES (X'01', 1, 3, 2, 5, \(Int64.min))")
        try db.conn.exec("INSERT INTO request_occurrence(\(columns), att_sig) VALUES (X'02', 1, 3, 2, 5, \(Int64.max))")
        XCTAssertEqual(try db.conn.queryTexts("SELECT att_sig FROM request_occurrence ORDER BY key"),
                       ["\(Int64.min)", "\(Int64.max)"])
    }

    func testRequestIsUniquePerKeyAndIteration() throws {
        let db = try openDB()
        try seedParents(db)
        try db.conn.exec(requestSQL(iteration: 0))
        try db.conn.exec(requestSQL(iteration: 1))      // another iteration of the same key is another row
        assertRejected(db, requestSQL(iteration: 0), uniqueFailed)
        assertRejected(db, requestSQL(iteration: 1), uniqueFailed)
        // the conflict target of the upsert the merge step uses resolves against that unique index
        try db.conn.exec(requestSQL(iteration: 1) + " ON CONFLICT(key, iteration_idx) DO UPDATE SET output = excluded.output + 1")
        XCTAssertEqual(try db.conn.queryInt("SELECT output FROM request WHERE iteration_idx = 1"), 21)
        XCTAssertEqual(try db.conn.queryInt("SELECT count(*) FROM request"), 2)
    }

    func testOtherNaturalKeysAreEnforced() throws {
        let db = try openDB()
        try seedParents(db)
        let sample = "INSERT INTO quota_sample(provider, window_id, source, reading_ms, recorded_ms) VALUES ('claude', 'five_hour', 'oauth', 1000, 2000)"
        try db.conn.exec(sample)
        assertRejected(db, sample, uniqueFailed)
        // the same reading under another source, window or provider is another sample
        try db.conn.exec(sample.replacingOccurrences(of: "'oauth'", with: "'cli'"))
        try db.conn.exec(sample.replacingOccurrences(of: "'five_hour'", with: "'seven_day'"))
        try db.conn.exec(sample.replacingOccurrences(of: "'claude'", with: "'codex'"))
        assertRejected(db, "INSERT INTO session(session_id) VALUES ('session-1')", uniqueFailed)
        assertRejected(db, "INSERT INTO source_file(path, class, session_ref, parser_version) VALUES ('/p/session-1.jsonl', 0, 1, 3)", uniqueFailed)
        assertRejected(db, "INSERT INTO dict(kind, value) VALUES (1, 'a'), (1, 'a')", uniqueFailed)
        try db.conn.exec("INSERT INTO dict(kind, value) VALUES (2, 'a')")
        try db.conn.exec("INSERT INTO request_occurrence(key, file_ref, ingest_version, att_fin, att_out, att_sig) VALUES (X'01', 1, 3, 2, 5, -9)")
        assertRejected(db, "INSERT INTO request_occurrence(key, file_ref, ingest_version, att_fin, att_out, att_sig) VALUES (X'01', 1, 3, 2, 5, -9)", primaryKeyFailed)
        try db.conn.exec("INSERT INTO reset_event VALUES ('claude', 'five_hour', 'reset', 5, 4, 90.0, 1.0, 100, 200, 1)")
        assertRejected(db, "INSERT INTO reset_event VALUES ('claude', 'five_hour', 'reset', 5, 4, 90.0, 1.0, 100, 200, 1)", primaryKeyFailed)
        try db.conn.exec("INSERT INTO limit_event(event_key, uuid, session_ref, ts_ms, window_id, source) VALUES ('rid', 'u', 1, 1, 'five_hour', 'quotaLimits')")
        assertRejected(db, "INSERT INTO limit_event(event_key, uuid, session_ref, ts_ms, window_id, source) VALUES ('rid', 'u2', 1, 2, 'five_hour', 'quotaLimits')", primaryKeyFailed)
        try db.conn.exec("INSERT INTO compact_event(event_key, session_ref, ts_ms, trigger) VALUES ('u', 1, 1, 'auto')")
    }

    func testForeignKeysAreEnforced() throws {
        let db = try openDB()
        XCTAssertEqual(try db.conn.queryInt("PRAGMA foreign_keys"), 1)
        assertRejected(db, "INSERT INTO source_file(path, class, session_ref, parser_version) VALUES ('/x', 0, 99, 3)", foreignKeyFailed)
        try seedParents(db)
        assertRejected(db, requestSQL(overrides: ["owner_file_ref": "99"]), foreignKeyFailed)
        assertRejected(db, requestSQL(overrides: ["session_ref": "99"]), foreignKeyFailed)
        assertRejected(db, "INSERT INTO request_occurrence(key, file_ref, ingest_version, att_fin, att_out, att_sig) VALUES (X'01', 99, 3, 2, 5, -9)", foreignKeyFailed)
        // The owning file of an event row (limit_event, usage_report_sample, compact_event).
        for sql in [
            "INSERT INTO limit_event(event_key, uuid, session_ref, ts_ms, window_id, source, file_ref) VALUES ('fk', 'u', 1, 1, 'five_hour', 'quotaLimits', 99)",
            "INSERT INTO usage_report_sample(report_key, uuid, session_ref, ts_ms, has_limits, file_ref) VALUES ('fk', 'u', 1, 1, 1, 99)",
            "INSERT INTO compact_event(event_key, session_ref, ts_ms, file_ref) VALUES ('fk', 1, 1, 99)",
        ] {
            assertRejected(db, sql, foreignKeyFailed)
        }
        try db.conn.exec(requestSQL())
        // a parent that a child still references cannot be deleted
        assertRejected(db, "DELETE FROM source_file WHERE file_ref = 1", foreignKeyFailed)
        assertRejected(db, "DELETE FROM session WHERE session_ref = 1", foreignKeyFailed)
        try db.conn.exec("DELETE FROM request")
        try db.conn.exec("DELETE FROM source_file")
        try db.conn.exec("DELETE FROM session")
    }

    func testWatermarkIdsAboveInt64MaxRoundTripThroughTheirBitPattern() throws {
        let db = try openDB()
        try seedParents(db)
        let fileID = UInt64.max - 41, volumeID = UInt64(Int64.max) + 7
        try db.conn.withStatement("UPDATE source_file SET file_id = ?1, volume_id = ?2, boundary_digest = ?3 WHERE file_ref = 1") { s in
            s.bind(1, fileID); s.bind(2, volumeID); s.bind(3, blob: Data())
            try s.step()
        }
        try db.conn.withTemporaryStatement("SELECT file_id, volume_id, boundary_digest FROM source_file WHERE file_ref = 1") { s in
            XCTAssertTrue(try s.step())
            XCTAssertEqual(s.uint64(0), fileID)
            XCTAssertEqual(s.uint64(1), volumeID)
            XCTAssertEqual(s.blob(2), [], "an empty digest is stored as an empty blob, not NULL")
        }
    }
}
