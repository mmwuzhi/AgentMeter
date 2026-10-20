import Foundation

/// The schema of `history.sqlite`, as Swift string literals (a `.sql` file in
/// the target would be an unhandled resource). Migration 1 is the whole
/// Phase 0B schema. Later migrations are appended here, never edited: a
/// shipped step must stay what it was.
///
/// Conventions that hold for every table:
///  * STRICT, so a text value in an INTEGER column is an error, not a silent
///    affinity conversion. Needs SQLite 3.37 (`HistoryDatabase.minimumSQLiteVersion`).
///  * Times are Unix milliseconds UTC. NULL means "not stated", never a
///    fallback such as `Date()`.
///  * Surrogate ids (`file_ref`, `session_ref`, `dict.id`, rowids) are
///    arrival-order artefacts of THIS database. They are never compared across
///    databases, never written to another file, never keyed on by later phases
///    (attribution tables key on `(key, iteration_idx)`).
///  * Foreign keys are enforced (`foreign_keys = ON`): a `request` row needs its
///    `source_file` and `session` rows first, and a bulk delete must remove
///    children before parents.
///  * Only identifiers, timestamps, counts and short labels are stored. No
///    prompt, title, message body or tool input ever reaches this schema.
enum HistorySchema {
    /// 'AMHS'. Lets the store recognise its own file, and reject somebody
    /// else's SQLite file at its path.
    static let applicationID: Int32 = 0x414D_4853

    static let migrations: [HistoryMigration] = [
        HistoryMigration(version: 1, name: "history schema v1") { db in
            for statement in schemaV1 { try db.exec(statement) }
            try db.setPragma("application_id", "\(applicationID)")
        },
    ]

    /// Every table the schema creates, in creation order. Tests iterate it.
    static let tableNames = [
        "meta", "dict", "session", "source_file", "request", "request_occurrence", "ingest_scan",
        "quota_sample", "limit_event", "usage_report_sample", "usage_report_limit",
        "cost_state_sample", "cost_state_model", "compact_event", "reset_grant_sample", "reset_event",
    ]

    /// Indexes created next to the tables (the implicit ones of PRIMARY KEY and UNIQUE are not listed).
    static let indexNames = ["request_first_seen", "request_session", "limit_event_window"]

    // Every `WITHOUT ROWID` table is written `WITHOUT ROWID, STRICT` (SQLite
    // wants that order), `meta` included. `ANY` is allowed in STRICT tables
    // (3.37) and keeps the value's own type.
    private static let schemaV1: [String] = [
        // acct_tz, created_ms, last_maintenance_ms, last_integrity_check_ms,
        // legacy_quota_imported, quota_conflicts, complete_scan_ms,
        // latest_scan_ms, ingest_version, schema_writer_app_version
        """
        CREATE TABLE meta(
            key TEXT PRIMARY KEY,
            value ANY
        ) WITHOUT ROWID, STRICT
        """,
        // Interned labels. kind: 1 model, 2 cc_version, 3 effort, 4 entrypoint, 5 plan, 6 tier, 7 scope_name.
        """
        CREATE TABLE dict(
            id INTEGER PRIMARY KEY,
            kind INTEGER NOT NULL,
            value TEXT NOT NULL,
            UNIQUE(kind, value)
        ) STRICT
        """,
        // first_cwd and friends: the earliest first-of-key usage record of the
        // MAIN file, replaced iff earlier (tie: smaller cwd). No first/last span
        // columns: those are derived from the owned requests on demand.
        """
        CREATE TABLE session(
            session_ref INTEGER PRIMARY KEY,
            session_id TEXT NOT NULL UNIQUE,
            first_cwd TEXT,
            first_cwd_ms INTEGER,
            entrypoint_ref INTEGER,
            cc_version_ref INTEGER
        ) STRICT
        """,
        // The tail (file_id ... ingested_ms) is the watermark. file_id and
        // volume_id are bound through Int64(bitPattern:). birth_ms is stat'd
        // once per new path inside the store actor and never rewritten. A path
        // registered but never watermarked has parsed_bytes NULL and
        // parser_version 0. Scan tickets are per-process counters, so the
        // store keeps them in memory, not here.
        """
        CREATE TABLE source_file(
            file_ref INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            class INTEGER NOT NULL CHECK(class IN (0,1,2,3)),
            session_ref INTEGER NOT NULL REFERENCES session,
            agent_id TEXT,
            run_id TEXT,
            birth_ms INTEGER,
            file_id INTEGER,
            volume_id INTEGER,
            size INTEGER,
            mtime REAL,
            parsed_bytes INTEGER,
            boundary_digest BLOB,
            parser_version INTEGER NOT NULL,
            ingested_ms INTEGER
        ) STRICT
        """,
        // A rowid table with a UNIQUE index, not WITHOUT ROWID: with a random
        // 17-byte key that measured twice the insert speed and 17x faster
        // time-range reads (rows land in arrival order, roughly time order).
        // No explicit id column: a hidden rowid is not stable across VACUUM and
        // nothing may key on it. Record rank columns: finality ... final_ms;
        // derived columns (recomputed from the occurrences): first_seen_ms ... flags.
        """
        CREATE TABLE request(
            key BLOB NOT NULL,
            iteration_idx INTEGER NOT NULL CHECK(iteration_idx >= 0),
            model_ref INTEGER NOT NULL,
            input INTEGER NOT NULL CHECK(input >= 0),
            output INTEGER NOT NULL CHECK(output >= 0),
            cache_write_5m INTEGER NOT NULL CHECK(cache_write_5m >= 0),
            cache_write_1h INTEGER NOT NULL CHECK(cache_write_1h >= 0),
            cache_read INTEGER NOT NULL CHECK(cache_read >= 0),
            thinking INTEGER,
            finality INTEGER NOT NULL CHECK(finality IN (0,1,2)),
            parts INTEGER NOT NULL CHECK(parts >= 1),
            output_total INTEGER NOT NULL,
            rec_sig INTEGER NOT NULL,
            ingest_version INTEGER NOT NULL,
            final_ms INTEGER,
            first_seen_ms INTEGER,
            last_seen_ms INTEGER,
            acct_day INTEGER,
            owner_file_ref INTEGER NOT NULL REFERENCES source_file,
            session_ref INTEGER NOT NULL REFERENCES session,
            class INTEGER NOT NULL,
            cc_version_ref INTEGER,
            effort_ref INTEGER,
            entrypoint_ref INTEGER,
            flags INTEGER NOT NULL DEFAULT 0,
            UNIQUE(key, iteration_idx)
        ) STRICT
        """,
        "CREATE INDEX request_first_seen ON request(first_seen_ms)",
        "CREATE INDEX request_session ON request(session_ref, first_seen_ms)",
        // What one file said about one request: the raw facts the derived
        // request columns are recomputed from. The attributes (cc_version ...
        // entrypoint) are those of the observation with the greatest
        // (ingest_version, att_fin, att_out, att_sig); att_sig is the signed
        // 64-bit `HistoryAttributeSignature` (rec_sig's high half, a label
        // hash below), which tells apart the contents of a file rewritten
        // with equal counts and other labels.
        """
        CREATE TABLE request_occurrence(
            key BLOB NOT NULL,
            file_ref INTEGER NOT NULL REFERENCES source_file,
            first_ms INTEGER,
            last_ms INTEGER,
            ingest_version INTEGER NOT NULL,
            att_fin INTEGER NOT NULL,
            att_out INTEGER NOT NULL,
            att_sig INTEGER NOT NULL,
            cc_version_ref INTEGER,
            effort_ref INTEGER,
            entrypoint_ref INTEGER,
            flags INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(key, file_ref)
        ) WITHOUT ROWID, STRICT
        """,
        // Scan coverage for attribution ("requests complete through T"); also meta.complete_scan_ms / latest_scan_ms.
        """
        CREATE TABLE ingest_scan(
            scan_id INTEGER PRIMARY KEY,
            started_ms INTEGER NOT NULL,
            landed_ms INTEGER NOT NULL,
            complete INTEGER NOT NULL CHECK(complete IN (0,1)),
            files INTEGER NOT NULL,
            files_written INTEGER NOT NULL
        ) STRICT
        """,
        // sample_id is the arrival order (clock anomalies show as a non-monotone
        // reading_ms against sample_id). reading_ms is the RAW readingTime and is
        // never clamped: clamping rewrote the natural key and split joined
        // flights. used_percent is NULL when the response named the window but
        // stated no utilization (never a fabricated 0). flags: 1 legacy,
        // 2 future_reading (reading_ms > recorded_ms), 4 value_not_stated.
        """
        CREATE TABLE quota_sample(
            sample_id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            window_id TEXT NOT NULL,
            source TEXT NOT NULL CHECK(source IN ('oauth','cli','appServer','rolloutFile','unknown')),
            reading_ms INTEGER NOT NULL,
            fetched_ms INTEGER,
            cached_ms INTEGER,
            recorded_ms INTEGER NOT NULL,
            used_percent REAL,
            resets_at_ms INTEGER,
            reset_epoch_s INTEGER,
            cycle_s INTEGER,
            scoped INTEGER,
            one_time INTEGER,
            is_active INTEGER,
            severity TEXT,
            locked_reason TEXT,
            scope_name TEXT,
            share_used REAL,
            share_allowance REAL,
            plan_ref INTEGER,
            tier_ref INTEGER,
            flags INTEGER NOT NULL DEFAULT 0,
            UNIQUE(provider, window_id, source, reading_ms)
        ) STRICT
        """,
        // event_key: request_id when present (forks re-stamp uuids), else 'uuid:' + uuid.
        // file_ref: the transcript the row was taken from. Copies of one event in
        // several files (forks) resolve to the file that ranks first by
        // (birth_ms IS NULL, birth_ms, path in byte order), the file order of the
        // request owner rule, so the row does not depend on which copy arrived
        // first. Same for usage_report_sample and compact_event.
        """
        CREATE TABLE limit_event(
            event_key TEXT PRIMARY KEY,
            uuid TEXT NOT NULL,
            request_id TEXT,
            session_ref INTEGER NOT NULL,
            agent_id TEXT,
            class INTEGER,
            ts_ms INTEGER NOT NULL,
            window_id TEXT NOT NULL,
            status TEXT,
            resets_at_ms INTEGER,
            reset_epoch_s INTEGER,
            overage_status TEXT,
            overage_disabled_reason TEXT,
            is_using_overage INTEGER,
            fallback_available INTEGER,
            source TEXT NOT NULL,
            api_error TEXT,
            cc_version_ref INTEGER,
            file_ref INTEGER REFERENCES source_file
        ) WITHOUT ROWID, STRICT
        """,
        "CREATE INDEX limit_event_window ON limit_event(window_id, resets_at_ms, ts_ms)",
        // report_key: "<ts_ms>|<hex8 sha of the canonical limits>" (a fork-copied /usage record gets a new uuid).
        // Its usage_report_limit rows are written (and replaced) only with the owning report.
        """
        CREATE TABLE usage_report_sample(
            report_key TEXT PRIMARY KEY,
            uuid TEXT NOT NULL,
            session_ref INTEGER NOT NULL,
            ts_ms INTEGER NOT NULL,
            cc_version_ref INTEGER,
            has_limits INTEGER NOT NULL,
            extra_enabled INTEGER,
            extra_monthly_limit INTEGER,
            extra_used_credits INTEGER,
            file_ref INTEGER REFERENCES source_file
        ) WITHOUT ROWID, STRICT
        """,
        """
        CREATE TABLE usage_report_limit(
            report_key TEXT NOT NULL,
            idx INTEGER NOT NULL,
            window_id TEXT NOT NULL,
            kind TEXT,
            grp TEXT,
            percent REAL,
            severity TEXT,
            is_active INTEGER,
            resets_at_ms INTEGER,
            reset_epoch_s INTEGER,
            scope_model TEXT,
            PRIMARY KEY(report_key, idx)
        ) WITHOUT ROWID, STRICT
        """,
        // after_ts_ms: the running MAX timestamp of the usage records before the
        // cost-state line in its file (a lower bound; the record has no time).
        // File-dependent, so copies merge it as a NULL-aware MAX; the rest of the
        // row and its cost_state_model rows are the same in every copy.
        """
        CREATE TABLE cost_state_sample(
            session_ref INTEGER NOT NULL,
            start_time_ms INTEGER NOT NULL,
            total_duration_ms INTEGER NOT NULL,
            total_api_duration_ms INTEGER,
            total_cost_usd REAL,
            has_unknown_model_cost INTEGER,
            after_ts_ms INTEGER,
            PRIMARY KEY(session_ref, start_time_ms, total_duration_ms)
        ) WITHOUT ROWID, STRICT
        """,
        """
        CREATE TABLE cost_state_model(
            session_ref INTEGER NOT NULL,
            start_time_ms INTEGER NOT NULL,
            total_duration_ms INTEGER NOT NULL,
            model_key TEXT NOT NULL,
            input INTEGER,
            output INTEGER,
            cache_read INTEGER,
            cache_creation INTEGER,
            thinking INTEGER,
            web_search INTEGER,
            cost_usd REAL,
            PRIMARY KEY(session_ref, start_time_ms, total_duration_ms, model_key)
        ) WITHOUT ROWID, STRICT
        """,
        // event_key: '<ts_ms>|<trigger>|<pre_tokens>|<post_tokens>' (empty for a
        // missing value). Not the uuid: a fork's copied compact_boundary line gets
        // a new one. In-file replays are deduplicated by uuid in the scanner.
        """
        CREATE TABLE compact_event(
            event_key TEXT PRIMARY KEY,
            session_ref INTEGER NOT NULL,
            ts_ms INTEGER NOT NULL,
            trigger TEXT,
            pre_tokens INTEGER,
            post_tokens INTEGER,
            file_ref INTEGER REFERENCES source_file
        ) WITHOUT ROWID, STRICT
        """,
        // The grant state is already fetched; stored only when the set changes.
        """
        CREATE TABLE reset_grant_sample(
            recorded_ms INTEGER NOT NULL,
            grant_id TEXT NOT NULL,
            resets_left INTEGER,
            ends_at_ms INTEGER,
            clears TEXT,
            PRIMARY KEY(recorded_ms, grant_id)
        ) WITHOUT ROWID, STRICT
        """,
        // Derived from two consecutive OAuth samples; rebuildResetEvents() re-derives.
        """
        CREATE TABLE reset_event(
            provider TEXT NOT NULL,
            window_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            detected_ms INTEGER NOT NULL,
            prev_sample_ms INTEGER NOT NULL,
            prev_percent REAL,
            new_percent REAL,
            prev_epoch_s INTEGER,
            new_epoch_s INTEGER,
            detector_version INTEGER NOT NULL,
            PRIMARY KEY(provider, window_id, kind, detected_ms)
        ) WITHOUT ROWID, STRICT
        """,
    ]
}
