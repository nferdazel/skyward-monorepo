-- ============================================================================
-- SKYWARD PHASE 14 WORLD TICK LOG COMPACTION DRY-RUN FOUNDATION
-- ============================================================================
-- Adds a summarized daily audit table for world_tick_log plus:
--   1. a read-only dry-run report RPC
--   2. a compaction RPC that defaults to dry-run mode
--
-- This migration does not schedule compaction. Destructive behavior only runs
-- when compact_world_tick_log(FALSE) is called intentionally.
-- ============================================================================

CREATE TABLE IF NOT EXISTS world_tick_daily_summary (
    season_id UUID NOT NULL REFERENCES season_clock(id),
    summary_date DATE NOT NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('started', 'skipped', 'success', 'error')),
    source_row_count BIGINT NOT NULL CHECK (source_row_count > 0),
    first_started_at TIMESTAMP WITH TIME ZONE NOT NULL,
    last_finished_at TIMESTAMP WITH TIME ZONE,
    first_game_time_before TIMESTAMP WITH TIME ZONE,
    last_game_time_after TIMESTAMP WITH TIME ZONE,
    total_ticks_processed BIGINT NOT NULL DEFAULT 0 CHECK (total_ticks_processed >= 0),
    total_real_seconds_processed NUMERIC(20,4) NOT NULL DEFAULT 0.0000 CHECK (total_real_seconds_processed >= 0),
    total_game_seconds_processed NUMERIC(20,4) NOT NULL DEFAULT 0.0000 CHECK (total_game_seconds_processed >= 0),
    total_players_processed BIGINT NOT NULL DEFAULT 0 CHECK (total_players_processed >= 0),
    total_bots_processed BIGINT NOT NULL DEFAULT 0 CHECK (total_bots_processed >= 0),
    latest_message TEXT,
    compacted_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    PRIMARY KEY (season_id, summary_date, status)
);

CREATE INDEX IF NOT EXISTS world_tick_daily_summary_date_idx
ON world_tick_daily_summary(summary_date DESC, season_id, status);


CREATE OR REPLACE FUNCTION get_world_tick_log_compaction_report()
RETURNS TABLE (
    season_id UUID,
    summary_date DATE,
    status VARCHAR,
    source_row_count BIGINT,
    first_started_at TIMESTAMP WITH TIME ZONE,
    last_finished_at TIMESTAMP WITH TIME ZONE,
    first_game_time_before TIMESTAMP WITH TIME ZONE,
    last_game_time_after TIMESTAMP WITH TIME ZONE,
    total_ticks_processed BIGINT,
    total_real_seconds_processed NUMERIC,
    total_game_seconds_processed NUMERIC,
    total_players_processed BIGINT,
    total_bots_processed BIGINT,
    latest_message TEXT,
    retention_real_days INT,
    cutoff_started_at TIMESTAMP WITH TIME ZONE
) AS $$
DECLARE
    v_retention_days INT;
    v_cutoff TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT value_int
    INTO v_retention_days
    FROM data_retention_policy
    WHERE key = 'world_tick_log_raw_real_days';

    v_retention_days := COALESCE(v_retention_days, 7);
    v_cutoff := NOW() - make_interval(days => v_retention_days);

    RETURN QUERY
    WITH eligible AS (
        SELECT *
        FROM world_tick_log
        WHERE started_at < v_cutoff
    )
    SELECT
        grouped.season_id,
        grouped.summary_date,
        grouped.status,
        grouped.source_row_count,
        grouped.first_started_at,
        grouped.last_finished_at,
        grouped.first_game_time_before,
        grouped.last_game_time_after,
        grouped.total_ticks_processed,
        grouped.total_real_seconds_processed,
        grouped.total_game_seconds_processed,
        grouped.total_players_processed,
        grouped.total_bots_processed,
        grouped.latest_message,
        v_retention_days,
        v_cutoff
    FROM (
        SELECT
            eligible.season_id,
            (eligible.started_at AT TIME ZONE 'UTC')::DATE AS summary_date,
            eligible.status,
            COUNT(*)::BIGINT AS source_row_count,
            MIN(eligible.started_at) AS first_started_at,
            MAX(eligible.finished_at) AS last_finished_at,
            (ARRAY_AGG(eligible.game_time_before ORDER BY eligible.started_at ASC NULLS LAST))[1] AS first_game_time_before,
            (ARRAY_AGG(eligible.game_time_after ORDER BY COALESCE(eligible.finished_at, eligible.started_at) DESC NULLS LAST))[1] AS last_game_time_after,
            COALESCE(SUM(eligible.ticks_processed), 0)::BIGINT AS total_ticks_processed,
            COALESCE(SUM(eligible.real_seconds_processed), 0.0000)::NUMERIC AS total_real_seconds_processed,
            COALESCE(SUM(eligible.game_seconds_processed), 0.0000)::NUMERIC AS total_game_seconds_processed,
            COALESCE(SUM(eligible.players_processed), 0)::BIGINT AS total_players_processed,
            COALESCE(SUM(eligible.bots_processed), 0)::BIGINT AS total_bots_processed,
            (ARRAY_AGG(eligible.message ORDER BY COALESCE(eligible.finished_at, eligible.started_at) DESC NULLS LAST))[1] AS latest_message
        FROM eligible
        GROUP BY
            eligible.season_id,
            (eligible.started_at AT TIME ZONE 'UTC')::DATE,
            eligible.status
    ) grouped
    ORDER BY grouped.summary_date ASC, grouped.season_id ASC, grouped.status ASC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;


CREATE OR REPLACE FUNCTION compact_world_tick_log(
    p_dry_run BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    action TEXT,
    season_id UUID,
    summary_date DATE,
    status VARCHAR,
    source_row_count BIGINT,
    first_started_at TIMESTAMP WITH TIME ZONE,
    last_finished_at TIMESTAMP WITH TIME ZONE,
    first_game_time_before TIMESTAMP WITH TIME ZONE,
    last_game_time_after TIMESTAMP WITH TIME ZONE,
    total_ticks_processed BIGINT,
    total_real_seconds_processed NUMERIC,
    total_game_seconds_processed NUMERIC,
    total_players_processed BIGINT,
    total_bots_processed BIGINT,
    latest_message TEXT,
    retention_real_days INT,
    cutoff_started_at TIMESTAMP WITH TIME ZONE,
    raw_rows_deleted BIGINT
) AS $$
DECLARE
    v_deleted_rows BIGINT := 0;
BEGIN
    CREATE TEMP TABLE tmp_world_tick_compaction_report
    ON COMMIT DROP AS
    SELECT *
    FROM get_world_tick_log_compaction_report();

    IF p_dry_run THEN
        RETURN QUERY
        SELECT
            'dry_run'::TEXT,
            report.season_id,
            report.summary_date,
            report.status,
            report.source_row_count,
            report.first_started_at,
            report.last_finished_at,
            report.first_game_time_before,
            report.last_game_time_after,
            report.total_ticks_processed,
            report.total_real_seconds_processed,
            report.total_game_seconds_processed,
            report.total_players_processed,
            report.total_bots_processed,
            report.latest_message,
            report.retention_real_days,
            report.cutoff_started_at,
            0::BIGINT
        FROM tmp_world_tick_compaction_report report
        ORDER BY report.summary_date ASC, report.season_id ASC, report.status ASC;
        RETURN;
    END IF;

    INSERT INTO world_tick_daily_summary (
        season_id,
        summary_date,
        status,
        source_row_count,
        first_started_at,
        last_finished_at,
        first_game_time_before,
        last_game_time_after,
        total_ticks_processed,
        total_real_seconds_processed,
        total_game_seconds_processed,
        total_players_processed,
        total_bots_processed,
        latest_message,
        compacted_at
    )
    SELECT
        report.season_id,
        report.summary_date,
        report.status,
        report.source_row_count,
        report.first_started_at,
        report.last_finished_at,
        report.first_game_time_before,
        report.last_game_time_after,
        report.total_ticks_processed,
        report.total_real_seconds_processed,
        report.total_game_seconds_processed,
        report.total_players_processed,
        report.total_bots_processed,
        report.latest_message,
        NOW()
    FROM tmp_world_tick_compaction_report report
    ON CONFLICT (season_id, summary_date, status) DO UPDATE
    SET source_row_count = EXCLUDED.source_row_count,
        first_started_at = EXCLUDED.first_started_at,
        last_finished_at = EXCLUDED.last_finished_at,
        first_game_time_before = EXCLUDED.first_game_time_before,
        last_game_time_after = EXCLUDED.last_game_time_after,
        total_ticks_processed = EXCLUDED.total_ticks_processed,
        total_real_seconds_processed = EXCLUDED.total_real_seconds_processed,
        total_game_seconds_processed = EXCLUDED.total_game_seconds_processed,
        total_players_processed = EXCLUDED.total_players_processed,
        total_bots_processed = EXCLUDED.total_bots_processed,
        latest_message = EXCLUDED.latest_message,
        compacted_at = EXCLUDED.compacted_at;

    DELETE FROM world_tick_log raw
    WHERE raw.started_at < (
        SELECT report.cutoff_started_at
        FROM tmp_world_tick_compaction_report report
        LIMIT 1
    );
    GET DIAGNOSTICS v_deleted_rows = ROW_COUNT;

    RETURN QUERY
    SELECT
        'compacted'::TEXT,
        report.season_id,
        report.summary_date,
        report.status,
        report.source_row_count,
        report.first_started_at,
        report.last_finished_at,
        report.first_game_time_before,
        report.last_game_time_after,
        report.total_ticks_processed,
        report.total_real_seconds_processed,
        report.total_game_seconds_processed,
        report.total_players_processed,
        report.total_bots_processed,
        report.latest_message,
        report.retention_real_days,
        report.cutoff_started_at,
        v_deleted_rows
    FROM tmp_world_tick_compaction_report report
    ORDER BY report.summary_date ASC, report.season_id ASC, report.status ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


GRANT SELECT ON world_tick_daily_summary TO authenticated, anon, service_role;

REVOKE ALL ON FUNCTION get_world_tick_log_compaction_report() FROM PUBLIC;
REVOKE ALL ON FUNCTION compact_world_tick_log(BOOLEAN) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION get_world_tick_log_compaction_report() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION compact_world_tick_log(BOOLEAN) TO service_role;

COMMENT ON TABLE world_tick_daily_summary IS
'Daily UTC summary buckets for compacted world_tick_log rows. Added in Phase 14 to reduce audit-log growth while preserving operational history.';

COMMENT ON FUNCTION get_world_tick_log_compaction_report() IS
'Returns UTC-day/status world_tick_log summary buckets older than the configured raw retention window. Read-only dry-run surface.';

COMMENT ON FUNCTION compact_world_tick_log(BOOLEAN) IS
'Compacts world_tick_log into world_tick_daily_summary. Defaults to dry-run mode; destructive deletion only occurs when called with FALSE.';
