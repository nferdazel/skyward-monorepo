-- ============================================================================
-- SKYWARD PHASE 14.1 WORLD TICK COMPACTION CONFLICT FIX
-- ============================================================================
-- Fixes an ambiguity in compact_world_tick_log() observed after migration 48.
-- The RETURNS TABLE output column names can collide with ON CONFLICT target
-- column references inside PL/pgSQL. Use the primary-key constraint name
-- explicitly so the non-dry-run path remains executable.
-- ============================================================================

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
    ON CONFLICT ON CONSTRAINT world_tick_daily_summary_pkey DO UPDATE
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

REVOKE ALL ON FUNCTION compact_world_tick_log(BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION compact_world_tick_log(BOOLEAN) TO service_role;

COMMENT ON FUNCTION compact_world_tick_log(BOOLEAN) IS
'Compacts world_tick_log into world_tick_daily_summary. Defaults to dry-run mode; destructive deletion only occurs when called with FALSE. Phase 14.1 fixes ON CONFLICT ambiguity in the non-dry-run path.';
