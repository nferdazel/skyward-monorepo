-- ============================================================================
-- SKYWARD PHASE 12/13 DATABASE SIZE AND RETENTION FOUNDATION
-- ============================================================================
-- Adds read-only database/table size reporting and configurable retention
-- policy values for future compaction phases. This migration does not delete
-- data and does not change simulation behavior.
-- ============================================================================

CREATE TABLE IF NOT EXISTS data_retention_policy (
    key TEXT PRIMARY KEY,
    value_int INT NOT NULL CHECK (value_int >= 0),
    unit TEXT NOT NULL CHECK (unit IN ('real_days', 'game_days', 'megabytes', 'percent')),
    description TEXT NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

INSERT INTO data_retention_policy (key, value_int, unit, description)
VALUES
    (
        'database_warn_mb',
        350,
        'megabytes',
        'Soft warning threshold for Supabase Free database size.'
    ),
    (
        'database_critical_mb',
        425,
        'megabytes',
        'Critical threshold where compaction should be run before read-only risk.'
    ),
    (
        'database_free_quota_mb',
        500,
        'megabytes',
        'Supabase Free database-size quota reference.'
    ),
    (
        'world_tick_log_raw_real_days',
        7,
        'real_days',
        'Future retention target for raw world_tick_log rows after summary compaction.'
    ),
    (
        'player_ledger_raw_game_days',
        90,
        'game_days',
        'Future retention target for detailed player ledger rows after summary compaction.'
    ),
    (
        'bot_ledger_raw_game_days',
        30,
        'game_days',
        'Future retention target for detailed bot ledger rows after summary compaction.'
    ),
    (
        'inactive_player_archive_real_days',
        30,
        'real_days',
        'Future inactivity threshold before player simulation can be paused or archived.'
    )
ON CONFLICT (key) DO UPDATE
SET value_int = EXCLUDED.value_int,
    unit = EXCLUDED.unit,
    description = EXCLUDED.description,
    updated_at = NOW();


CREATE OR REPLACE FUNCTION get_database_size_report()
RETURNS TABLE (
    database_name TEXT,
    database_size_bytes BIGINT,
    database_size_pretty TEXT,
    free_quota_mb INT,
    used_quota_percent NUMERIC,
    status TEXT
) AS $$
DECLARE
    v_size BIGINT;
    v_quota_mb INT;
    v_warn_mb INT;
    v_critical_mb INT;
BEGIN
    v_size := pg_database_size(current_database());

    SELECT value_int INTO v_quota_mb
    FROM data_retention_policy
    WHERE key = 'database_free_quota_mb';

    SELECT value_int INTO v_warn_mb
    FROM data_retention_policy
    WHERE key = 'database_warn_mb';

    SELECT value_int INTO v_critical_mb
    FROM data_retention_policy
    WHERE key = 'database_critical_mb';

    v_quota_mb := COALESCE(v_quota_mb, 500);
    v_warn_mb := COALESCE(v_warn_mb, 350);
    v_critical_mb := COALESCE(v_critical_mb, 425);

    RETURN QUERY SELECT
        current_database()::TEXT,
        v_size,
        pg_size_pretty(v_size),
        v_quota_mb,
        ROUND(((v_size::NUMERIC / (v_quota_mb::NUMERIC * 1024 * 1024)) * 100), 2),
        CASE
            WHEN v_size >= (v_critical_mb::BIGINT * 1024 * 1024) THEN 'critical'
            WHEN v_size >= (v_warn_mb::BIGINT * 1024 * 1024) THEN 'warn'
            ELSE 'ok'
        END;
END;
$$ LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION get_table_size_report()
RETURNS TABLE (
    schema_name TEXT,
    table_name TEXT,
    row_estimate BIGINT,
    total_size_bytes BIGINT,
    total_size_pretty TEXT,
    table_size_pretty TEXT,
    index_size_pretty TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        schemaname::TEXT,
        relname::TEXT,
        n_live_tup::BIGINT,
        pg_total_relation_size(format('%I.%I', schemaname, relname)::REGCLASS)::BIGINT,
        pg_size_pretty(pg_total_relation_size(format('%I.%I', schemaname, relname)::REGCLASS)),
        pg_size_pretty(pg_relation_size(format('%I.%I', schemaname, relname)::REGCLASS)),
        pg_size_pretty(pg_indexes_size(format('%I.%I', schemaname, relname)::REGCLASS))
    FROM pg_stat_user_tables
    ORDER BY pg_total_relation_size(format('%I.%I', schemaname, relname)::REGCLASS) DESC;
END;
$$ LANGUAGE plpgsql STABLE;


GRANT SELECT ON data_retention_policy TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION get_database_size_report() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION get_table_size_report() TO authenticated, anon, service_role;

COMMENT ON TABLE data_retention_policy IS
'Config values for future data compaction and inactivity policies. Phase 12/13 only: no deletion behavior.';

COMMENT ON FUNCTION get_database_size_report() IS
'Returns current database size against configured Supabase Free quota thresholds.';

COMMENT ON FUNCTION get_table_size_report() IS
'Returns approximate row counts and relation/index sizes for user tables.';
